import Foundation

class AudioFeedbackRenderer {
    private let earconPlayer: EarconPlayer
    private let ttsEngine: TtsEngineProtocol
    private let ducker: any AudioSessionDucking
    private var renderTask: Task<Void, Never>?

    init(earconPlayer: EarconPlayer, ttsEngine: TtsEngineProtocol, ducker: any AudioSessionDucking = AudioSessionDucker()) {
        self.earconPlayer = earconPlayer
        self.ttsEngine = ttsEngine
        self.ducker = ducker
    }

    func render(_ response: VoiceResponse, language: String? = nil) {
        // Cancel any in-progress render before starting a new one
        renderTask?.cancel()
        ttsEngine.cancel()

        let lang = language ?? currentLanguage

        renderTask = Task {
            switch response {
            case .silent:
                break
            case .earcon(let id):
                guard earconPlayer.hasEarcon(id) else { break }
                ducker.duck()
                earconPlayer.play(id)
                // Earcon playback is synchronous and short; unduck after a brief delay
                try? await Task.sleep(nanoseconds: 200_000_000) // 0.2s
                ducker.unduck()
            case .spoken(let text):
                guard !Task.isCancelled else { return }
                ducker.duck()
                await ttsEngine.speak(text: text, language: lang)
                ducker.unduck()
            case .combined(let earcon, let spokenText):
                guard !Task.isCancelled else { return }
                ducker.duck()
                earconPlayer.play(earcon)
                await ttsEngine.speak(text: spokenText, language: lang)
                ducker.unduck()
            }
        }
    }

    /// Every earcon the service asks for, so a control can assert which feedback the user would
    /// actually hear instead of inferring it from a call site.
    private(set) var playedEarcons: [EarconId] = []

    func playEarcon(_ id: EarconId) {
        playedEarcons.append(id)
        render(.earcon(id))
    }

    func release() {
        renderTask?.cancel()
        ttsEngine.cancel()
        ttsEngine.releaseEngine()
        earconPlayer.release()
    }

    private var currentLanguage: String {
        Locale.current.language.languageCode?.identifier ?? "en"
    }
}
