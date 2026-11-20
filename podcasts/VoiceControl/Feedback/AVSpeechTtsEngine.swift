import AVFoundation
import PocketCastsUtils

/// The surface of AVSpeechSynthesizer the engine uses, so tests can supply a
/// synthesizer that never delivers callbacks — the failure a headless CI runner
/// produces, where the hang is real rather than simulated.
protocol SpeechSynthesizing: AnyObject {
    var delegate: AVSpeechSynthesizerDelegate? { get set }
    var isSpeaking: Bool { get }
    func speak(_ utterance: AVSpeechUtterance)
    @discardableResult func stopSpeaking(at boundary: SpeechBoundary) -> Bool
}

typealias SpeechBoundary = AVSpeechBoundary

final class SystemSpeechSynthesizer: AVSpeechSynthesizer, SpeechSynthesizing {}

class AVSpeechTtsEngine: NSObject, TtsEngineProtocol {
    private let synthesizer: SpeechSynthesizing
    /// How long `speak` waits for a delegate callback before resuming anyway.
    /// A synthesizer without a usable audio route can silently never start an
    /// utterance, and without this the waiter hangs forever.
    private let callbackTimeout: TimeInterval
    private var continuation: CheckedContinuation<Void, Never>?
    /// The utterance the stored continuation waits on. Callbacks for older
    /// utterances must not resume it: after a cancel-then-speak, a late
    /// `didCancel` for the old utterance arrives while the new utterance's
    /// continuation is already stored.
    private var awaitedUtterance: AVSpeechUtterance?
    private let stateLock = NSLock()

    init(synthesizer: SpeechSynthesizing = SystemSpeechSynthesizer(),
         callbackTimeout: TimeInterval = 10) {
        self.synthesizer = synthesizer
        self.callbackTimeout = callbackTimeout
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
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let utterance = AVSpeechUtterance(string: text)
            utterance.voice = self.bestVoice(for: language)
            utterance.rate = AVSpeechUtteranceDefaultSpeechRate
            self.storeContinuation(cont, for: utterance)
            self.synthesizer.speak(utterance)
            self.scheduleFallbackResume(for: utterance)
        }
    }

    func cancel() {
        synthesizer.stopSpeaking(at: .immediate)
        // .immediate does not reliably deliver didCancel; the waiter must not
        // outlive the cancel that ended its utterance.
        resumeIfCurrent(awaitedUtterance, reason: "cancel")
    }

    func releaseEngine() {
        synthesizer.stopSpeaking(at: .immediate)
        resumeIfCurrent(awaitedUtterance, reason: "release")
    }

    // MARK: - Continuation state

    /// Resumes the waiter only when it still belongs to `utterance`, and only
    /// once. Every resume path — delegate callback, fallback timer, cancel,
    /// a superseding speak — goes through here, so a callback racing a
    /// fallback can never resume a continuation twice.
    private func resumeIfCurrent(_ utterance: AVSpeechUtterance?, reason: String) {
        stateLock.lock()
        guard continuation != nil, utterance === awaitedUtterance else {
            stateLock.unlock()
            return
        }
        let cont = continuation
        continuation = nil
        awaitedUtterance = nil
        stateLock.unlock()
        FileLog.shared.addMessage("[VoicePipeline] TTS speak resumed (\(reason))")
        cont?.resume()
    }

    /// A new `speak` abandons the previous waiter: the synthesizer has moved
    /// on, so its callbacks now describe a different utterance, and leaving
    /// the old waiter stored would let the old utterance's callbacks resume
    /// the new waiter.
    private func storeContinuation(_ cont: CheckedContinuation<Void, Never>, for utterance: AVSpeechUtterance) {
        synthesizer.stopSpeaking(at: .immediate)
        resumeIfCurrent(awaitedUtterance, reason: "superseded")
        stateLock.lock()
        continuation = cont
        awaitedUtterance = utterance
        stateLock.unlock()
    }

    private func scheduleFallbackResume(for utterance: AVSpeechUtterance) {
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64((self?.callbackTimeout ?? 10) * 1_000_000_000))
            self?.resumeIfCurrent(utterance, reason: "callback timeout")
        }
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
        resumeIfCurrent(utterance, reason: "didFinish")
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        resumeIfCurrent(utterance, reason: "didCancel")
    }
}
