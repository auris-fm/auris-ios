import Foundation
import PocketCastsUtils

/// Real cloud route sink: WebSocket client → audio player → action dispatch.
///
/// Cloud answers arrive as synthesised audio streamed over the WebSocket; the
/// client plays them directly through the shared audio output path. Text
/// accumulation (`.token`) is removed — cloud answers are played, not spoken.
/// How a cloud turn actually ended, reported separately from how it was rendered.
///
/// The rendered response cannot carry this: a spoken server error and a silent success
/// are both "no earcon", so a caller deciding what happened from the response shape gets
/// them backwards — which is how a failed turn was recorded as a completed cloud route
/// and reopened the grace window for a turn that never happened.
enum CloudRouteOutcome: Equatable {
    /// The server sent `done`: the turn completed.
    case completed
    /// The server reported an error, or the route could not be dialled.
    case failed(code: String?)
    /// The stream ended without `done`: a truncated turn, not a completion.
    case earlyClose
    /// Cloud is not configured, so no turn was attempted.
    case refused
}

/// A turn's terminal outcome together with the feedback it rendered.
struct CloudRouteResult: Equatable {
    let response: VoiceResponse
    let outcome: CloudRouteOutcome
    /// The handle to the request THIS call prepared, returned WITH the outcome.
    ///
    /// A published "last handle" slot would let a successor replace it before an older caller
    /// read it, so the older caller would retry the wrong request — the "last" problem again, one
    /// level up. Riding on the result means a caller can only hold the handle for the call it
    /// actually made. Nil when no request was prepared (refused before preparation, or a re-drive).
    var retainedPreparation: CloudRouteSink.RetainedPreparation?
}

final class CloudRouteSink: VoiceCloudRouteSink,
                            CloudAudioPlayer.Delegate {

    /// The active turn's cancellation state, readable so a test can observe whether a refused
    /// turn cancelled its predecessor. The cancellation is a FLAG the running turn checks at its
    /// next event, so a held turn has not yet acted on it — reading the flag is what distinguishes
    /// "cancelled but not yet observed" from "never cancelled".
    /// Main-actor isolated like the rest of the sink: `activeTurn` is actor state, so the read
    /// must be too. A test awaits it through `MainActor.run`.
    var activeTurnIsCancelledForTesting: Bool? { activeTurn?.isCancelled }

    /// The selection the last turn arrived with, so a caller-level case can assert that the
    /// service derived it from the turn's own provenance rather than from live window state.
    /// Necessary because the two are indistinguishable from inside the sink when grace is active.
    @MainActor private(set) var lastSelectionForTesting: CloudConversationSelection?

    /// The cloud player this sink drives, so a test can reach the real producer through
    /// the chain the app builds rather than constructing its own.
    var audioPlayerForTesting: CloudAudioPlayer? { audioPlayer }
    private let clientFactory: () -> CloudRouteClient
    private let isConfigured: () -> Bool
    /// Prepares the conversation identity for each turn.
    private let conversationManager: CloudConversationManager
    /// What selected the current turn. Defaults to a wake word: a turn with no reported
    /// selection is a new user act, and create-then-resume is the safe direction — resuming
    /// a conversation nobody opened would attach an utterance to someone else's history.
    private let conversationSelectionProvider: () -> CloudConversationSelection
    /// The origin the turn runs under, so a resume cannot cross an ended window.

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

    /// The last prepared logical request, retained so an EXPLICIT retry can re-drive it with the
    /// same ids. Retaining the envelope rather than rebuilding it is what makes identity
    /// preservation structural: a retry has no other source for its `request_id`.
    /// A handle to one prepared logical request, returned to the OWNER so a retry can be
    /// request-scoped rather than "the last thing prepared".
    ///
    /// Holding the id (rather than letting the caller reach for whatever was prepared most
    /// recently) is what stops an older retry selecting a successor. The owning lifecycle
    /// invalidates it: `invalidateRetained(_:)` drops the entry, and a handle whose entry is gone
    /// refuses rather than re-driving something else.
    struct RetainedPreparation: Equatable {
        let requestId: String
    }

    /// The COMPLETE prepared logical request. Every field the original attempt used is retained,
    /// because re-driving with substitutes would send a DIFFERENT request under the same ids — the
    /// ids would be preserved while the request was not, which is worse than not retrying.
    private struct PreparedRequest {
        let turn: CloudTurnEnvelope
        let request: String
        let tier: CloudTier
        let playbackContext: PlaybackContext
        /// The origin captured when the request was prepared. A retry must be validated against
        /// the origin it belonged to, not whatever is current when the retry is invoked.
        let origin: Int?
        /// The selection captured with the request, for the same reason.
        let selection: CloudConversationSelection?
    }

    /// Prepared requests keyed by their `request_id`, NOT a single "last" slot.
    ///
    /// A global "last" would let an OLDER retry select a SUCCESSOR: the successor is prepared
    /// later, so it would be the one a "last" lookup returned, and the retry would re-drive a turn
    /// the caller never named — with the wrong identity, which is the opposite of the point. Keyed
    /// by the id the caller is retrying, a request can only be re-driven by naming it.
    private var preparedRequests: [String: PreparedRequest] = [:]

    /// Drops a retained request when its owning lifecycle ends, so a later retry of it refuses
    /// instead of re-driving a request that no longer belongs to anything.
    func invalidateRetained(_ handle: RetainedPreparation) {
        preparedRequests.removeValue(forKey: handle.requestId)
    }

    /// Re-drives the last prepared logical request, preserving its `request_id`, conversation id
    /// and mode.
    ///
    /// **Only call this for a transport that dropped BEFORE admission.** The identity requirement
    /// does not authorize replaying a turn after an unknown outcome: a turn whose admission may
    /// have landed is not safe to resubmit, and the failure that reaches here must be one the
    /// caller has established as pre-admission. That is why this is an explicit entry point rather
    /// than a loop around `client.route`.
    ///
    /// Returns nil when there is nothing retained to re-drive, so a caller cannot mistake an
    /// absent request for a successful retry.
    /// The origin a retry must still belong to, supplied by the OWNER (the executor, which knows
    /// the turn's window). `nil` means liveness cannot be established, and the retry refuses.
    ///
    /// There is no production binding yet, so today this refuses every retry — which is the
    /// correct default while the owner is unwired: a retry that cannot establish its window must
    /// not re-drive, and failing closed is what makes the missing wiring visible instead of
    /// letting unowned retries through.
    var liveOriginForRetry: () -> Int? = { nil }

    func retryLastPreparedRequest(requestId: String) async -> CloudRouteResult? {
        // Refuse BEFORE `route()`, which is where `activeTurn.cancel()` and the output
        // registration happen: an absent or retired retry must not disturb a successor. Retiring
        // the entry on use also stops a second retry of the same turn re-driving it again.
        guard let prepared = preparedRequests.removeValue(forKey: requestId) else { return nil }
        // A retired origin cannot re-drive: the request belonged to a window that is gone, and
        // re-driving it would attribute the turn to whatever window is current now.
        // FAIL CLOSED on an unestablished origin. An earlier version skipped this guard when the
        // captured origin was nil, which means "we do not know what window this belonged to" was
        // treated as permission to re-drive it — the opposite reading. Liveness must be
        // ESTABLISHED, and an unknown live origin cannot establish anything.
        guard let requestOrigin = prepared.origin,
              let liveOrigin = liveOriginForRetry(),
              requestOrigin == liveOrigin
        else { return nil }
        // Re-enters the single-attempt path with the RETAINED envelope, so the ids on the wire are
        // the originals by construction. Passing the retained turn through means the retry cannot
        // mint a fresh id even by mistake.
        // The CAPTURED origin, not nil: a retry belongs to the window its request was prepared
        // under, and passing nil would drop it to the sink's live-state fallback — reintroducing
        // the very attribution error the captured origin exists to prevent.
        return await route(
            request: prepared.request,
            tier: prepared.tier,                        // retained, not substituted
            context: prepared.playbackContext,          // retained, not `absent`
            origin: prepared.origin,
            selection: prepared.selection,
            retainedTurn: prepared.turn   // retained: same request_id, same conversation id
        )
    }

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
        spokenTemplates: SpokenTemplateResolver = SpokenTemplateResolver(),
        // Last so a call site can always supply them after whatever other defaults it uses.
        conversationManager: CloudConversationManager = CloudConversationManager(),
        conversationSelectionProvider: @escaping () -> CloudConversationSelection = { .wakeWord }
    ) {
        self.clientFactory = clientFactory
        self.isConfigured = isConfigured
        self.conversationManager = conversationManager
        self.conversationSelectionProvider = conversationSelectionProvider
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

    /// - Parameter retainedTurn: a previously prepared logical request to re-drive. Passed ONLY by
    ///   `retryLastPreparedRequest`, so the ids on the wire are the originals rather than freshly
    ///   minted — the identity requirement is then structural, not a convention each caller must
    ///   remember.
    func routeToCloud(
        request: String,
        tier: CloudTier,
        context: PlaybackContext,
        origin: Int?,
        selection: CloudConversationSelection?
    ) async -> CloudRouteResult {
        await route(request: request, tier: tier, context: context, origin: origin,
                    selection: selection, retainedTurn: nil)
    }

    /// The shared body. `retainedTurn`, when present, is a previously prepared logical request
    /// being re-driven, so its ids are the originals rather than freshly minted.
    private func route(
        request: String,
        tier: CloudTier,
        context: PlaybackContext,
        origin: Int?,
        selection: CloudConversationSelection?,
        retainedTurn: CloudTurnEnvelope?
    ) async -> CloudRouteResult {
        // Recorded BEFORE any guard: what selected this turn is a property of the TURN, not of
        // whether the sink happens to be configured. Recording after the configured check made
        // the seam blind to exactly the refused turns a caller-level case most needs to observe.
        MainActor.assumeIsolated {
            lastSelectionForTesting = selection ?? (try? conversationSelectionProvider())
        }
        guard isConfigured() else {
            // Same rule as the error path: a client-authored message is spoken
            // only in the user's own locale (spec ruling 2026-09-24).
            let comingSoon = spokenTemplates.resolveForUserLocale("general.cloud_coming_soon")
            return CloudRouteResult(
                response: comingSoon.isEmpty ? .earcon(.error) : .spoken(comingSoon),
                outcome: .refused
            )
        }

        // The conversation identity is prepared FIRST, before anything this turn can disturb.
        // A nil result means the origin is NOT LIVE: this turn has no claim on any conversation,
        // so it is refused — and it must be refused before touching successor-owned state. The
        // supersede block below cancels the in-flight turn and claims `activeTurn`; running that
        // for a turn that is then refused would let a stale dispatch CANCEL a live successor and
        // leave the sink pointing at a token nobody will ever complete.
        let effectiveSelection = selection ?? conversationSelectionProvider()
        // A RETRY must not re-prepare: `prepare` can select or mint a conversation, and cancelling
        // `activeTurn` after that would disturb a successor for a turn that already has its own
        // identity. The retained envelope already carries the conversation it was admitted under,
        // so a re-drive uses that and touches none of the preparation path.
        // A RETRY does not re-prepare: `prepare` can select or mint a conversation, and cancelling
        // `activeTurn` after that would disturb a successor for a turn that already has its own
        // identity. The retained envelope names its conversation, so a re-drive takes it from
        // there — and then flows into the SAME event loop below, because a retry that handled a
        // subset of events would report success while delivering none of the answer.
        //
        // There is deliberately NO second event loop: `route` handles connected/codec, audioFrame,
        // token, action, result, done and error in one place, and a parallel path would diverge
        // from it the moment either changed.
        let conversation: CloudPreparedConversation
        // The handle for THIS call's preparation, returned with the outcome. Nil on a re-drive,
        // which prepares nothing.
        var preparationHandle: RetainedPreparation?
        if let retainedTurn, let retainedConversation = retainedTurn.conversation {
            conversation = retainedConversation
        } else {
            guard let prepared = conversationManager.prepare(
                // The captured selection when the caller supplied one; the provider is the
                // fallback for callers that did not, which is the late-reading behaviour this
                // replaces.
                selection: effectiveSelection,
                origin: origin
            ) else {
                return CloudRouteResult(response: .silent, outcome: .refused)
            }
            conversation = prepared
            preparationHandle = RetainedPreparation(requestId: prepared.requestId)
        }

        let client = clientFactory()
        let routeContext = CloudRouteContext(from: context)

        // Supersede any in-flight turn (double wake / barge-in) before touching
        // shared per-turn state. Only a turn that will actually run supersedes.
        let turnToken = CloudTurnToken()
        activeTurn?.cancel()
        activeTurn = turnToken

        let turn = retainedTurn ?? CloudTurnEnvelope.make(
            capabilities: CloudClientCapabilities.advertised(rendersStructuredResults: rendersStructuredResults),
            routeHint: routeHintProvider(),
            recentConversation: recentConversationProvider(),
            conversation: conversation
        )
        // Retained so an EXPLICIT retry can re-drive the SAME logical request. Holding the whole
        // envelope is what makes identity preservation structural rather than a convention: a
        // retry has nothing else to build an id from.
        //
        // There is deliberately NO blanket retry loop here. The identity requirement does not
        // authorize replaying a turn after an UNKNOWN outcome — only a transport that dropped
        // before admission is safe to re-drive, and that decision belongs to an explicit caller.
        preparedRequests[turn.requestId] = PreparedRequest(
            turn: turn,
            request: request,
            tier: tier,
            playbackContext: context,
            origin: origin,
            selection: effectiveSelection
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
                return CloudRouteResult(response: .silent, outcome: .completed,
                                    retainedPreparation: preparationHandle)
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
                    return CloudRouteResult(response: .earcon(.error), outcome: .failed(code: code),
                                            retainedPreparation: preparationHandle)
                }
                return CloudRouteResult(response: .spoken(spoken), outcome: .failed(code: code),
                                        retainedPreparation: preparationHandle)
            }
        }

        if turnToken.isCancelled {
            // The superseding turn owns pause/restore and analytics. Superseded is not a
            // completion: the winner's turn decides the window, and reporting this one as
            // completed would let a turn that was cancelled mid-stream reopen it.
            return CloudRouteResult(response: .silent, outcome: .earlyClose,
                                    retainedPreparation: preparationHandle)
        }
        restoreTransientAudioState()
        // The stream ended without `done`: the turn was truncated, which is not a
        // completion and must not restore the allowance as though the model answered.
        return CloudRouteResult(response: .silent, outcome: .earlyClose,
                                retainedPreparation: preparationHandle)
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
            // Two forms, per the wire contract's schema (app_operation_schema_map 11993ca):
            // "ordinary" carries position_seconds in SINK time and seeks directly;
            // "reference_target" carries reference_position_ms and requires the validated
            // mapping. Both or neither is a malformed request, not a default to guess.
            let sinkSeconds = params["position_seconds"]?.int64Value
            let referenceMs = params["reference_position_ms"]?.int64Value
            switch (sinkSeconds, referenceMs) {
            case (let seconds?, nil):
                seekToSinkSeconds(seconds)
            case (nil, let reference?):
                capturePreActionPosition(referenceMs: reference)
                seekToReference(reference)
            default:
                recordSeekRejection(.nonSuccess(.refused, reason: OperationReason.malformedSeekTarget))
            }
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

    /// Records that a reference-time seek could not be mapped to playback time.
    ///
    /// The unavailable mapping is the operation's outcome: no position was changed, and the
    /// reason the server is told is that this client cannot convert the target — not that it
    /// sought somewhere arbitrary.
    private func recordReferenceSeekUnavailable(referenceMs: Int64) {
        unavailableReferenceSeek = OperationResult.nonSuccess(
            .refused,
            reason: OperationReason.referenceMappingUnavailable
        )
    }

    /// The most recent unavailable-reference-seek outcome, consumed by the executor.
    private(set) var unavailableReferenceSeek: OperationResult?

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

    /// Seeks to an absolute position in SINK time — the ordinary form, no mapping involved.
    ///
    /// Signed values are allowed: the duration-aware sink overload resolves a negative
    /// position as an offset back from the episode end, matching how the local path behaves.
    private func seekToSinkSeconds(_ seconds: Int64) {
        let durationSeconds = Int(playbackManager?.duration().rounded() ?? 0)
        _ = playbackSink.seekTo(positionSeconds: Int(seconds), episodeDurationSeconds: durationSeconds)
    }

    private func recordSeekRejection(_ result: OperationResult) {
        lastSeekRejection = result
    }

    /// The most recent malformed-seek rejection, consumed by the executor.
    @MainActor private(set) var lastSeekRejection: OperationResult?

    private func seekToReference(_ referenceMs: Int64) {
        let referenceSeconds = Double(referenceMs) / 1000.0
        // Reference time is not playback time. The two happen to coincide on an unmapped
        // episode, but taking the fallback when the mapping is *missing* silently seeks to a
        // position the server never asked for — on a mapped episode that is the wrong place,
        // and nothing downstream can tell it apart from a correct seek. So an unavailable
        // mapping is reported as unavailable rather than converted by assumption.
        guard let playbackSeconds = fingerprintMapper.playbackTime(forReferenceTime: referenceSeconds) else {
            recordReferenceSeekUnavailable(referenceMs: referenceMs)
            return
        }
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
