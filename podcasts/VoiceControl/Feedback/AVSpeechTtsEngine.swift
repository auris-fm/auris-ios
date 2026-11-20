import AVFoundation
import PocketCastsUtils

/// The surface of AVSpeechSynthesizer the engine uses, so tests can supply a
/// synthesizer that never delivers callbacks — the failure a headless CI runner
/// produces, where the hang is real rather than simulated.
typealias SpeechBoundary = AVSpeechBoundary

protocol SpeechSynthesizing: AnyObject {
    var delegate: AVSpeechSynthesizerDelegate? { get set }
    var isSpeaking: Bool { get }
    func speak(_ utterance: AVSpeechUtterance)
    @discardableResult func stopSpeaking(at boundary: SpeechBoundary) -> Bool
}

final class SystemSpeechSynthesizer: AVSpeechSynthesizer, SpeechSynthesizing {}

class AVSpeechTtsEngine: NSObject, TtsEngineProtocol {
    private let synthesizer: SpeechSynthesizing
    private var continuation: CheckedContinuation<Void, Never>?

    init(synthesizer: SpeechSynthesizing = SystemSpeechSynthesizer()) {
        self.synthesizer = synthesizer
        super.init()
        self.synthesizer.delegate = self
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
            utterance.voice = self.bestVoice(for: language)
            utterance.rate = AVSpeechUtteranceDefaultSpeechRate
            self.synthesizer.speak(utterance)
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
