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
        analytics: VoiceAnalytics? = nil
    ) {
        self.clientFactory = clientFactory
        self.isConfigured = isConfigured
        self.playbackSink = playbackSink
        self.fingerprintMapper = fingerprintMapper
        self.playbackPositionMs = playbackPositionMs
        self.cloudPlaybackContextState = cloudPlaybackContextState
        self.analytics = analytics
    }

    func routeToCloud(request: String, tier: CloudTier, context: PlaybackContext) async -> VoiceResponse {
        guard isConfigured() else {
            return .spoken(SpokenTemplateResolver().resolve("general.cloud_coming_soon"))
        }

        var tokenBuffer = ""
        let client = clientFactory()
        let routeContext = CloudRouteContext(from: context)

        // Pause for the turn; restore on done/error so TTS ducking runs over active playback.
        _ = playbackSink.pause()
        didAutoPause = true

        for await event in client.route(request: request, context: routeContext) {
            switch event {
            case let .action(tool, action, params):
                executeAction(tool: tool, action: action, params: params)
            case let .token(text):
                tokenBuffer += text
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
            case let .error(_, message):
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
