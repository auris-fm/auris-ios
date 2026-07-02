import AVFoundation
import PocketCastsUtils

class AVSpeechTtsEngine: NSObject, TtsEngineProtocol {
    private let synthesizer = AVSpeechSynthesizer()
    private var continuation: CheckedContinuation<Void, Never>?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func warmUp(language: String) {
        let utterance = AVSpeechUtterance(string: "")
        if let voice = bestVoice(for: language) {
            utterance.voice = voice
        }
        utterance.volume = 0
        synthesizer.speak(utterance)
    }

    func speak(text: String, language: String) async {
        FileLog.shared.addMessage("[VoiceControl/TTS] Speaking: \"\(text)\" (\(language))")
        // Cancel any in-progress utterance before starting the new one
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
            // Resume the old continuation so it doesn't hang
            continuation?.resume()
            continuation = nil
        }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            self.continuation = cont
            let utterance = AVSpeechUtterance(string: text)
            utterance.voice = bestVoice(for: language)
            utterance.rate = AVSpeechUtteranceDefaultSpeechRate
            synthesizer.speak(utterance)
        }
    }

    func cancel() {
        guard synthesizer.isSpeaking else { return }
        synthesizer.stopSpeaking(at: .immediate)
        continuation?.resume()
        continuation = nil
    }

    func release() {
        synthesizer.stopSpeaking(at: .immediate)
        continuation?.resume()
        continuation = nil
    }

    // MARK: - Voice Selection

    private func bestVoice(for language: String) -> AVSpeechSynthesisVoice {
        // Prefer enhanced quality voices (iOS 17+), fall back to default
        if #available(iOS 17.0, *) {
            if let enhanced = AVSpeechSynthesisVoice(language: language, quality: .enhanced) {
                return enhanced
            }
        }
        if let defaultVoice = AVSpeechSynthesisVoice(language: language, quality: .default) {
            return defaultVoice
        }
        // Last resort: any voice for the language, or en-US fallback
        return AVSpeechSynthesisVoice(language: language)
            ?? AVSpeechSynthesisVoice(language: "en-US")!
    }
}

// MARK: - AVSpeechSynthesizerDelegate

extension AVSpeechTtsEngine: AVSpeechSynthesizerDelegate {
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        continuation?.resume()
        continuation = nil
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        continuation?.resume()
        continuation = nil
    }
}
