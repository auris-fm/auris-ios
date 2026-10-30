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

    /// Observer for the earcon request, so a control can assert the presentation the user would
    /// hear without the production renderer retaining a history.
    ///
    /// Deliberately not a stored array: nothing in production needs the history, and an unbounded
    /// one would grow for the life of the process purely to satisfy tests.
    var earconObserverForTesting: ((EarconId) -> Void)?

    func playEarcon(_ id: EarconId) {
        earconObserverForTesting?(id)
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
