import AVFoundation

class AVSpeechTtsEngine: TtsEngineProtocol {
    private let synthesizer = AVSpeechSynthesizer()
    private var isSpeaking = false

    func warmUp(language: String) {
        let utterance = AVSpeechUtterance(string: "")
        if let voice = AVSpeechSynthesisVoice(language: language) {
            utterance.voice = voice
        }
        utterance.volume = 0
        synthesizer.speak(utterance)
    }

    func speak(text: String, language: String) async {
        if isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let utterance = AVSpeechUtterance(string: text)
            utterance.voice = bestVoice(for: language)
            utterance.rate = AVSpeechUtteranceDefaultSpeechRate
            isSpeaking = true
            synthesizer.speak(utterance)
            // Completion is handled via AVSpeechSynthesizerDelegate
            // For now, resume after a reasonable delay
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(text.count * 60)) { [weak self] in
                self?.isSpeaking = false
                continuation.resume()
            }
        }
    }

    func release() { synthesizer.stopSpeaking(at: .immediate) }

    private func bestVoice(for language: String) -> AVSpeechSynthesisVoice {
        return AVSpeechSynthesisVoice(language: language)
            ?? AVSpeechSynthesisVoice(language: "en-US")!
    }
}
