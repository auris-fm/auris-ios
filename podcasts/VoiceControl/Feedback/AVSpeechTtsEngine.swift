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

/// The single serialization boundary for speech.
///
/// `AudioFeedbackRenderer.render` cancels the render task it replaces without
/// joining it, and neither that renderer, `VoiceControlService` nor the engine
/// is actor-isolated, so two starts genuinely can be inside the start sequence
/// at once. Everything that decides who speaks — claiming a generation,
/// checking it, commanding the synthesizer, storing or claiming the waiter —
/// runs on this one executor, in order. A lock around only the state would not
/// do: the check and the synthesizer command have to be ordered *together*,
/// otherwise a start can pass its check and then enqueue after a newer start
/// has already spoken.
///
/// Delegate callbacks are the exception, and deliberately so: AVFoundation
/// delivers `didStart` synchronously from inside `speak`, on the thread already
/// running on this executor. They therefore take a plain lock over the shared
/// state and never touch the synthesizer or hop back onto the executor, which
/// would deadlock.
private final class SpeechState {
    let lock = NSLock()
    var continuation: CheckedContinuation<Void, Never>?
    var awaitedUtterance: AVSpeechUtterance?
    var fallbackGeneration: UInt64 = 0
    var fallbackTask: Task<Void, Never>?
}

private actor SpeechBoundaryActor {
    private let synthesizer: SpeechSynthesizing
    private let silenceTimeout: TimeInterval
    private let state: SpeechState
    /// Newest start. Only ever touched on this executor.
    private var startGeneration: UInt64 = 0
    /// Tests hold a timer expiry here — after its cancellation check, before
    /// its claim — so progress can rearm underneath a live, expired timer.
    private var expirySeam: (@Sendable () async -> Void)?
    /// The seam fires once, for the first expiry only, so later windows run
    /// normally and the test does not have to disarm it mid-flight.
    private var expirySeamUsed = false

    init(synthesizer: SpeechSynthesizing, silenceTimeout: TimeInterval, state: SpeechState) {
        self.synthesizer = synthesizer
        self.silenceTimeout = silenceTimeout
        self.state = state
    }

    func setExpirySeam(_ seam: (@Sendable () async -> Void)?) {
        expirySeam = seam
    }

    /// Claims the next start number, before the utterance is built, so a start
    /// overtaken while preparing can tell that it lost.
    func claimStart() -> UInt64 {
        startGeneration &+= 1
        return startGeneration
    }

    /// A cancel invalidates every start still preparing as well as settling the
    /// current waiter: a start that was mid-flight when the user cancelled must
    /// not begin speaking afterwards.
    func cancel(reason: String) {
        startGeneration &+= 1
        synthesizer.stopSpeaking(at: .immediate)
        resumeCurrent(reason: reason)
    }

    func start(_ cont: CheckedContinuation<Void, Never>,
               utterance: AVSpeechUtterance,
               generation: UInt64) {
        // Check, store and command are one uninterrupted step on this executor,
        // so no other start, cancel or release can interleave with them.
        guard generation == startGeneration else {
            FileLog.shared.addMessage("[VoicePipeline] TTS start superseded before it spoke")
            cont.resume()
            return
        }
        let displaced = takeWaiter()
        state.lock.lock()
        state.continuation = cont
        state.awaitedUtterance = utterance
        state.lock.unlock()
        synthesizer.stopSpeaking(at: .immediate)
        synthesizer.speak(utterance)
        if let displaced {
            FileLog.shared.addMessage("[VoicePipeline] TTS speak resumed (superseded)")
            displaced.resume()
        }
        armTimer(for: utterance)
    }

    private func resumeCurrent(reason: String) {
        guard let cont = takeWaiter() else { return }
        FileLog.shared.addMessage("[VoicePipeline] TTS speak resumed (\(reason))")
        cont.resume()
    }

    private func takeWaiter() -> CheckedContinuation<Void, Never>? {
        state.lock.lock()
        defer { state.lock.unlock() }
        let cont = state.continuation
        state.continuation = nil
        state.awaitedUtterance = nil
        state.fallbackGeneration &+= 1
        state.fallbackTask?.cancel()
        state.fallbackTask = nil
        return cont
    }

    private func armTimer(for utterance: AVSpeechUtterance) {
        state.lock.lock()
        guard utterance === state.awaitedUtterance else {
            state.lock.unlock()
            return
        }
        state.fallbackTask?.cancel()
        state.fallbackGeneration &+= 1
        let generation = state.fallbackGeneration
        let timeout = silenceTimeout
        state.fallbackTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.expire(generation: generation, utterance: utterance)
        }
        state.lock.unlock()
    }

    /// Expiry for a timer armed by a delegate callback. Same ordering and same
    /// seam as the start-armed timer.
    func expireRearmed(generation: UInt64, utterance: AVSpeechUtterance) async {
        await expire(generation: generation, utterance: utterance)
    }

    /// A timer expiry, ordered on the same executor as starts and cancels.
    private func expire(generation: UInt64, utterance: AVSpeechUtterance) async {
        guard !Task.isCancelled else { return }
        if let expirySeam, !expirySeamUsed {
            expirySeamUsed = true
            await expirySeam()
        }
        state.lock.lock()
        let stale = generation != state.fallbackGeneration
            || utterance !== state.awaitedUtterance
        state.lock.unlock()
        guard !stale else { return }
        resumeCurrent(reason: "silence timeout")
    }
}

class AVSpeechTtsEngine: NSObject, TtsEngineProtocol {
    private let synthesizer: SpeechSynthesizing
    /// How long `speak` waits for the synthesizer to go silent — no start, no
    /// speech-progress, no finish — before resuming anyway. A synthesizer
    /// without a usable audio route never starts an utterance at all, and
    /// without this the waiter hangs forever. A long utterance that IS speaking
    /// keeps resetting the window, so it is never cut off mid-sentence.
    private let silenceTimeout: TimeInterval
    private let state = SpeechState()
    private let boundary: SpeechBoundaryActor

    init(synthesizer: SpeechSynthesizing = SystemSpeechSynthesizer(),
         silenceTimeout: TimeInterval = 10) {
        self.synthesizer = synthesizer
        self.silenceTimeout = silenceTimeout
        self.boundary = SpeechBoundaryActor(synthesizer: synthesizer,
                                            silenceTimeout: silenceTimeout,
                                            state: state)
        super.init()
        self.synthesizer.delegate = self
    }

    /// Lets a test hold a timer expiry between its cancellation check and its
    /// claim. Test-only; production never sets it.
    func setExpirySeamForTesting(_ seam: (@Sendable () async -> Void)?) async {
        await boundary.setExpirySeam(seam)
    }

    /// Lets a test hold a start after it has claimed its generation but before
    /// it enters the boundary, so another start can genuinely overtake it.
    /// Parks between two actor hops, leaving the boundary free to run the
    /// overtaking start. Test-only; production never sets it.
    func setPreparationSeamForTesting(_ seam: (@Sendable (String) async -> Void)?) {
        preparationSeam = seam
    }
    private var preparationSeam: (@Sendable (String) async -> Void)?

    func warmUp(language: String) {
        let utterance = AVSpeechUtterance(string: "")
        utterance.voice = bestVoice(for: language)
        utterance.volume = 0
        synthesizer.speak(utterance)
    }

    func speak(text: String, language: String) async {
        FileLog.shared.addMessage("[VoicePipeline] Speaking: \"\(text)\" (\(language))")
        let generation = await boundary.claimStart()
        if let preparationSeam { await preparationSeam(text) }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = bestVoice(for: language)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            Task { await boundary.start(cont, utterance: utterance, generation: generation) }
        }
    }

    func cancel() {
        // .immediate does not reliably deliver didCancel; the waiter must not
        // outlive the cancel that ended its utterance.
        Task { await boundary.cancel(reason: "cancel") }
    }

    func releaseEngine() {
        Task { await boundary.cancel(reason: "release") }
    }

    // MARK: - Synchronous delegate fast path
    //
    // These run on AVFoundation's thread, sometimes synchronously from inside
    // `speak` while the boundary executor is busy. They take the state lock
    // directly and never call back into the executor.

    private func resumeIfCurrent(_ utterance: AVSpeechUtterance, reason: String) {
        state.lock.lock()
        guard let cont = state.continuation, utterance === state.awaitedUtterance else {
            state.lock.unlock()
            return
        }
        state.continuation = nil
        state.awaitedUtterance = nil
        state.fallbackGeneration &+= 1
        state.fallbackTask?.cancel()
        state.fallbackTask = nil
        state.lock.unlock()
        FileLog.shared.addMessage("[VoicePipeline] TTS speak resumed (\(reason))")
        cont.resume()
    }

    /// Every sign of life from the synthesizer rearms the silence window, so
    /// the timer fires only when it has gone quiet without finishing.
    private func rearmFallback(for utterance: AVSpeechUtterance) {
        state.lock.lock()
        guard utterance === state.awaitedUtterance else {
            state.lock.unlock()
            return
        }
        state.fallbackTask?.cancel()
        state.fallbackGeneration &+= 1
        let generation = state.fallbackGeneration
        let timeout = silenceTimeout
        state.fallbackTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.expireFromDelegate(generation: generation, utterance: utterance)
        }
        state.lock.unlock()
    }

    private func expireFromDelegate(generation: UInt64, utterance: AVSpeechUtterance) async {
        await boundary.expireRearmed(generation: generation, utterance: utterance)
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
        rearmFallback(for: utterance)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, willSpeakRangeOfSpeechString characterRange: NSRange, utterance: AVSpeechUtterance) {
        rearmFallback(for: utterance)
    }
}

