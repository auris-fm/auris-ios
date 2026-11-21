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
    /// How long `speak` waits for the synthesizer to go silent — no start, no
    /// speech-progress, no finish — before resuming anyway. A synthesizer
    /// without a usable audio route never starts an utterance at all, and
    /// without this the waiter hangs forever. A long utterance that IS speaking
    /// keeps resetting the window, so it is never cut off mid-sentence.
    private let silenceTimeout: TimeInterval
    private var continuation: CheckedContinuation<Void, Never>?
    /// The utterance the stored continuation waits on. Callbacks for older
    /// utterances must not resume it: after a cancel-then-speak, a late
    /// `didCancel` for the old utterance arrives while the new utterance's
    /// continuation is already stored.
    private var awaitedUtterance: AVSpeechUtterance?
    /// Bumped on every arm/rearm and every resume. A timer captures the
    /// generation it was armed with and may only fire while that generation is
    /// still current — checked under the same lock that claims the
    /// continuation, so a timer that expired just before a progress callback
    /// rearmed can never resume early.
    private var fallbackGeneration: UInt64 = 0
    private var fallbackTask: Task<Void, Never>?
    private let stateLock = NSLock()

    init(synthesizer: SpeechSynthesizing = SystemSpeechSynthesizer(),
         silenceTimeout: TimeInterval = 10) {
        self.synthesizer = synthesizer
        self.silenceTimeout = silenceTimeout
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
    private func resumeIfCurrent(_ utterance: AVSpeechUtterance?, reason: String, generation: UInt64? = nil) {
        stateLock.lock()
        guard continuation != nil, utterance === awaitedUtterance else {
            stateLock.unlock()
            return
        }
        if let generation, generation != fallbackGeneration {
            // The timer expired, but progress rearmed since: not our window.
            stateLock.unlock()
            return
        }
        let cont = continuation
        continuation = nil
        awaitedUtterance = nil
        fallbackGeneration &+= 1
        fallbackTask?.cancel()
        fallbackTask = nil
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
        // Swap atomically: two overlapping starts must not both see an empty
        // slot and overwrite each other's waiter. The displaced waiter is
        // resumed outside the lock.
        stateLock.lock()
        let displaced = continuation
        continuation = cont
        awaitedUtterance = utterance
        fallbackGeneration &+= 1
        fallbackTask?.cancel()
        fallbackTask = nil
        stateLock.unlock()
        if displaced != nil {
            FileLog.shared.addMessage("[VoicePipeline] TTS speak resumed (superseded)")
            displaced?.resume()
        }
    }

    /// Arms (or rearms) the silence timer for `utterance`. Every sign of
    /// life from the synthesizer — start, speech progress — calls this, so the
    /// timer fires only when the synthesizer has gone quiet without finishing.
    private func scheduleFallbackResume(for utterance: AVSpeechUtterance) {
        stateLock.lock()
        guard utterance === awaitedUtterance else {
            stateLock.unlock()
            return
        }
        fallbackTask?.cancel()
        fallbackGeneration &+= 1
        let generation = fallbackGeneration
        let timeout = silenceTimeout
        fallbackTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.resumeIfCurrent(utterance, reason: "silence timeout", generation: generation)
        }
        stateLock.unlock()
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

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        scheduleFallbackResume(for: utterance)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, willSpeakRangeOfSpeechString characterRange: NSRange, utterance: AVSpeechUtterance) {
        scheduleFallbackResume(for: utterance)
    }
}
