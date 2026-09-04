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
        utterance.voice = bestVoice(for: language)
        utterance.volume = 0
        synthesizer.speak(utterance)
    }

    func speak(text: String, language: String) async {
        FileLog.shared.addMessage("[VoicePipeline] Speaking: \"\(text)\" (\(language))")
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

    func releaseEngine() {
        synthesizer.stopSpeaking(at: .immediate)
        continuation?.resume()
        continuation = nil
    }

    // MARK: - Voice Selection

    private func bestVoice(for language: String) -> AVSpeechSynthesisVoice {
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
