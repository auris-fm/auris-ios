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

    /// Observation points on the engine's own timeline. The engine reports
    /// where it is; the synthesizer decides whether that moment matters. The
    /// system synthesizer does nothing at either, so production behaviour is
    /// unchanged, while a test synthesizer can park there to force an
    /// interleaving instead of approximating one with a sleep.
    func engineWillPrepareUtterance(text: String) async
    func engineWillClaimSilenceExpiry() async

    /// Resolves a voice for `language`. `AVSpeechSynthesisVoice(language:)` talks to
    /// the system speech service and is synchronous, so it must not run on the main
    /// actor: the first resolution in a process pays the service's cold-start cost
    /// and would freeze the caller. Implementations resolve away from main.
    func resolveVoice(for language: String) async -> AVSpeechSynthesisVoice?
}

extension SpeechSynthesizing {
    func engineWillPrepareUtterance(text: String) async {}
    func engineWillClaimSilenceExpiry() async {}
}

typealias SpeechBoundary = AVSpeechBoundary

final class SystemSpeechSynthesizer: AVSpeechSynthesizer, SpeechSynthesizing {
    /// Resolves off the main actor. The call is synchronous and reaches the system
    /// speech service, whose first use in a process costs tens of milliseconds and
    /// can block indefinitely when that service is unresponsive — measured at 42 ms
    /// cold versus 0.1 ms warm. On the main actor that is a frozen app, not a slow
    /// one, and `warmUp` runs during service construction at launch.
    nonisolated func resolveVoice(for language: String) async -> AVSpeechSynthesisVoice? {
        await Task.detached(priority: .userInitiated) {
            // Resolving reaches the system speech service synchronously. On the main
            // queue that freezes the caller for as long as the service takes, and this
            // runs on the launch path through `warmUp`. True of the code, not a test hook.
            dispatchPrecondition(condition: .notOnQueue(.main))
            return AVSpeechSynthesisVoice(language: language)
                ?? AVSpeechSynthesisVoice(language: "en-US")
        }.value
    }
}

/// Waits out a silence window. Injected so a test can hold an expiry at a
/// chosen point and let it go explicitly, rather than racing a real clock.
protocol SilenceScheduling {
    func schedule(after seconds: TimeInterval, _ work: @escaping @MainActor () async -> Void) -> SilenceTimerToken
}

protocol SilenceTimerToken {
    func cancel()
}

struct SystemSilenceScheduler: SilenceScheduling {
    func schedule(after seconds: TimeInterval, _ work: @escaping @MainActor () async -> Void) -> SilenceTimerToken {
        let task = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await work()
        }
        return task
    }
}

extension Task: SilenceTimerToken {}

/// Text-to-speech over AVSpeechSynthesizer.
///
/// Everything here is main-actor isolated: starts, stops, cancels, releases,
/// timer expiry and the delegate callbacks. `AudioFeedbackRenderer.render`
/// cancels the render task it replaces without joining it, so two starts can
/// genuinely be in flight; one isolation domain orders them without a lock,
/// and `cancel` completes synchronously before its caller creates the
/// replacement. AVSpeechSynthesizer delivers `didStart` from inside `speak`,
/// which under this design is ordinary same-actor re-entry rather than a
/// deadlock.
@MainActor
class AVSpeechTtsEngine: NSObject, TtsEngineProtocol {
    private let synthesizer: SpeechSynthesizing
    private let scheduler: SilenceScheduling
    /// How long `speak` waits for the synthesizer to go silent — no start, no
    /// speech-progress, no finish — before resuming anyway. A synthesizer
    /// without a usable audio route never starts an utterance at all, and
    /// without this the waiter hangs forever. A long utterance that IS speaking
    /// keeps resetting the window, so it is never cut off mid-sentence.
    private let silenceTimeout: TimeInterval
    private var continuation: CheckedContinuation<Void, Never>?
    /// The utterance the stored continuation waits on, so a late callback for
    /// an older utterance cannot resume the current waiter.
    private var awaitedUtterance: AVSpeechUtterance?
    /// Bumped on every arm/rearm and every resume. An expiry may only claim the
    /// waiter while the generation it was armed with is still current.
    private var fallbackGeneration: UInt64 = 0
    private var fallbackTimer: SilenceTimerToken?
    /// Newest start. A start that a later start — or a cancel — overtook while
    /// it was preparing must neither speak nor install a waiter.
    private var startGeneration: UInt64 = 0

    init(synthesizer: SpeechSynthesizing = SystemSpeechSynthesizer(),
         silenceTimeout: TimeInterval = 10,
         scheduler: SilenceScheduling = SystemSilenceScheduler()) {
        self.synthesizer = synthesizer
        self.silenceTimeout = silenceTimeout
        self.scheduler = scheduler
        super.init()
        self.synthesizer.delegate = self
    }

    func warmUp(language: String) async {
        let generation = startGeneration
        let voice = await synthesizer.resolveVoice(for: language)
        // A real start or a release may have happened while the lookup was outstanding.
        // Warming then would enqueue behind — or after — the speech it was meant to
        // precede, so it enqueues nothing instead.
        guard generation == startGeneration else {
            FileLog.shared.addMessage("[VoicePipeline] TTS warm-up superseded while resolving its voice")
            return
        }
        let utterance = AVSpeechUtterance(string: "")
        utterance.voice = voice
        utterance.volume = 0
        synthesizer.speak(utterance)
    }

    func speak(text: String, language: String) async {
        FileLog.shared.addMessage("[VoicePipeline] Speaking: \"(text)\" (\(language))")
        startGeneration &+= 1
        let generation = startGeneration
        await synthesizer.engineWillPrepareUtterance(text: text)

        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate

        // The waiter and its silence window are installed BEFORE the voice lookup, so
        // one deadline covers the whole call. Resolving reaches the system speech
        // service and may never return; installing the wait only afterwards would leave
        // this call pending for ever, and the renderer would never unduck. Installed
        // first, a stuck lookup ends through the same timeout path as a silent
        // synthesizer, and cancel or release ends it immediately.
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            guard generation == startGeneration else {
                FileLog.shared.addMessage("[VoicePipeline] TTS start superseded before it spoke")
                cont.resume()
                return
            }
            let displaced = takeWaiter()
            continuation = cont
            awaitedUtterance = utterance
            armFallback(for: utterance)
            if let displaced {
                FileLog.shared.addMessage("[VoicePipeline] TTS speak resumed (superseded)")
                displaced.resume()
            }
            // Resolving happens while the waiter is installed and its window armed.
            // Only the resolver is held across the lookup. Taking a strong `self`
            // before the suspension would keep the whole engine alive for as long as
            // the lookup takes, even after release — and it may never return.
            let resolver = synthesizer
            Task { @MainActor [weak self] in
                let voice = await resolver.resolveVoice(for: language)
                guard let self else { return }
                // The wait may have ended while the lookup was outstanding: cancel,
                // release, a later start, or the silence window. Enqueue nothing then.
                guard generation == self.startGeneration,
                      self.awaitedUtterance === utterance,
                      self.continuation != nil else {
                    FileLog.shared.addMessage("[VoicePipeline] TTS start ended while resolving its voice")
                    return
                }
                utterance.voice = voice
                self.synthesizer.stopSpeaking(at: .immediate)
                self.synthesizer.speak(utterance)
                // The window armed before the lookup still covers this utterance;
                // arming again here would add a second window for the same wait.
            }
        }
    }

    func cancel() {
        // Invalidates starts still preparing as well as settling the current
        // waiter, and runs synchronously on the main actor, so it is finished
        // before the caller creates the replacement render.
        startGeneration &+= 1
        synthesizer.stopSpeaking(at: .immediate)
        // .immediate does not reliably deliver didCancel; the waiter must not
        // outlive the cancel that ended its utterance.
        resumeCurrent(reason: "cancel")
    }

    func releaseEngine() {
        startGeneration &+= 1
        synthesizer.stopSpeaking(at: .immediate)
        resumeCurrent(reason: "release")
    }

    // MARK: - Waiter state (main actor only)

    private func takeWaiter() -> CheckedContinuation<Void, Never>? {
        let cont = continuation
        continuation = nil
        awaitedUtterance = nil
        fallbackGeneration &+= 1
        fallbackTimer?.cancel()
        fallbackTimer = nil
        return cont
    }

    private func resumeCurrent(reason: String) {
        guard let cont = takeWaiter() else { return }
        FileLog.shared.addMessage("[VoicePipeline] TTS speak resumed (\(reason))")
        cont.resume()
    }

    private func resumeIfCurrent(_ utterance: AVSpeechUtterance, reason: String) {
        guard continuation != nil, utterance === awaitedUtterance else { return }
        resumeCurrent(reason: reason)
    }

    /// Every sign of life from the synthesizer rearms the silence window, so
    /// the timer fires only when it has gone quiet without finishing.
    private func armFallback(for utterance: AVSpeechUtterance) {
        guard utterance === awaitedUtterance else { return }
        fallbackTimer?.cancel()
        fallbackGeneration &+= 1
        let generation = fallbackGeneration
        fallbackTimer = scheduler.schedule(after: silenceTimeout) { [weak self] in
            await self?.expire(generation: generation, utterance: utterance)
        }
    }

    private func expire(generation: UInt64, utterance: AVSpeechUtterance) async {
        await synthesizer.engineWillClaimSilenceExpiry()
        // Freshness and the claim are one main-actor step: nothing can rearm
        // between deciding this window is current and taking its waiter.
        guard generation == fallbackGeneration, utterance === awaitedUtterance else { return }
        resumeCurrent(reason: "silence timeout")
    }

    // MARK: - Voice Selection

}

// MARK: - AVSpeechSynthesizerDelegate

extension AVSpeechTtsEngine: AVSpeechSynthesizerDelegate {
    /// AVSpeechSynthesizer usually delivers on the thread that called `speak`,
    /// which under this design is already the main actor — but it is not
    /// guaranteed, so a callback arriving elsewhere hops rather than assuming.
    /// The utterance identity is all these carry, and it is checked against the
    /// current waiter once the hop lands.
    private nonisolated func onMain(_ work: @escaping @MainActor () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated(work)
        } else {
            Task { @MainActor in work() }
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        onMain { self.resumeIfCurrent(utterance, reason: "didFinish") }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        onMain { self.resumeIfCurrent(utterance, reason: "didCancel") }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        onMain { self.armFallback(for: utterance) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, willSpeakRangeOfSpeechString characterRange: NSRange, utterance: AVSpeechUtterance) {
        onMain { self.armFallback(for: utterance) }
    }
}
