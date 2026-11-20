import AVFoundation
import XCTest
@testable import podcasts

/// A synthesizer the engine controls from the test: it records utterances and
/// delivers exactly the delegate callbacks the test names, so the callback
/// sequences a real AVSpeechSynthesizer produces — including the never-calls-
/// back case a headless runner produces — are reproducible deterministically.
private final class StubSpeechSynthesizer: SpeechSynthesizing {
    var delegate: AVSpeechSynthesizerDelegate?
    var isSpeaking = false
    private(set) var spoken: [AVSpeechUtterance] = []
    /// Called with each utterance as `speak` is invoked. Default: deliver
    /// nothing, which is what a synthesizer without a usable audio route does.
    var onSpeak: ((StubSpeechSynthesizer, AVSpeechUtterance) -> Void)?

    func speak(_ utterance: AVSpeechUtterance) {
        spoken.append(utterance)
        isSpeaking = true
        onSpeak?(self, utterance)
    }

    func stopSpeaking(at boundary: AVSpeechBoundary) -> Bool {
        isSpeaking = false
        return true
    }

    /// The delegate methods are ObjC-optional, so delivery goes through
    /// perform rather than an existential call.
    func deliverDidFinish(_ utterance: AVSpeechUtterance) {
        delegate?.perform(#selector(AVSpeechSynthesizerDelegate.speechSynthesizer(_:didFinish:)),
                          with: AVSpeechSynthesizer(), with: utterance)
    }

    func deliverDidCancel(_ utterance: AVSpeechUtterance) {
        delegate?.perform(#selector(AVSpeechSynthesizerDelegate.speechSynthesizer(_:didCancel:)),
                          with: AVSpeechSynthesizer(), with: utterance)
    }

    func deliverDidStart(_ utterance: AVSpeechUtterance) {
        delegate?.perform(#selector(AVSpeechSynthesizerDelegate.speechSynthesizer(_:didStart:)),
                          with: AVSpeechSynthesizer(), with: utterance)
    }

    func deliverWillSpeak(_ utterance: AVSpeechUtterance) {
        // The delegate method takes a struct NSRange, which perform(with:)
        // cannot pass — invoke it through its C function pointer instead.
        guard let obj = delegate as? NSObject else { return }
        let sel = #selector(AVSpeechSynthesizerDelegate.speechSynthesizer(_:willSpeakRangeOfSpeechString:utterance:))
        typealias Fn = @convention(c) (AnyObject, Selector, AVSpeechSynthesizer, NSRange, AVSpeechUtterance) -> Void
        let fn = unsafeBitCast(obj.method(for: sel), to: Fn.self)
        fn(obj, sel, AVSpeechSynthesizer(), NSRange(location: 0, length: min(5, (utterance.speechString as NSString).length)), utterance)
    }

}

final class AVSpeechTtsEngineTests: XCTestCase {

    func test_warmUp_doesNotThrow() {
        let engine = AVSpeechTtsEngine()
        engine.warmUp(language: "en-US")
        // Verifying it doesn't crash
    }

    func test_speak_completesAsync() async {
        let engine = AVSpeechTtsEngine()
        await engine.speak(text: "Hello", language: "en-US")
        // Verifies async speak completion via delegate
    }

    func test_cancel_stopsSpeaking() {
        let engine = AVSpeechTtsEngine()
        engine.cancel()
        // Verifies no crash on cancel when not speaking
    }

    func test_releaseEngine_stopsEngine() {
        let engine = AVSpeechTtsEngine()
        engine.releaseEngine()
        // Verifies no crash on release
    }

    func test_speak_cancelsPreviousUtterance() async {
        let engine = AVSpeechTtsEngine()
        // Start first utterance (fire and forget to simulate ongoing speech)
        Task {
            await engine.speak(text: "Long text that takes time", language: "en-US")
        }
        // Give it a moment to start
        try? await Task.sleep(nanoseconds: 50_000_000)
        // Second utterance should cancel the first
        await engine.speak(text: "Short", language: "en-US")
        // Should complete without hanging
    }

    func test_warmUp_acceptsAnyLanguage() {
        let engine = AVSpeechTtsEngine()
        engine.warmUp(language: "ja-JP")
        engine.warmUp(language: "fr-FR")
        engine.warmUp(language: "es-ES")
        // Verifying no crash with different languages
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
        try? await Task.sleep(nanoseconds: 50_000_000)
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
        try? await Task.sleep(nanoseconds: 50_000_000)
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
}
