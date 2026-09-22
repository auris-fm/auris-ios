import Foundation
import PocketCastsUtils

/// Real cloud route sink: SSE client → action dispatch → TTS-on-done.
final class CloudRouteSink: VoiceCloudRouteSink {
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

    /// Playback position captured before `seek_to` / `play_quote` for `stop_quote`.
    private var preQuotePositionMs: Int64?
    /// True when this turn paused playback so we can restore on error.
    private var didAutoPause = false

    init(
        clientFactory: @escaping () -> CloudRouteClient = {
            CloudRouteClient(
                baseURL: CloudConfig.shared.baseUrl,
                userId: CloudIdentity.shared.userId
            )
        },
        isConfigured: @escaping () -> Bool = { !CloudConfig.shared.baseUrl.isEmpty },
        playbackSink: VoicePlaybackSink,
        fingerprintMapper: FingerprintMappingProviding,
        playbackPositionMs: @escaping () -> Int64,
        cloudPlaybackContextState: CloudPlaybackContextState,
        analytics: VoiceAnalytics? = nil,
        rendersStructuredResults: Bool = false,
        routeHintProvider: @escaping () -> CloudRouteHint? = { nil },
        recentConversationProvider: @escaping () -> [RecentConversationTurn] = { [] },
        resultsPresenter: DiscoveryResultsPresenting? = nil
    ) {
        self.clientFactory = clientFactory
        self.isConfigured = isConfigured
        self.playbackSink = playbackSink
        self.fingerprintMapper = fingerprintMapper
        self.playbackPositionMs = playbackPositionMs
        self.cloudPlaybackContextState = cloudPlaybackContextState
        self.analytics = analytics
        self.rendersStructuredResults = rendersStructuredResults
        self.routeHintProvider = routeHintProvider
        self.recentConversationProvider = recentConversationProvider
        self.resultsPresenter = resultsPresenter
    }

    /// Renders a negotiated discovery result (result / no-match). Rendering
    /// never initiates playback — selection goes through
    /// `DiscoverySelectionHandler`.
    func presentDiscoveryResults(_ model: DiscoveryResultsViewModel) {
        resultsPresenter?.present(model)
    }

    func routeToCloud(request: String, tier: CloudTier, context: PlaybackContext) async -> VoiceResponse {
        guard isConfigured() else {
            return .spoken(SpokenTemplateResolver().resolve("general.cloud_coming_soon"))
        }

        var tokenBuffer = ""
        let client = clientFactory()
        let routeContext = CloudRouteContext(from: context)

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

        // Pause for the turn; restore on done/error so TTS ducking runs over active playback.
        _ = playbackSink.pause()
        didAutoPause = true

        for await event in client.route(request: request, context: routeContext, turn: turn) {
            switch event {
            case let .action(tool, action, params):
                executeAction(tool: tool, action: action, params: params)
            case let .token(text):
                tokenBuffer += text
            case let .result(result):
                // Structured results are rendered as they arrive; the turn still
                // completes on `done` with the same restore/analytics behavior.
                presentDiscoveryResults(DiscoveryResultsViewModel(result: result))
            case let .done(inputTokens, outputTokens):
                analytics?.recordCloudAssistantTurn(
                    outcome: "done",
                    inputTokens: inputTokens,
                    outputTokens: outputTokens
                )
                restoreTransientAudioState()
                if tokenBuffer.isEmpty {
                    return .silent
                }
                return .spoken(tokenBuffer)
            case let .error(code, message):
                tokenBuffer = ""
                restoreTransientAudioState()
                analytics?.recordCloudAssistantTurn(outcome: "error", inputTokens: nil, outputTokens: nil)
                if message.isEmpty {
                    return .earcon(.error)
                }
                return .spoken(message)
            }
        }

        restoreTransientAudioState()
        return .silent
    }

    private func restoreTransientAudioState() {
        if didAutoPause {
            _ = playbackSink.resume()
            didAutoPause = false
        }
        // Seek positions are intentionally not rolled back.
    }

    private func executeAction(tool: String, action: String, params: [String: CloudRouteJSONValue]) {
        guard tool == "playback" else { return }

        switch action {
        case "seek_to":
            guard let referenceMs = params["reference_position_ms"]?.int64Value else { return }
            capturePreActionPosition(referenceMs: referenceMs)
            seekToReference(referenceMs)
        case "play_quote":
            guard let referenceMs = params["reference_position_ms"]?.int64Value else { return }
            capturePreActionPosition(referenceMs: referenceMs)
            seekToReference(referenceMs)
            _ = playbackSink.resume()
            didAutoPause = false
        case "stop_quote":
            guard let restoreMs = preQuotePositionMs else { return }
            let seconds = Int((Double(restoreMs) / 1000.0).rounded())
            _ = playbackSink.seekTo(positionSeconds: seconds)
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

    private func seekToReference(_ referenceMs: Int64) {
        let referenceSeconds = Double(referenceMs) / 1000.0
        let playbackSeconds = fingerprintMapper.playbackTime(forReferenceTime: referenceSeconds)
            ?? referenceSeconds
        let clamped = max(0, Int(playbackSeconds.rounded()))
        _ = playbackSink.seekTo(positionSeconds: clamped)
    }
}
