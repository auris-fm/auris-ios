import XCTest
@testable import podcasts

/// PR50 review r4357901593 fix: the bleed-filter inputs (retained samples, audible-end offset,
/// render anchor) must come from ONE lock acquisition. Split reads straddling an append displace
/// the alignment by exactly the samples appended between the reads.
final class ConsistentEchoObservationTests: XCTestCase {

    /// THE SPLIT-READ DEFECT, pinned at the arithmetic level: the offset a SECOND acquisition
    /// returns no longer describes the SNAPSHOT the first acquisition took. The filter compared
    /// the mic segment against the stale samples but aligned it with the post-append offset —
    /// displaced by exactly the appended count — which is how the assistant's own voice passed
    /// the bleed filter while talking over a streaming answer.
    func test_splitReadsStraddlingAnAppendDisplaceTheAlignmentByTheAppend() {
        let reference = PlaybackEchoReference(sampleRate: 16_000, retainedSeconds: 0.05)
        let capacity = 16_000 * 5 / 100 // 800 samples retained
        reference.append([Float](repeating: 0.1, count: capacity))
        // Rendered position AT the snapshot's end: the audible end is the last retained sample.
        reference.recordRenderPosition(PlaybackRenderAnchor(
            renderedFrames: Double(capacity), sourceSampleRate: 16_000, hostTime: 0))

        let staleSamples = reference.snapshot()
        let correctOffsetForStaleSamples = capacity // rendered end == stale window end

        // The producer appends BETWEEN the two reads (what a streaming answer does continuously).
        let appended = 300
        reference.append([Float](repeating: 0.1, count: appended))
        let splitOffset = reference.audibleEndOffsetInRetainedWindow()

        let audible = try! XCTUnwrap(splitOffset)
        // The window slid forward by `appended`, so the recomputed offset is displaced by exactly
        // that much from the offset the stale snapshot required.
        XCTAssertEqual(audible, correctOffsetForStaleSamples - appended,
                       "premise: a second read after an append describes the NEW window")
        XCTAssertNotEqual(audible, correctOffsetForStaleSamples,
                          "premise: the split pair disagrees by the appended count")
        _ = staleSamples
    }

    /// THE FIX: `consistentObservation()` reads samples, offset and anchor under ONE lock, and
    /// the engine's filter path passes that observation onward. A producer appending
    /// concurrently can never make the returned pair disagree: every observation taken during
    /// the append storm satisfies 0 ≤ offset ≤ samples.count — the audible position is always
    /// inside the window the RETURNED samples index.
    func test_concurrentAppendsNeverSplitTheObservation() {
        // LARGE window + THROTTLED producer: the producer advances the anchor continuously for
        // the whole observation run (an append every ~150µs across ~150ms), so anchor advances
        // land inside any split read's inter-acquisition gaps at a high rate. The first version
        // of this control exhausted its headroom in ~9ms and the split mutant survived it.
        let reference = PlaybackEchoReference(sampleRate: 16_000, retainedSeconds: 10.0)
        let capacity = 16_000 * 10 // 160000
        let stride = 8
        let appended = Counter() // total samples the producer has appended
        reference.append([Float](repeating: 0.1, count: capacity / 2))
        appended.bump(by: capacity / 2)
        // NOTE: the producer below runs UNGATED (no sleep): an anchor advance every ~1µs is
        // what makes a nanosecond-scale inter-acquisition gap detectable at all. A throttled
        // producer never lands an advance inside a split read's gap and the mutant survives.

        reference.recordRenderPosition(PlaybackRenderAnchor(
            renderedFrames: Double(capacity / 2), sourceSampleRate: 16_000, hostTime: 0))

        let producerStop = AtomicFlag()
        var producer: Thread? = nil
        producer = Thread { [appended] in
            var tick: Float = 0.1
            while !producerStop.load() {
                // Stay below capacity so the window never trims: count == tracked total.
                if appended.load() + stride > capacity * 9 / 10 { break }
                tick += 0.001
                reference.append([Float](repeating: tick, count: stride))
                let total = appended.bump(by: stride)
                reference.recordRenderPosition(PlaybackRenderAnchor(
                    renderedFrames: Double(total), sourceSampleRate: 16_000, hostTime: 0))
            }
        }
        producer?.start()
        for iteration in 0..<150_000 {
            let observation = reference.consistentObservation()
            if let offset = observation.audibleEndOffset {
                XCTAssertTrue(offset >= 0 && offset <= observation.samples.count,
                              "iteration \(iteration): the offset (\(offset)) must index the "
                                  + "returned window (\(observation.samples.count) samples) — a "
                                  + "violation means the observation was split across reads")
                if let anchor = observation.renderAnchor {
                    // The window never trims and the anchor IS the appended total the window
                    // ends at, so a consistent read's offset equals its own anchor.
                    XCTAssertEqual(offset, Int(anchor.renderedPipelineSamples),
                                   "iteration \(iteration): the offset must be computed from "
                                       + "the anchor read WITH it — a mismatch means the pair "
                                       + "was split across reads")
                }
            }
        }
        producerStop.store(true)
        // Join the producer (review nit): no busy loop contending into subsequent tests.
        let joinDeadline = Date().addingTimeInterval(5)
        while producer?.isFinished == false && Date() < joinDeadline {
            Thread.sleep(forTimeInterval: 0.002)
        }
    }

    /// The engine consumes the OBSERVATION it took, not a fresh read: an append landing after the
    /// observation must not shift the offset the filter uses. A fresh re-read after the append
    /// returns an offset displaced by the append — this control fails on exactly that.
    func test_engineOffsetUsesTheObservationItTookNotAFreshRead() {
        let reference = PlaybackEchoReference(sampleRate: 16_000, retainedSeconds: 0.05)
        let capacity = 16_000 * 5 / 100
        reference.append([Float](repeating: 0.1, count: capacity))
        reference.recordRenderPosition(PlaybackRenderAnchor(
            renderedFrames: Double(capacity), sourceSampleRate: 16_000, hostTime: 0))

        let observation = reference.consistentObservation()
        let expected = try! XCTUnwrap(observation.audibleEndOffset)

        // The producer appends AFTER the observation was taken.
        reference.append([Float](repeating: 0.1, count: 300))

        let engine = VoiceAsrEngine(
            capture: ParkedCapture(),
            segmenter: NativeVadSegmenter(threshold: 0.020),
            backend: IdleBackend(),
            signalFilter: SignalFilter(),
            wakeWordDetector: QuietWake(),
            gracePeriodSignal: GracePeriodSignal())
        engine.setEchoReference(reference)
        let used = engine.engineOffsetFromObservationForTesting(observation: observation)
        XCTAssertEqual(used, expected,
                       "the filter must use the offset from the observation it took; a fresh "
                           + "re-read after an append is displaced and misaligns the correlation")
    }

    /// THE HOOK CLOSURE RACE (r4357901105): `finishTurn()` must run the close hook EXACTLY ONCE
    /// even when two turn-end paths race — the hook is taken-and-cleared under `bindingLock`, so
    /// only one caller wins the non-nil swap. The old pattern (run, then nil, unsynchronized)
    /// closed the lifetime twice under this arrangement.
    func test_concurrentFinishTurnsCloseTheLifetimeExactlyOnce() {
        let socket = AppOperationResultSocket(requestId: "req-finish-race")
        // The hook bodies take a moment, so on the OLD unsynchronized pattern (run-then-nil)
        // both racing callers observe the hook non-nil before either clears it — the double run
        // is the defect, made wide enough to be caught.
        let closes = Counter()
        socket.closeHook = { Thread.sleep(forTimeInterval: 0.02); _ = closes.bump() }
        let claims = Counter()
        socket.claimHook = { Thread.sleep(forTimeInterval: 0.02); _ = claims.bump() }

        // All four turn-end paths arrive together and are RELEASED together, so on the old
        // unsynchronized pattern multiple callers could observe the hook non-nil.
        let ready = DispatchSemaphore(value: 0)
        let go = DispatchSemaphore(value: 0)
        var threads: [Thread] = []
        let bodies: [() -> Void] = [{ socket.finishTurn() }, { socket.finishTurn() },
                                    { socket.claimConsumerOwnership() },
                                    { socket.claimConsumerOwnership() }]
        for body in bodies {
            let thread = Thread { [body] in
                ready.signal()
                go.wait()
                body()
            }
            threads.append(thread)
            thread.start()
        }
        for _ in threads { XCTAssertEqual(ready.wait(timeout: .now() + 5), .success, "premise") }
        go.signal(); go.signal(); go.signal(); go.signal()
        // Deterministic join: all four threads must finish before the assertions read.
        for t in threads { t.join() }
        XCTAssertEqual(closes.load(), 1, "the close hook must run exactly once across racing turn ends")
        XCTAssertEqual(claims.load(), 1, "the claim hook must run exactly once across racing consumers")
        XCTAssertTrue(socket.isTurnFinished, "the turn reads finished after its close hook was taken")
    }
}

/// Stand-ins so the offset-arithmetic seam can run without audio or network.
private final class ParkedCapture: NativeAudioCapture { }
private final class IdleBackend: AsrBackend {
    var requiredModel: ModelSpec { ModelSpec(id: "test", files: [], targetDir: "/tmp/test") }
    var capabilities: AsrCapabilities {
        AsrCapabilities(languages: ["en"], canTranslateToEnglish: false, requiresHardwareAccel: false)
    }
    func ensureReady() async -> Result<Void, Error> { .success(()) }
    func release() {}
    func transcribe(samples: [Float], sampleRateHz: Int) async -> AsrResult {
        AsrResult(text: "test", detectedLanguage: "en")
    }
}
private final class QuietWake: WakeWordDetectorProtocol {
    func release() {}
    func detect(samples: [Float], sampleRate: Int) -> WakeWordResult {
        .notDetected(confidence: 0)
    }
}

/// Minimal primitives so the controls need no framework beyond XCTest.
private final class Counter {
    private let lock = NSLock()
    private var value = 0
    func load() -> Int { lock.lock(); defer { lock.unlock() }; return value }
    @discardableResult
    func bump() -> Int { bump(by: 1) }
    func bump(by delta: Int) -> Int { lock.lock(); value += delta; lock.unlock(); return value }
}

private extension Thread {
    /// Bounded join for a thread whose body is known to terminate.
    func join(timeout: TimeInterval = 5) {
        let deadline = Date().addingTimeInterval(timeout)
        while !isFinished && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.002)
        }
    }
}

/// Minimal atomic flag so the controls need no framework beyond XCTest.
private final class AtomicFlag {
    private let lock = NSLock()
    private var value = false
    func load() -> Bool { lock.lock(); defer { lock.unlock() }; return value }
    func store(_ v: Bool) { lock.lock(); value = v; lock.unlock() }
}
