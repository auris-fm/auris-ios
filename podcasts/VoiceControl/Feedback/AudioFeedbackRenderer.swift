class AudioFeedbackRenderer {
    private let earconPlayer: EarconPlayer
    private let ttsEngine: TtsEngineProtocol

    init(earconPlayer: EarconPlayer, ttsEngine: TtsEngineProtocol) {
        self.earconPlayer = earconPlayer
        self.ttsEngine = ttsEngine
    }

    func render(_ response: VoiceResponse) {
        switch response {
        case .silent:
            break
        case .earcon(let id):
            earconPlayer.play(id)
        case .spoken(let text):
            Task {
                await ttsEngine.speak(text: text, language: currentLanguage)
            }
        }
    }

    func playEarcon(_ id: EarconId) {
        render(.earcon(id))
    }

    private var currentLanguage: String {
        Locale.current.language.languageCode?.identifier ?? "en"
    }
}
