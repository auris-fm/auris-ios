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
    /// The boundary every start, stop, cancel and release goes through.
    ///
    /// `AudioFeedbackRenderer.render` cancels the previous render task and
    /// starts a new one without joining it, and neither this engine nor that
    /// renderer is actor-isolated, so two starts genuinely can be inside the
    /// start sequence at once. Serializing here — rather than at the renderer
    /// — is what makes "a start that has been superseded must not speak" true
    /// regardless of which caller got there second.
    private let stateLock = NSLock()
    /// Identifies the newest start. A start claims a number at entry and may
    /// only enqueue speech and store its waiter while that number is still the
    /// newest, so a start that a later start overtook becomes a no-op instead
    /// of speaking over it or displacing its waiter.
    ///
    /// Claimed through `stateLock` at the top of `speak`, before the boundary
    /// is taken for the store, so a start that is still preparing can be
    /// overtaken by one that arrives later.
    private var startGeneration: UInt64 = 0

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
        let generation = self.claimStart()
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let utterance = AVSpeechUtterance(string: text)
            utterance.voice = self.bestVoice(for: language)
            utterance.rate = AVSpeechUtteranceDefaultSpeechRate
            self.start(cont, utterance: utterance, generation: generation)
        }
    }

    /// Claims the next start number. Taken before the utterance is built and
    /// before the boundary, so a start that is overtaken while preparing can
    /// tell that it lost.
    private func claimStart() -> UInt64 {
        stateLock.lock()
        startGeneration &+= 1
        let claimed = startGeneration
        stateLock.unlock()
        return claimed
    }

    func cancel() {
        synthesizer.stopSpeaking(at: .immediate)
        // .immediate does not reliably deliver didCancel; the waiter must not
        // outlive the cancel that ended its utterance. The waiter is claimed
        // inside the boundary rather than read first and compared after.
        resumeCurrent(reason: "cancel")
    }

    func releaseEngine() {
        synthesizer.stopSpeaking(at: .immediate)
        resumeCurrent(reason: "release")
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

    /// The start sequence, run entirely inside the boundary.
    ///
    /// Two starts can enter this concurrently — `AudioFeedbackRenderer.render`
    /// cancels the render task it is replacing without joining it, and nothing
    /// in that chain is actor-isolated — so the boundary, not the caller, is
    /// what orders them.
    ///
    /// Each start claims a generation number at entry and only enqueues speech
    /// and stores its waiter while that number is still the newest. The claim
    /// happens on the first line, before the work, so a start that a later
    /// start overtook while it was building its utterance becomes a no-op: it
    /// neither talks over the winner nor installs a waiter nothing would
    /// resume.
    private func start(_ cont: CheckedContinuation<Void, Never>,
                       utterance: AVSpeechUtterance,
                       generation: UInt64) {
        stateLock.lock()
        // A later start claimed while this one was building its utterance: do
        // nothing at all, and settle this waiter rather than leaving it
        // suspended with nothing to resume it.
        guard generation == startGeneration else {
            stateLock.unlock()
            FileLog.shared.addMessage("[VoicePipeline] TTS start superseded before it spoke")
            cont.resume()
            return
        }
        // Supersede whoever held the slot. Their waiter is resumed after the
        // lock is released, so a continuation that resumes inline cannot
        // deadlock against this boundary.
        let displaced = continuation
        continuation = cont
        awaitedUtterance = utterance
        fallbackTask?.cancel()
        fallbackTask = nil
        // The synthesizer is stopped and started AFTER the lock is released.
        // AVSpeechSynthesizer delivers `didStart` to its delegate
        // synchronously from `speak`, and that delegate callback re-enters this
        // boundary to arm the silence timer — calling out under the lock
        // self-deadlocks on a non-recursive NSLock. The state above is already
        // fully published, so a callback arriving at any point after this sees
        // the new waiter and utterance.
        stateLock.unlock()
        synthesizer.stopSpeaking(at: .immediate)
        // Re-check after the stop. Stopping the synthesizer can take real time,
        // and a start that arrives during it claims a newer generation; if that
        // happened, this start has been overtaken and must not speak. The
        // winner has already stored its own waiter, so this one has nothing
        // left to install and is simply settled.
        stateLock.lock()
        let overtaken = generation != startGeneration
        // An overtaken start may already have had its waiter displaced and
        // resumed by the winner, so it must only settle a waiter it still owns.
        let stillOurs = awaitedUtterance === utterance
        if overtaken, stillOurs {
            continuation = nil
            awaitedUtterance = nil
            fallbackTask?.cancel()
            fallbackTask = nil
        }
        stateLock.unlock()
        // Speak OUTSIDE the lock: `didStart` arrives synchronously from
        // `speak` and re-enters this boundary to arm the timer.
        if !overtaken {
            synthesizer.speak(utterance)
        }
        if displaced != nil {
            FileLog.shared.addMessage("[VoicePipeline] TTS speak resumed (superseded)")
            displaced?.resume()
        }
        if overtaken {
            FileLog.shared.addMessage("[VoicePipeline] TTS start superseded before it spoke")
            if stillOurs { cont.resume() }
            return
        }
        scheduleFallbackResume(for: utterance)
    }

    /// Resumes whatever waiter is current, claiming it inside the boundary.
    /// The waiter is identified by the boundary's own state rather than by an
    /// `awaitedUtterance` value read before the lock was taken.
    private func resumeCurrent(reason: String) {
        stateLock.lock()
        guard continuation != nil else {
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
