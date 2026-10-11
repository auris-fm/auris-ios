import Foundation
import PocketCastsUtils

/// Real cloud route sink: WebSocket client → audio player → action dispatch.
///
/// Cloud answers arrive as synthesised audio streamed over the WebSocket; the
/// client plays them directly through the shared audio output path. Text
/// accumulation (`.token`) is removed — cloud answers are played, not spoken.
final class CloudRouteSink: VoiceCloudRouteSink,
                            CloudAudioPlayer.Delegate {

    /// The cloud player this sink drives, so a test can reach the real producer through
    /// the chain the app builds rather than constructing its own.
    var audioPlayerForTesting: CloudAudioPlayer? { audioPlayer }
    private let clientFactory: () -> CloudRouteClient
    private let isConfigured: () -> Bool
    private let playbackSink: VoicePlaybackSink
    private let fingerprintMapper: FingerprintMappingProviding
    private let playbackPositionMs: () -> Int64
    private let cloudPlaybackContextState: CloudPlaybackContextState
    private let analytics: VoiceAnalytics?
    /// Renders structured `search_results_v1` results. False until the discovery
    /// renderer lands (Item 5 slice 2) — the capability is only advertised when
    /// the client can actually render result/empty/unavailable.
    private let rendersStructuredResults: Bool
    /// Typed-only route hint for the current turn. Free-text turns pass nil and
    /// keep today's interpretation path.
    private let routeHintProvider: () -> CloudRouteHint?
    /// Bounded prior conversation for the turn (≤4 turns / ≤8 KiB enforced by
    /// `RecentConversation.bounded`).
    private let recentConversationProvider: () -> [RecentConversationTurn]
    /// Renders negotiated discovery results. Present only when the UI can show
    /// result/empty/unavailable states — the same condition that justifies
    /// advertising `search_results_v1`.
    private weak var resultsPresenter: DiscoveryResultsPresenting?
    /// Spoken templates for client-authored codes. Injectable so the locale rule
    /// (speak only in the user's own language; earcon otherwise) is testable.
    private let spokenTemplates: SpokenTemplateResolver

    /// Audio player for cloud-delivered speech.
    private let audioPlayer: CloudAudioPlayer
    private let playbackManager: PlaybackManager?

    /// Playback position captured before `seek_to` / `play_quote` for `stop_quote`.
    private var preQuotePositionMs: Int64?
    /// True when this turn paused playback so we can restore on done/error.
    private var didAutoPause = false
    /// Whether the host was playing when the turn took its hold. The user's own
    /// pause stays the user's; only a hold that stopped running playback is
    /// released by the turn's end (Task 12).
    private var wasPlayingBeforeHold = false

    /// Set when the turn has completed and the player is draining: the hold is
    /// released from `audioPlayerDidStop` rather than at `done`.
    private var restoreHeldForPlayerDrain = false
    /// The in-flight turn. A new turn supersedes it: the older turn stops
    /// consuming its stream and stops touching playback/analytics state, so two
    /// overlapping turns (double wake, barge-in) cannot interleave actions or
    /// double-restore the pause.
    private var activeTurn: CloudTurnToken?

    /// Cancellation handle for one logical turn.
    final class CloudTurnToken {
        private let lock = NSLock()
        private var cancelled = false

        var isCancelled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return cancelled
        }

        func cancel() {
            lock.lock()
            cancelled = true
            lock.unlock()
        }
    }

    // `nonisolated`: the sink conforms to `CloudAudioPlayer.Delegate`, which is
    // `@MainActor`, so `CloudRouteSink` is implicitly main-actor-isolated. The
    // assembly that builds it is not, and construction only stores dependencies
    // (no main-actor state is touched), so the initializer is safe to call from
    // any context.
    nonisolated init(
        clientFactory: @escaping () -> CloudRouteClient = {
            CloudRouteClient(
                baseURL: CloudConfig.shared.baseUrl,
                userId: CloudIdentity.shared.userId,
                // Per-call: a configured Auris origin switches the credential
                // source to Auris-issued tokens; otherwise the static provider.
                tokenProvider: CloudTokenProviderRouter.provider()
            )
        },
        isConfigured: @escaping () -> Bool = { !CloudConfig.shared.baseUrl.isEmpty },
        audioPlayer: CloudAudioPlayer? = nil,
        playbackManager: PlaybackManager? = nil,
        playbackSink: VoicePlaybackSink,
        fingerprintMapper: FingerprintMappingProviding,
        playbackPositionMs: @escaping () -> Int64,
        cloudPlaybackContextState: CloudPlaybackContextState,
        analytics: VoiceAnalytics? = nil,
        rendersStructuredResults: Bool = false,
        routeHintProvider: @escaping () -> CloudRouteHint? = { nil },
        recentConversationProvider: @escaping () -> [RecentConversationTurn] = { [] },
        resultsPresenter: DiscoveryResultsPresenting? = nil,
        spokenTemplates: SpokenTemplateResolver = SpokenTemplateResolver()
    ) {
        self.clientFactory = clientFactory
        self.isConfigured = isConfigured
        self.playbackManager = playbackManager
        self.playbackSink = playbackSink
        self.fingerprintMapper = fingerprintMapper
        self.playbackPositionMs = playbackPositionMs
        self.cloudPlaybackContextState = cloudPlaybackContextState
        self.analytics = analytics
        self.rendersStructuredResults = rendersStructuredResults
        self.routeHintProvider = routeHintProvider
        self.recentConversationProvider = recentConversationProvider
        self.resultsPresenter = resultsPresenter
        self.spokenTemplates = spokenTemplates
        // Assigned last, and its delegate is set after every stored property is
        // initialized: `audioPlayer.delegate = self` reads `self` to make the
        // delegate reference, which Swift forbids before the initializer fully
        // initializes `self`.
        let resolvedAudioPlayer = audioPlayer ?? CloudAudioPlayer()
        self.audioPlayer = resolvedAudioPlayer
        resolvedAudioPlayer.delegate = self
    }

    /// Renders a negotiated discovery result (result / no-match). Rendering
    /// never initiates playback — selection goes through
    /// `DiscoverySelectionHandler`.
    func presentDiscoveryResults(_ model: DiscoveryResultsViewModel) {
        resultsPresenter?.present(model)
    }

    func routeToCloud(request: String, tier: CloudTier, context: PlaybackContext) async -> VoiceResponse {
        guard isConfigured() else {
            // Same rule as the error path: a client-authored message is spoken
            // only in the user's own locale (spec ruling 2026-09-24).
            let comingSoon = spokenTemplates.resolveForUserLocale("general.cloud_coming_soon")
            return comingSoon.isEmpty ? .earcon(.error) : .spoken(comingSoon)
        }

        let client = clientFactory()
        let routeContext = CloudRouteContext(from: context)

        // Supersede any in-flight turn (double wake / barge-in) before touching
        // shared per-turn state.
        let turnToken = CloudTurnToken()
        activeTurn?.cancel()
        activeTurn = turnToken

        // One envelope per logical turn: a fresh client-assigned `request_id`
        // that any transport retry of this turn must reuse, capabilities gated
        // on the renderer, a typed-only hint and a bounded prior conversation.
        let turn = CloudTurnEnvelope.make(
            capabilities: CloudClientCapabilities.advertised(rendersStructuredResults: rendersStructuredResults),
            routeHint: routeHintProvider(),
            recentConversation: recentConversationProvider()
        )

        // Per-turn quote state is turn-scoped: without this reset a `stop_quote`
        // in a turn that issued no `play_quote` would seek to a previous turn's
        // captured position (task #12 PR review).
        preQuotePositionMs = nil

        // Hold the place for the turn: the server decides when the assistant
        // speaks, so the client does not pause on its own for a turn that may
        // not produce audio. The hold is only ours to release if it stopped
        // playback that was already running.
        //
        // A superseded turn leaves its hold in place (it returns without
        // restoring, deliberately: the winning turn does that). `isPlaying` is
        // therefore already false, and reading it here would lose the hold —
        // the user would be left paused for good. Inherit the outstanding hold
        // instead, so this turn releases it exactly once at its own end.
        if didAutoPause && wasPlayingBeforeHold {
            // Turn B started while A's hold was still in effect: B owns the
            // release now (A must not also resume — see the supersede tests).
            didAutoPause = true
        } else {
            wasPlayingBeforeHold = playbackSink.isPlaying
            if wasPlayingBeforeHold {
                _ = playbackSink.pause()
                didAutoPause = true
            }
        }

        turnLoop: for await event in client.route(request: request, context: routeContext, turn: turn) {
            // Superseded mid-stream: stop consuming so this turn cannot execute
            // late actions or overwrite the new turn's state. The stream's own
            // termination closes the transport. (`break turnLoop` — a bare
            // `break` inside the switch would only leave the switch.)
            if turnToken.isCancelled { break turnLoop }
            switch event {
            case let .connected(codec):
                // The server names the codec for this turn's binary frames;
                // the player decodes at that rate rather than the hardware's.
                audioPlayer.setNegotiatedCodec(codec)
            case let .audioFrame(frame):
                audioPlayer.enqueue(frame)
            case let .action(tool, action, params):
                executeAction(tool: tool, action: action, params: params)
            // .token is no longer accumulated — cloud answers are played as
            // audio, not text (spec: "cloud answers are played, not spoken").
            case .token:
                break
            case let .result(result):
                // Structured results are rendered as they arrive; the turn still
                // completes on `done` with the same restore/analytics behavior.
                presentDiscoveryResults(DiscoveryResultsViewModel(result: result))
            case let .done(usage):
                guard !turnToken.isCancelled else { break turnLoop }
                analytics?.recordCloudAssistantTurn(
                    outcome: "done",
                    inputTokens: usage.inputTokens,
                    outputTokens: usage.outputTokens
                )
                // Restore playback only once the answer has stopped coming out
                // of the speaker: `done` means the server has finished sending,
                // not that the client has finished playing, so restoring here
                // would resume the episode under the answer's tail. With nothing
                // left to play the drain is a no-op and the restore is immediate.
                if audioPlayer.hasPendingAudio {
                    restoreHeldForPlayerDrain = true
                } else {
                    restoreTransientAudioState()
                }
                audioPlayer.finish()
                return .silent
            case let .error(code, message):
                guard !turnToken.isCancelled else { break turnLoop }
                audioPlayer.cancel()
                restoreTransientAudioState()
                analytics?.recordCloudAssistantTurn(outcome: "error", inputTokens: nil, outputTokens: nil)
                // A server-supplied message passes through (localising it is the
                // server's job). When the client generated the diagnostic it
                // carries a code and an empty message instead of English prose:
                // resolve a localized template for that code if one exists, and
                // fall back to the error earcon when it doesn't (PR #19 review).
                // Whitespace-only counts as absent: a server message of spaces
                // would otherwise be "spoken" as silence, occupying the turn's
                // only feedback channel (PR #19 review).
                let serverMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
                let spoken = serverMessage.isEmpty
                    ? spokenTemplates.resolveForUserLocale("cloud_error_\(code)")
                    : serverMessage
                if spoken.isEmpty {
                    return .earcon(.error)
                }
                return .spoken(spoken)
            }
        }

        if turnToken.isCancelled {
            // The superseding turn owns pause/restore and analytics.
            return .silent
        }
        restoreTransientAudioState()
        return .silent
    }

    private func restoreTransientAudioState() {
        // Release only a hold we took, and only if it stopped playback the user
        // was already hearing. A hold that cannot be told apart from the user's
        // own pause must not be released — resuming here would start audio the
        // user asked to stop.
        if didAutoPause && wasPlayingBeforeHold {
            _ = playbackSink.resume()
        }
        didAutoPause = false
        wasPlayingBeforeHold = false
        // Seek positions are intentionally not rolled back.
    }

    private func executeAction(tool: String, action: String, params: [String: CloudRouteJSONValue]) {
        guard tool == "playback" else { return }

        switch action {
        case "seek_to":
            guard let referenceMs = params["reference_position_ms"]?.int64Value else { return }
            capturePreActionPosition(referenceMs: referenceMs)
            seekToReference(referenceMs)
        // Serve the quote. This does not take or release the hold: the quote
        // plays over playback the server has already ducked, and the turn's end
        // is the release (Task 12). Resuming here would end the duck early.
        case "play_quote":
            guard let referenceMs = params["reference_position_ms"]?.int64Value else { return }
            capturePreActionPosition(referenceMs: referenceMs)
            seekToReference(referenceMs)
        case "stop_quote":
            guard let restoreMs = preQuotePositionMs else { return }
            let seconds = Int((Double(restoreMs) / 1000.0).rounded())
            _ = playbackSink.seekTo(positionSeconds: seconds)
        case "seek_relative":
            // Per the recovery contract (PR 59, cloud-seek-relative):
            // Capture previous position so "go back to where I was" works
            // after a relative seek.
            capturePreActionPositionForRelativeSeek()
            // Zero delta is treated as "no stated amount" — the sink
            // applies its interval in the request's direction.
            let delta = params["delta_seconds"]?.int64Value
                .flatMap { Int($0) == 0 ? nil : Int($0) }
            // The parameter is a `CloudRouteJSONValue`; take its string. Typing
            // this as `String?` rather than `Any?` makes the compiler reject the
            // next call site that passes the wrapper where a string is wanted.
            let direction = seekDirectionOf(delta: delta, declared: params["direction"]?.stringValue)
            _ = playbackSink.seekRelative(deltaSeconds: delta, direction: direction)
        case "pause":
            _ = playbackSink.pause()
            didAutoPause = false
        case "resume":
            _ = playbackSink.resume()
            didAutoPause = false
        default:
            break // unknown action ignored (forward compatibility)
        }
    }

    private func capturePreActionPosition(referenceMs: Int64) {
        let previous = playbackPositionMs()
        preQuotePositionMs = previous
        cloudPlaybackContextState.record(
            referencePositionMs: referenceMs,
            previousReferencePositionMs: previous
        )
    }

    /// Capture the current playback position before a relative seek so that a
    /// subsequent "go back to where I was" restores the correct place. The
    /// recovery contract (PR 59, cloud-seek-relative) requires this for all
    /// relative seeks — not just `seek_to` / `play_quote`.
    private func capturePreActionPositionForRelativeSeek() {
        let previous = playbackPositionMs()
        preQuotePositionMs = previous
    }

    /// Resolve seek direction when a relative seek arrives.
    ///
    /// Per the recovery contract: the delta's sign is authoritative when a
    /// delta is present; `direction` decides only when it is absent. A request
    /// that stated neither takes the app's default forward interval.
    private func seekDirectionOf(delta: Int?, declared: String?) -> SeekDirection {
        if let delta {
            return delta < 0 ? .backward : .forward
        }
        if declared == "backward" { return .backward }
        if declared == "forward" { return .forward }
        return .forward // default: app's configurable interval
    }

    private func seekToReference(_ referenceMs: Int64) {
        let referenceSeconds = Double(referenceMs) / 1000.0
        let playbackSeconds = fingerprintMapper.playbackTime(forReferenceTime: referenceSeconds)
            ?? referenceSeconds
        let seconds = Int(playbackSeconds.rounded())
        // Negative positionSeconds is an offset back from the episode end.
        // Use the duration-aware overload so the sink resolves and bounds it.
        let durationSeconds = Int(playbackManager?.duration().rounded() ?? 0)
        _ = playbackSink.seekTo(positionSeconds: seconds, episodeDurationSeconds: durationSeconds)
    }
}

// MARK: - CloudAudioPlayer.Delegate

extension CloudRouteSink {
    func audioPlayerDidStartPlaying() {
        // Audio started — the sink doesn't need to react; the player
        // already managed the AVAudioEngine and playbackSink ducking
        // is handled by the sink's own pause/resume on action events.
    }

    func audioPlayerDidPause() {
        // Audio paused due to buffer underrun — the sink doesn't need
        // to react; the player will resume automatically when new
        // frames arrive.
    }

    func audioPlayerDidStop() {
        // The player has drained its buffer and stopped output. This is when a
        // hold taken for the turn may be released, so the answer is not played
        // over the resumed episode, and the turn's held state stays consistent
        // even though the sink has already returned to its caller.
        guard restoreHeldForPlayerDrain else { return }
        restoreHeldForPlayerDrain = false
        restoreTransientAudioState()
    }
}
