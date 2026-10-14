import XCTest
import AVFoundation
@testable import podcasts

/// THE THREE DETERMINISTIC ADMISSION ORDERS (@spec dca18343), tested SEPARATELY.
///
/// Policy:
///   1. a retired callback SUBMITTED after rotation             -> REFUSE
///   2. an old block ENQUEUED before rotation, never appended   -> REFUSE (rotation wins)
///   3. an old block ALREADY APPENDED while its producer was current -> RETAIN
///
/// SAMPLE-RETENTION ONLY. Any anchor assertion is deliberately absent from order 3: an earlier
/// version asserted the recorded anchor survives rotation, but that version never established an
/// anchor first (its samples carried no range or renderedAt), so the non-nil comparison had a
/// MISSING PRECONDITION and was withdrawn. See helper-evidence/ledger/admission-orders-FINDING.txt.
final class HandoffAdmissionOrderTests: XCTestCase {

    private func flat(_ frames: Int, _ value: Float) -> [Float] {
        [Float](repeating: value, count: frames)
    }

    private func makeHandoff() -> (PlaybackEchoReference, EchoReferenceHandoff) {
        let reference = PlaybackEchoReference()
        let handoff = EchoReferenceHandoff(reference: reference, capacity: 16)
        return (reference, handoff)
    }

    /// ORDER 1: a retired callback is SUBMITTED after the rotation.
    func testOrder1CallbackSubmittedAfterRotationIsRefused() {
        let (reference, handoff) = makeHandoff()
        let old = EchoReferenceHandoff.ProducerIdentity(kind: .episodeTap, incarnation: 1)
        let new = EchoReferenceHandoff.ProducerIdentity(kind: .episodeTap, incarnation: 2)

        handoff.rotateIncarnation(for: .episodeTap, to: 1)
        handoff.rotateIncarnation(for: .episodeTap, to: 2)
        handoff.submit(flat(256, 0.4), producer: old, sampleRate: 44_100)
        handoff.submit(flat(256, -0.5), producer: new, sampleRate: 44_100)
        handoff.drain()

        let delivered = reference.snapshot()
        print("[ORD1] delivered=", delivered.count, " old(0.4)=", delivered.contains(0.4),
              " new(-0.5)=", delivered.contains(-0.5))
        XCTAssertFalse(delivered.contains(0.4), "ORDER 1: a retired callback submitted after rotation is refused")
        XCTAssertTrue(delivered.contains(-0.5), "ORDER 1: the new producer is accepted")
    }

    /// ORDER 2: the old block is ENQUEUED while current, then rotation wins BEFORE its append.
    func testOrder2BlockEnqueuedBeforeRotationButNotAppendedIsRefused() {
        let (reference, handoff) = makeHandoff()
        let old = EchoReferenceHandoff.ProducerIdentity(kind: .episodeTap, incarnation: 1)
        let new = EchoReferenceHandoff.ProducerIdentity(kind: .episodeTap, incarnation: 2)
        handoff.rotateIncarnation(for: .episodeTap, to: 1)

        var rotated = false
        handoff.onDeliveryDequeued = {
            if !rotated {
                rotated = true
                handoff.rotateIncarnation(for: .episodeTap, to: 2)
            }
        }

        handoff.submit(flat(256, 0.4), producer: old, sampleRate: 44_100)
        handoff.drain()
        handoff.onDeliveryDequeued = nil
        handoff.submit(flat(256, -0.5), producer: new, sampleRate: 44_100)
        handoff.drain()

        let delivered = reference.snapshot()
        print("[ORD2] delivered=", delivered.count, " old(0.4)=", delivered.contains(0.4),
              " new(-0.5)=", delivered.contains(-0.5))
        XCTAssertFalse(delivered.contains(0.4),
                       "ORDER 2: rotation winning before the append must refuse the old block")
        XCTAssertTrue(delivered.contains(-0.5), "ORDER 2: the new producer is accepted")
    }

    /// ORDER 3: the old block was ALREADY APPENDED while its producer was current -> RETAINED.
    /// SAMPLE-RETENTION ONLY; no anchor assertion (see the class comment).
    func testOrder3BlockAlreadyAppendedWhileCurrentIsRetained() {
        let (reference, handoff) = makeHandoff()
        let old = EchoReferenceHandoff.ProducerIdentity(kind: .episodeTap, incarnation: 1)
        handoff.rotateIncarnation(for: .episodeTap, to: 1)

        handoff.submit(flat(256, 0.4), producer: old, sampleRate: 44_100)
        handoff.drain()
        let afterAppend = reference.snapshot().count
        XCTAssertGreaterThan(afterAppend, 0, "the block must be appended while current")

        handoff.rotateIncarnation(for: .episodeTap, to: 2)
        handoff.drain()

        let delivered = reference.snapshot()
        print("[ORD3] afterAppend=", afterAppend, " afterRotation=", delivered.count,
              " retained(0.4)=", delivered.contains(0.4))
        XCTAssertTrue(
            delivered.contains(0.4),
            "ORDER 3: audio appended while its producer was CURRENT is retained after rotation"
        )
    }
}

/// PRODUCTION CALLBACK LIFECYCLE control (@spec): install -> REMOVE -> install.
///
/// The earlier lifecycle probe covered a DOUBLE install with no intervening remove. This covers the
/// cycle, which is the shape a graph replacement actually produces: after an explicit remove, a fresh
/// install must resolve the feeder again, deliver, and rotate the identity MONOTONICALLY.
final class EpisodeTapLifecycleTests: XCTestCase {

    private func frames() -> AVAudioFrameCount { 44_100 }

    @MainActor
    func testInstallRemoveInstallCycleResolvesDeliversAndRotatesMonotonically() throws {
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
        let tap = EpisodeOutputTap(engine: engine)
        tap.handoff = handoff

        // 1) INSTALL
        tap.install()
        let i1 = tap.producerIdentity.incarnation
        XCTAssertTrue(tap.isInstalledOnOutputNode(mixer), "first install resolves the feeder")

        // 2) REMOVE
        tap.remove()
        XCTAssertFalse(tap.isInstalledOnOutputNode(mixer), "remove takes the tap off the feeder")

        // 3) INSTALL AGAIN
        tap.install()
        let i2 = tap.producerIdentity.incarnation
        XCTAssertTrue(tap.isInstalledOnOutputNode(mixer), "the re-install resolves the feeder again")
        XCTAssertGreaterThan(i2, i1, "identities must rotate MONOTONICALLY across the cycle")

        // And the re-installed tap DELIVERS.
        try engine.enableManualRenderingMode(.offline, format: f, maximumFrameCount: 4096)
        defer { engine.disableManualRenderingMode() }
        engine.prepare()
        try engine.start()

        let count = frames()
        let buf = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: f, frameCapacity: count))
        buf.frameLength = count
        let ch = try XCTUnwrap(buf.floatChannelData?[0])
        for i in 0..<Int(count) { ch[i] = Float(sin(Double(i) * 0.05) * 0.4) }
        player.scheduleBuffer(buf)
        player.play()
        let out = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat,
                                                 frameCapacity: engine.manualRenderingMaximumFrameCount))
        var rendered = 0
        while rendered < Int(count) {
            let s = try engine.renderOffline(engine.manualRenderingMaximumFrameCount, to: out)
            if s == .success { rendered += Int(out.frameLength) } else if s == .error { break }
        }
        handoff.drain()

        let delivered = reference.snapshot()
        let peak = delivered.map { abs($0) }.max() ?? 0
        print("[CYCLE] i1=", i1, " i2=", i2, " delivered=", delivered.count, " peak=", peak)
        XCTAssertFalse(delivered.isEmpty, "the re-installed tap must deliver reference audio")
        XCTAssertGreaterThan(peak, 0.01, "the delivered audio must be non-empty")
    }

    /// REPEAT INSTALL with NO intervening remove — the case that actually exercises install()'s OWN
    /// cleanup. The explicit-remove cycle above does NOT: the test removed the tap itself, so a
    /// mutated install() that skips its own remove() would go unnoticed. This case supplies the
    /// missing falsification target. CoreAudio refuses two taps on one bus, so a surviving prior tap
    /// would surface here.
    @MainActor
    func testRepeatInstallWithoutRemoveStillDelivers() throws {
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
        let tap = EpisodeOutputTap(engine: engine)
        tap.handoff = handoff

        tap.install()
        let i1 = tap.producerIdentity.incarnation
        // NO REMOVE: install again, so install() must clean up ITS OWN prior tap.
        tap.install()
        let i2 = tap.producerIdentity.incarnation
        XCTAssertGreaterThan(i2, i1, "a repeat install still rotates the identity")

        try engine.enableManualRenderingMode(.offline, format: f, maximumFrameCount: 4096)
        defer { engine.disableManualRenderingMode() }
        engine.prepare()
        try engine.start()

        let count = frames()
        let buf = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: f, frameCapacity: count))
        buf.frameLength = count
        let ch = try XCTUnwrap(buf.floatChannelData?[0])
        for i in 0..<Int(count) { ch[i] = Float(sin(Double(i) * 0.05) * 0.4) }
        player.scheduleBuffer(buf)
        player.play()
        let out = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat,
                                                 frameCapacity: engine.manualRenderingMaximumFrameCount))
        var rendered = 0
        while rendered < Int(count) {
            let s = try engine.renderOffline(engine.manualRenderingMaximumFrameCount, to: out)
            if s == .success { rendered += Int(out.frameLength) } else if s == .error { break }
        }
        handoff.drain()

        let delivered = reference.snapshot()
        let peak = delivered.map { abs($0) }.max() ?? 0
        print("[REPEAT] i1=", i1, " i2=", i2, " delivered=", delivered.count, " peak=", peak)
        XCTAssertFalse(delivered.isEmpty, "a repeat install must still deliver (its own cleanup ran)")
        XCTAssertGreaterThan(peak, 0.01, "the delivered audio must be non-empty")
    }
    /// FAILED-REPLACEMENT CLEANUP (@spec): when the feeder CANNOT be resolved, a prior install's tap
    /// must NOT be left behind. The guard must not return before removing.
    @MainActor
    func testFailedReplacementLeavesNoPriorTapInstalled() throws {
        let f = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let mixer = AVAudioMixerNode()
        engine.attach(player)
        engine.attach(mixer)
        engine.connect(player, to: mixer, format: f)
        engine.connect(mixer, to: engine.outputNode, format: f)

        let tap = EpisodeOutputTap(engine: engine)
        tap.handoff = EchoReferenceHandoff(reference: PlaybackEchoReference(), capacity: 16)
        tap.install()
        XCTAssertTrue(tap.isInstalledOnOutputNode(mixer), "the first install must place the tap")

        // BREAK THE GRAPH so the feeder cannot be resolved, then re-install.
        engine.disconnectNodeOutput(mixer)
        tap.install()

        XCTAssertFalse(
            tap.isInstalledOnOutputNode(mixer),
            "a FAILED replacement must not leave the prior tap behind on the old feeder"
        )
    }
}
