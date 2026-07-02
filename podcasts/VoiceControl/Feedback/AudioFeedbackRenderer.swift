import Foundation

class AudioFeedbackRenderer {
    private let earconPlayer: EarconPlayer
    private let ttsEngine: TtsEngineProtocol
    private let ducker: AudioSessionDucker
    private var renderTask: Task<Void, Never>?

    init(earconPlayer: EarconPlayer, ttsEngine: TtsEngineProtocol, ducker: AudioSessionDucker = AudioSessionDucker()) {
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

    func playEarcon(_ id: EarconId) {
        render(.earcon(id))
    }

    func release() {
        renderTask?.cancel()
        ttsEngine.cancel()
        ttsEngine.release()
        earconPlayer.release()
    }

    private var currentLanguage: String {
        Locale.current.language.languageCode?.identifier ?? "en"
    }
}
