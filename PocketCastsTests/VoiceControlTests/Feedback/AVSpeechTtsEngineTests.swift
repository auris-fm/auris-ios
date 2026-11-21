import AVFoundation
import XCTest
@testable import podcasts

/// A synthesizer the engine controls from the test: it records utterances and
/// delivers exactly the delegate callbacks the test names, so the callback
/// sequences a real AVSpeechSynthesizer produces — including the never-calls-
/// back case a headless runner produces — are reproducible deterministically.
/// Hands each silence window to the test as a closure instead of running it on
/// a clock, so a test decides exactly when a window expires and can wait for
/// that expiry to finish before doing anything else.
private actor ManualSilenceScheduler: SilenceScheduling {
    private var windows: [@MainActor () async -> Void] = []
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []

    nonisolated func schedule(after seconds: TimeInterval,
                              _ work: @escaping @MainActor () async -> Void) -> SilenceTimerToken {
        Task { await self.append(work) }
        return ManualToken()
    }

    private func append(_ work: @escaping @MainActor () async -> Void) {
        windows.append(work)
        let ready = waiters.filter { $0.0 <= windows.count }
        waiters.removeAll { $0.0 <= windows.count }
        ready.forEach { $0.1.resume() }
    }

    /// Waits until at least `count` windows have been armed, then returns the
    /// last one's expiry.
    func waitForWindow(count: Int) async -> @MainActor () async -> Void {
        if windows.count < count {
            await withCheckedContinuation { waiters.append((count, $0)) }
        }
        return windows[count - 1]
    }
}

private struct ManualToken: SilenceTimerToken {
    func cancel() {}
}

/// A flag an async test can read without a lock.
private actor FinishedFlag {
    private var done = false
    var value: Bool { done }
    func set() { done = true }
}

/// A boolean a main-actor task can set and any test can read afterwards.
private final class MainActorFlag {
    private let lock = NSLock()
    private var _value = false
    var value: Bool {
        lock.lock(); defer { lock.unlock() }
        return _value
    }
    func set() {
        lock.lock(); _value = true; lock.unlock()
    }
}

/// A one-shot gate an async test can park on and open explicitly, so an
/// interleaving is forced rather than approximated with a sleep.
private actor AsyncGate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        opened = true
        let pending = waiters
        waiters = []
        pending.forEach { $0.resume() }
    }
}

private final class StubSpeechSynthesizer: SpeechSynthesizing {
    var delegate: AVSpeechSynthesizerDelegate?
    var isSpeaking = false
    private let lock = NSLock()
    private var _spoken: [AVSpeechUtterance] = []
    var spoken: [AVSpeechUtterance] {
        lock.lock(); defer { lock.unlock() }
        return _spoken
    }
    /// Called with each utterance as `speak` is invoked. Default: deliver
    /// nothing, which is what a synthesizer without a usable audio route does.
    var onSpeak: ((StubSpeechSynthesizer, AVSpeechUtterance) -> Void)?
    /// When set, speak(_:) blocks on this semaphore after enqueuing, letting a
    /// test hold the first start inside the synthesizer while a second starts.
    var holdSpeak: DispatchSemaphore?
    /// Where this stub parks when the engine reports its timeline. The engine
    /// only reports; the stub decides what to do at each point.
    var onPrepare: ((String) async -> Void)?
    var onClaimExpiry: (() async -> Void)?
    private var claimedExpiry = false

    /// Records whether resolution ran on main. The production implementation must
    /// resolve away from the main actor; a stub resolving inline would hide that.
    private let voiceLock = NSLock()
    private var _resolveOnMain: [Bool] = []
    var resolveOnMain: [Bool] {
        voiceLock.lock(); defer { voiceLock.unlock() }
        return _resolveOnMain
    }
    var onResolve: (() async -> Void)?

    /// Returns a voice resolved once, off main, when the stub is created. Resolving
    /// per call would put the real system speech call back on the caller's thread —
    /// the very thing the engine no longer does — and make every test pay its cost.
    func resolveVoice(for language: String) async -> AVSpeechSynthesisVoice? {
        if let onResolve { await onResolve() }
        let onMain = Thread.isMainThread
        voiceLock.lock(); _resolveOnMain.append(onMain); voiceLock.unlock()
        // No voice, and no call into the speech service. A unit stub must not reach
        // the system at all: caching only reduces how often it is called, it does not
        // remove the possibility of blocking on it.
        return nil
    }

    func engineWillPrepareUtterance(text: String) async {
        if let onPrepare { await onPrepare(text) }
    }

    func engineWillClaimSilenceExpiry() async {
        // Only the first expiry is held, so later windows run normally.
        guard !claimedExpiry else { return }
        claimedExpiry = true
        if let onClaimExpiry { await onClaimExpiry() }
    }

    func speak(_ utterance: AVSpeechUtterance) {
        lock.lock()
        _spoken.append(utterance)
        lock.unlock()
        isSpeaking = true
        onSpeak?(self, utterance)
        holdSpeak?.wait()
    }

    func stopSpeaking(at boundary: AVSpeechBoundary) -> Bool {
        isSpeaking = false
        return true
    }

    /// The delegate methods are ObjC-optional, so delivery goes through
    /// perform rather than an existential call.
    func deliverDidFinish(_ utterance: AVSpeechUtterance) {
        delegate?.speechSynthesizer?(AVSpeechSynthesizer(), didFinish: utterance)
    }

    func deliverDidCancel(_ utterance: AVSpeechUtterance) {
        delegate?.speechSynthesizer?(AVSpeechSynthesizer(), didCancel: utterance)
    }

    func deliverDidStart(_ utterance: AVSpeechUtterance) {
        delegate?.speechSynthesizer?(AVSpeechSynthesizer(), didStart: utterance)
    }

    func deliverWillSpeak(_ utterance: AVSpeechUtterance) {
        // Typed optional call: the delegate methods are ObjC-optional, so the
        // existential exposes them as optional requirements — no unsafe casts.
        let range = NSRange(location: 0, length: min(5, (utterance.speechString as NSString).length))
        delegate?.speechSynthesizer?(AVSpeechSynthesizer(), willSpeakRangeOfSpeechString: range, utterance: utterance)
    }

}

@MainActor
final class AVSpeechTtsEngineTests: XCTestCase {

    func test_warmUp_doesNotThrow() async {
        let synthesizer = StubSpeechSynthesizer()
        let engine = AVSpeechTtsEngine(synthesizer: synthesizer)
        await engine.warmUp(language: "en-US")
        XCTAssertEqual(synthesizer.spoken.count, 1, "warmUp enqueues one silent utterance")
    }

    func test_speak_completesAsync() async {
        let synthesizer = StubSpeechSynthesizer()
        synthesizer.onSpeak = { stub, utterance in stub.deliverDidFinish(utterance) }
        let engine = AVSpeechTtsEngine(synthesizer: synthesizer)
        await engine.speak(text: "Hello", language: "en-US")
        XCTAssertEqual(synthesizer.spoken.count, 1)
    }

    func test_cancel_stopsSpeaking() {
        let engine = AVSpeechTtsEngine(synthesizer: StubSpeechSynthesizer())
        engine.cancel()
        // Verifies no crash on cancel when not speaking
    }

    func test_releaseEngine_stopsEngine() {
        let engine = AVSpeechTtsEngine(synthesizer: StubSpeechSynthesizer())
        engine.releaseEngine()
        // Verifies no crash on release
    }

    func test_speak_cancelsPreviousUtterance() async {
        let synthesizer = StubSpeechSynthesizer()
        let engine = AVSpeechTtsEngine(synthesizer: synthesizer)
        // The first utterance stays speaking: the stub delivers nothing for it.
        let first = Task { await engine.speak(text: "Long text that takes time", language: "en-US") }
        await waitUntil(timeout: 5) { !synthesizer.spoken.isEmpty }
        // The second speak bumps the start generation while the first is still
        // resolving its voice, so the first never reaches the synthesizer and its
        // task returns settled rather than waiting. Only the second is spoken.
        synthesizer.onSpeak = { stub, utterance in stub.deliverDidFinish(utterance) }
        await engine.speak(text: "Short", language: "en-US")
        await first.value
        XCTAssertEqual(synthesizer.spoken.count, 2,
                       "the first utterance started speaking before the second was requested")
    }

    func test_warmUp_acceptsAnyLanguage() async {
        let synthesizer = StubSpeechSynthesizer()
        let engine = AVSpeechTtsEngine(synthesizer: synthesizer)
        for language in ["ja-JP", "fr-FR", "es-ES"] {
            await engine.warmUp(language: language)
        }
        XCTAssertEqual(synthesizer.spoken.count, 3)
    }

    // MARK: - Hang and double-resume regressions

    /// A synthesizer without a usable audio route silently never delivers any
    /// callback, and `speak` waited forever — the launch-time CI hang. `speak`
    /// must complete even when the synthesizer never calls back.
    func test_speak_completesEvenWhenTheSynthesizerNeverCallsBack() async {
        let synthesizer = StubSpeechSynthesizer()
        let engine = AVSpeechTtsEngine(synthesizer: synthesizer, silenceTimeout: 0.2)
        await engine.speak(text: "Hello", language: "en-US")
        XCTAssertEqual(synthesizer.spoken.count, 1, "the utterance was enqueued")
    }

    /// After a cancel-then-speak, the old utterance's `didCancel` arrives while
    /// the new utterance's continuation is already stored. The old callback
    /// must not resume it: the second speak must stay waiting until its own
    /// utterance finishes.
    func test_speak_afterCancel_oldUtteranceCallbackDoesNotStealTheNewWaiter() async {
        let synthesizer = StubSpeechSynthesizer()
        let engine = AVSpeechTtsEngine(synthesizer: synthesizer)
        let firstTask = Task {
            await engine.speak(text: "Long text that takes time", language: "en-US")
        }
        await waitUntil(timeout: 5) { !synthesizer.spoken.isEmpty }
        let firstUtterance = synthesizer.spoken[0]

        // The second speak stops the first; the synthesizer then reports the
        // first utterance cancelled while the second is already enqueued.
        synthesizer.onSpeak = { stub, utterance in
            guard utterance !== firstUtterance else { return }
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) {
                stub.deliverDidCancel(firstUtterance)
            }
        }

        let lock = NSLock()
        var secondReturned = false
        let secondTask = Task {
            await engine.speak(text: "Short", language: "en-US")
            lock.lock()
            secondReturned = true
            lock.unlock()
        }
        // Wait until the second utterance is enqueued and the old one's late
        // didCancel has been delivered.
        var enqueued = false
        while !enqueued {
            lock.lock()
            enqueued = synthesizer.spoken.count >= 2
            lock.unlock()
            if !enqueued { try? await Task.sleep(nanoseconds: 10_000_000) }
        }
        try? await Task.sleep(nanoseconds: 300_000_000)
        lock.lock()
        let returned = secondReturned
        lock.unlock()
        XCTAssertFalse(returned,
                       "the old utterance's didCancel must not end the new speak")

        // Only the new utterance's own finish may end it.
        let secondUtterance = synthesizer.spoken[1]
        synthesizer.deliverDidFinish(secondUtterance)
        await secondTask.value
        firstTask.cancel()
    }

    /// `cancel` must end the waiter even when the synthesizer delivers no
    /// callback for the stopped utterance.
    func test_cancel_endsTheWaiterEvenWithoutACallback() async {
        let synthesizer = StubSpeechSynthesizer()
        let engine = AVSpeechTtsEngine(synthesizer: synthesizer)
        let speaking = Task {
            await engine.speak(text: "Hello", language: "en-US")
        }
        await waitUntil(timeout: 5) { !synthesizer.spoken.isEmpty }
        engine.cancel()
        await speaking.value
    }

    /// A long utterance that IS speaking keeps sending progress callbacks.
    /// The fallback timer covers silence, not duration, so it must never end a
    /// speak that is still making progress.
    func test_speak_longUtteranceWithSteadyProgressIsNotEndedByTheFallback() async {
        let synthesizer = StubSpeechSynthesizer()
        let engine = AVSpeechTtsEngine(synthesizer: synthesizer, silenceTimeout: 0.3)
        // Progress every 0.1 s for a full second — three silence windows worth.
        synthesizer.onSpeak = { stub, utterance in
            stub.deliverDidStart(utterance)
            for i in 0..<10 {
                DispatchQueue.global().asyncAfter(deadline: .now() + Double(i + 1) * 0.1) {
                    stub.deliverWillSpeak(utterance)
                }
            }
        }
        let lock = NSLock()
        var finished = false
        let task = Task {
            await engine.speak(text: String(repeating: "word ", count: 200), language: "en-US")
            lock.lock()
            finished = true
            lock.unlock()
        }
        // Give any (wrong) duration-based cutoff ample time to fire.
        try? await Task.sleep(nanoseconds: 700_000_000)
        lock.lock()
        let done = finished
        lock.unlock()
        XCTAssertFalse(done,
                       "speak must not end while the synthesizer is still reporting progress")
        let utterance = synthesizer.spoken[0]
        synthesizer.deliverDidFinish(utterance)
        await task.value
    }

    /// A silence timer whose window has already expired must not resume a
    /// waiter that a progress callback rearms afterwards. The progress is held
    /// inside the synthesizer's speak until the first window has fully passed,
    /// so the stale timer is guaranteed to be at or past its expiry when the
    /// rearm happens; freshness is decided under the continuation lock.
    /// A silence timer that expired must not resume a waiter that progress has
    /// since rearmed.
    ///
    /// The order is fixed by the stub, not by timing: `didStart` arms a real
    /// timer *before* the synthesizer blocks, so a window genuinely expires
    /// while the start is held. Progress then rearms it, and only afterwards is
    /// the held start released — so the expired timer's claim is attempted
    /// against a generation that progress has already replaced.
    /// A silence timer that expired must not resume a waiter that progress has
    /// since rearmed.
    ///
    /// The interleaving is forced, not timed: the expiry is held after its
    /// cancellation check and before it claims the waiter, progress rearms
    /// while it is held, and only then is it released. A timer that ignores the
    /// generation it was armed with resumes the waiter here.
    /// A silence timer that expired must not resume a waiter that progress has
    /// since rearmed.
    ///
    /// Nothing here waits on a clock. The injected scheduler hands the test
    /// each window's expiry as a closure it fires by hand, so the stale expiry
    /// is run to completion — and observed to claim nothing — before the next
    /// window is fired at all.
    func test_speak_expiredTimerDoesNotResumeAfterProgressRearms() async {
        let synthesizer = StubSpeechSynthesizer()
        let scheduler = ManualSilenceScheduler()
        let engine = AVSpeechTtsEngine(synthesizer: synthesizer,
                                       silenceTimeout: 0.2,
                                       scheduler: scheduler)
        let finished = FinishedFlag()
        let task = Task {
            await engine.speak(text: "Hello", language: "en-US")
            await finished.set()
        }
        // The first window is armed by the start. Fire it, but hold it at the
        // point where it is about to claim the waiter.
        let firstExpiry = await scheduler.waitForWindow(count: 1)
        let release = AsyncGate()
        let parked = expectation(description: "expiry held before its claim")
        synthesizer.onClaimExpiry = {
            parked.fulfill()
            await release.wait()
        }
        let staleRun = Task { await firstExpiry() }
        await fulfillment(of: [parked], timeout: 5)

        // Progress rearms underneath the parked expiry, arming a second window.
        // The enqueue follows the voice lookup, so wait for it rather than assuming it.
        await waitUntil(timeout: 5) { !synthesizer.spoken.isEmpty }
        let utterance = synthesizer.spoken[0]
        synthesizer.deliverWillSpeak(utterance)
        let secondExpiry = await scheduler.waitForWindow(count: 2)

        // Let the stale expiry finish its claim attempt, and wait for it.
        await release.open()
        await staleRun.value
        let endedEarly = await finished.value
        XCTAssertFalse(endedEarly, "an expired timer resumed a waiter that progress had rearmed")

        // The current window is still live: firing it is what may end the wait.
        synthesizer.onClaimExpiry = nil
        await secondExpiry()
        await task.value
        let endedByCurrentWindow = await finished.value
        XCTAssertTrue(endedByCurrentWindow,
                      "the current silence window must still be able to end a silent utterance")
    }

    /// A start that a later start overtook must not reach the synthesizer.
    ///
    /// `AudioFeedbackRenderer.render` cancels the render task it replaces
    /// without joining it, and nothing in that chain is actor-isolated, so two
    /// starts can be inside the engine's start sequence at once. The engine
    /// must settle that at its own boundary: the overtaken start neither speaks
    /// over the winner nor leaves a waiter behind.
    ///
    /// The overtaking start is launched from the seam the overtaken one is
    /// still blocked in, so the order is fixed rather than timed.
    /// A start that a later start overtook must not reach the synthesizer.
    ///
    /// `AudioFeedbackRenderer.render` cancels the render task it replaces
    /// without joining it, and nothing in that chain is actor-isolated, so two
    /// starts can be inside the engine's start sequence at once. The engine
    /// settles that at its own boundary: the overtaken start neither speaks
    /// over the winner nor leaves a waiter behind.
    ///
    /// The order is forced by an explicit handoff through the stub, not by
    /// sleeping: the loser blocks inside `stopSpeaking` until the winner has
    /// actually enqueued its utterance.
    /// A start that a later start overtook must not reach the synthesizer.
    ///
    /// `AudioFeedbackRenderer.render` cancels the render task it replaces
    /// without joining it, and nothing in that chain is actor-isolated, so two
    /// starts can be inside the engine's start sequence at once. The engine
    /// settles that at its own boundary: the overtaken start neither speaks
    /// over the winner nor leaves a waiter behind.
    ///
    /// The order is forced by an explicit handoff, not by sleeping. The loser
    /// claims its generation and then parks before entering the boundary; the
    /// winner runs to completion — including its actual enqueue — and only then
    /// is the loser released.
    func test_speak_overtakenStartDoesNotReachTheSynthesizer() async {
        let synthesizer = StubSpeechSynthesizer()
        let engine = AVSpeechTtsEngine(synthesizer: synthesizer, silenceTimeout: 30)
        let loserParked = expectation(description: "first start parked after claiming")
        let winnerSpoke = expectation(description: "winner enqueued its utterance")
        let loserDone = expectation(description: "overtaken start settled")
        let winnerDone = expectation(description: "winning start settled")
        let release = AsyncGate()
        synthesizer.onPrepare = { text in
            guard text == "Loser" else { return }
            loserParked.fulfill()
            await release.wait()
        }
        synthesizer.onSpeak = { _, utterance in
            if utterance.speechString == "Winner" { winnerSpoke.fulfill() }
        }

        Task {
            await engine.speak(text: "Loser", language: "en-US")
            loserDone.fulfill()
        }
        await fulfillment(of: [loserParked], timeout: 5)
        Task {
            await engine.speak(text: "Winner", language: "en-US")
            winnerDone.fulfill()
        }
        // The winner must really have spoken before the loser is let go.
        await fulfillment(of: [winnerSpoke], timeout: 5)
        await release.open()

        await fulfillment(of: [loserDone], timeout: 5)
        XCTAssertEqual(synthesizer.spoken.map(\.speechString), ["Winner"],
                       "an overtaken start reached the synthesizer")
        if let winnerUtterance = synthesizer.spoken.first {
            synthesizer.deliverDidFinish(winnerUtterance)
        }
        await fulfillment(of: [winnerDone], timeout: 5)
    }

    /// The engine must await the injected resolver rather than resolving on its own
    /// main actor. Observed through the resolver: it records the thread it was called
    /// on, and the engine's own main-actor work must still be able to run while a
    /// lookup is outstanding. The production invariant itself is
    /// `dispatchPrecondition(.notOnQueue(.main))` at the system lookup, which needs no
    /// test: it holds in debug builds wherever that code runs.
    func test_speak_awaitsTheInjectedResolver_andLeavesTheMainActorFree() async {
        let synthesizer = StubSpeechSynthesizer()
        let parked = expectation(description: "lookup parked")
        let gate = AsyncGate()
        synthesizer.onResolve = {
            parked.fulfill()
            await gate.wait()
        }
        let engine = AVSpeechTtsEngine(synthesizer: synthesizer, silenceTimeout: 60)
        let speaking = Task { await engine.speak(text: "Hello", language: "en-US") }
        await fulfillment(of: [parked], timeout: 5)

        // While the lookup is outstanding the main actor must still run other work —
        // cancel among it, which is what ends this call.
        let ranOnMain = expectation(description: "main actor still runs work")
        Task { @MainActor in ranOnMain.fulfill() }
        await fulfillment(of: [ranOnMain], timeout: 5)

        engine.cancel()
        await speaking.value
        await gate.open()
        // The record is written after the gate opens, so wait for it.
        await waitUntil(timeout: 5) { !synthesizer.resolveOnMain.isEmpty }
        XCTAssertFalse(synthesizer.resolveOnMain.isEmpty,
                       "the resolver was never called, so this proves nothing")
    }

    /// A voice lookup that never returns must not leave the call waiting for ever:
    /// the renderer ducks before speaking and only unducks when speak returns, so a
    /// stuck lookup would leave the app's audio ducked permanently. The waiter and its
    /// silence window are installed before the lookup, so the window ends the call.
    func test_speak_voiceLookupNeverReturns_endsOnTheSilenceTimeout() async {
        let synthesizer = StubSpeechSynthesizer()
        let parked = expectation(description: "lookup parked")
        let gate = AsyncGate()
        synthesizer.onResolve = {
            parked.fulfill()
            await gate.wait()
        }
        let engine = AVSpeechTtsEngine(synthesizer: synthesizer, silenceTimeout: 0.2)
        let speaking = Task { await engine.speak(text: "Hello", language: "en-US") }
        await fulfillment(of: [parked], timeout: 5)

        // The lookup is still parked. The silence window must end the call anyway.
        await speaking.value
        XCTAssertTrue(synthesizer.spoken.isEmpty,
                      "a call ended by the timeout must not enqueue afterwards")
        await gate.open()
    }

    /// Cancel must end a call whose lookup is still outstanding, immediately, rather
    /// than waiting for the lookup or the silence window.
    func test_speak_voiceLookupNeverReturns_cancelEndsTheCall() async {
        let synthesizer = StubSpeechSynthesizer()
        let parked = expectation(description: "lookup parked")
        let gate = AsyncGate()
        synthesizer.onResolve = {
            parked.fulfill()
            await gate.wait()
        }
        // A long window, so ending the call can only be attributed to cancel.
        let engine = AVSpeechTtsEngine(synthesizer: synthesizer, silenceTimeout: 60)
        let speaking = Task { await engine.speak(text: "Hello", language: "en-US") }
        await fulfillment(of: [parked], timeout: 5)

        engine.cancel()
        await speaking.value
        XCTAssertTrue(synthesizer.spoken.isEmpty,
                      "a cancelled call must not enqueue when its lookup finally returns")
        await gate.open()
    }

    /// Warm-up superseded during its lookup must enqueue nothing: it would otherwise
    /// speak behind, or after, the real start it was meant to precede.
    func test_warmUp_supersededDuringVoiceLookup_enqueuesNothing() async {
        let synthesizer = StubSpeechSynthesizer()
        let parked = expectation(description: "warm-up lookup parked")
        let gate = AsyncGate()
        synthesizer.onResolve = {
            parked.fulfill()
            await gate.wait()
        }
        let engine = AVSpeechTtsEngine(synthesizer: synthesizer)
        let warming = Task { await engine.warmUp(language: "en-US") }
        await fulfillment(of: [parked], timeout: 5)

        // A real start replaces the warm-up while its lookup is outstanding.
        synthesizer.onResolve = nil
        synthesizer.onSpeak = { stub, utterance in stub.deliverDidFinish(utterance) }
        await engine.speak(text: "Real speech", language: "en-US")
        let spokenAfterStart = synthesizer.spoken.count

        await gate.open()
        await warming.value
        XCTAssertEqual(synthesizer.spoken.count, spokenAfterStart,
                       "the superseded warm-up must not enqueue after the real start")
    }

    /// A start overtaken while its voice is still resolving must not speak. The
    /// resolution is held on an explicit gate, so the ordering is forced, not timed.
    func test_speak_overtakenWhileResolvingVoice_doesNotSpeak() async {
        let synthesizer = StubSpeechSynthesizer()
        let resolving = expectation(description: "first start is resolving its voice")
        let gate = AsyncGate()
        synthesizer.onResolve = {
            resolving.fulfill()
            await gate.wait()
        }
        let engine = AVSpeechTtsEngine(synthesizer: synthesizer)
        let first = Task { await engine.speak(text: "First", language: "en-US") }
        await fulfillment(of: [resolving], timeout: 5)

        // Cancel while the first start is still resolving, then let it go.
        engine.cancel()
        await gate.open()
        await first.value

        XCTAssertTrue(synthesizer.spoken.isEmpty,
                      "a start cancelled while resolving its voice must not reach the synthesizer")
    }

    /// Polls the event rather than sleeping a fixed interval: under load a fixed
    /// sleep is a deadline that can expire before the work has happened.
    ///
    /// Deliberately NOT main-actor. The work being waited for runs on the main actor,
    /// so polling there competes with it: under load the poll can consume the whole
    /// window and the awaited work never runs. Reading the stub's lock-guarded state
    /// from off-main avoids that.
    private nonisolated func waitUntil(timeout: TimeInterval, _ condition: @Sendable () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

}
