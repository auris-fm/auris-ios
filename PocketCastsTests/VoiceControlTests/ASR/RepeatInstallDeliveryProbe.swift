import AVFoundation
import XCTest
@testable import podcasts

/// SYNCHRONIZED TRACE (repeat-install work): establishes WHEN callbacks arrive, WHEN blocks are
/// dequeued/delivered into the reference, and in what ORDER — rather than inferring a stop-flush
/// mechanism from two snapshots taken at different instants.
///
/// Counters are wired and synchronized: the tap callback increments `callbacks`; the handoff's
/// `onDeliveryDequeued` hook increments `dequeued`; both are read under the same lock, and every
/// transition is stamped with a monotonic sequence number so arrival and append ordering is
/// visible in one trace.
final class RepeatInstallDeliveryProbe: XCTestCase {

    final class Trace {
        private let lock = NSLock()
        private var events: [String] = []
        private var seq = 0
        private(set) var callbacks = 0
        private(set) var dequeued = 0
        func record(_ what: String) {
            lock.lock(); seq += 1; events.append("#\(seq) \(what)"); lock.unlock()
        }
        func didCallback() { lock.lock(); seq += 1; callbacks += 1; events.append("#\(seq) callback(\(callbacks))"); lock.unlock() }
        func didDequeue() { lock.lock(); seq += 1; dequeued += 1; events.append("#\(seq) dequeue(\(dequeued))"); lock.unlock() }
        func snapshotState() -> (events: [String], callbacks: Int, dequeued: Int) {
            lock.lock(); defer { lock.unlock() }; return (events, callbacks, dequeued)
        }
    }

    func testTraceCallbackArrivalAndDeliveryOrdering() throws {
        let f = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let mixer = AVAudioMixerNode()
        engine.attach(player)
        engine.attach(mixer)
        engine.connect(player, to: mixer, format: f)
        engine.connect(mixer, to: engine.outputNode, format: f)

        let reference = PlaybackEchoReference()
        let handoff = EchoReferenceHandoff(reference: reference, capacity: 16)
        let trace = Trace()
        handoff.onDeliveryDequeued = { trace.didDequeue() }

        let tap = EpisodeOutputTap(engine: engine)
        tap.handoff = handoff
        // COUNT CALLBACK ARRIVAL THROUGH THE TAP'S OWN CLOSURE: CoreAudio refuses a second tap on
        // the same bus, so the observer wraps the closure install() captured rather than adding
        // another tap. The wrapper runs the production closure and counts the arrival.
        tap.onCallbackArrived = { trace.didCallback() }
        trace.record("install#1")
        tap.install()
        trace.record("install#2")
        tap.install()

        try engine.enableManualRenderingMode(.offline, format: f, maximumFrameCount: 4_096)
        defer { engine.disableManualRenderingMode() }
        engine.prepare()
        try engine.start()
        defer { engine.stop() }

        let count = 32_768
        let buf = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: f, frameCapacity: AVAudioFrameCount(count)))
        buf.frameLength = AVAudioFrameCount(count)
        if let ch = buf.floatChannelData?[0] {
            for i in 0..<count { ch[i] = Float(sin(Double(i) * 0.05) * 0.4) }
        }
        player.scheduleBuffer(buf)
        player.play()
        let out = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat,
                                                 frameCapacity: engine.manualRenderingMaximumFrameCount))
        var rendered = 0
        var attempts = 0
        while rendered < count && attempts < 1_000 {
            attempts += 1
            let s = try engine.renderOffline(engine.manualRenderingMaximumFrameCount, to: out)
            if s == .success { rendered += Int(out.frameLength) } else if s == .error { break }
        }
        trace.record("renderLoop done rendered=\(rendered)")

        let beforeStop = trace.snapshotState()
        let countBeforeStop = reference.snapshot().count
        trace.record("beforeStop callbacks=\(beforeStop.callbacks) dequeued=\(beforeStop.dequeued) refCount=\(countBeforeStop)")

        engine.stop()
        trace.record("afterStop")
        handoff.drain()
        let afterAll = trace.snapshotState()
        let countAfterDrain = reference.snapshot().count
        trace.record("afterDrain callbacks=\(afterAll.callbacks) dequeued=\(afterAll.dequeued) refCount=\(countAfterDrain)")

        for event in afterAll.events { print("TRACE \(event)") }
        print("TRACE summary callbacks=\(afterAll.callbacks) dequeued=\(afterAll.dequeued) refBefore=\(countBeforeStop) refAfter=\(countAfterDrain)")

        XCTAssertGreaterThan(afterAll.callbacks, 0, "no callbacks were observed at all")
        XCTAssertGreaterThan(countAfterDrain, 0, "the reference received nothing after the explicit drain")
    }
}
