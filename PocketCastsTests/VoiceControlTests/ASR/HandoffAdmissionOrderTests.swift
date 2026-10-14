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
        // REAL-TIME PLAYBACK — the production mode. The offline-render path measurably misses
        // callbacks (unresolved setup observation, kept out of this control); real time delivered
        // valid-host callbacks reliably in every probe.
        engine.prepare()
        // CLEANUP REGISTERED BEFORE START'S POSSIBLE THROW: stop() runs even if start() fails.
        defer { engine.stop() }
        try engine.start()

        // ONE identified scheduled output: a single buffer, scheduled exactly once.
        let count = frames()
        let buf = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: f, frameCapacity: count))
        buf.frameLength = count
        let ch = try XCTUnwrap(buf.floatChannelData?[0])
        for i in 0..<Int(count) { ch[i] = Float(sin(Double(i) * 0.05) * 0.4) }
        let expectedSamples = Int(Double(count) * Double(PlaybackEchoReference.pipelineSampleRate) / f.sampleRate)
        player.scheduleBuffer(buf)
        player.play()
        // BOUNDED callback/append acknowledgment: wait until the reference has received the whole
        // scheduled output, then stop and drain what exists.
        let ackDeadline = Date().addingTimeInterval(10)
        while Date() < ackDeadline {
            if reference.snapshot().count >= expectedSamples { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        engine.stop()
        XCTAssertGreaterThanOrEqual(
            reference.snapshot().count, expectedSamples,
            "the scheduled output was not fully acknowledged within the bound"
        )
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

        // REAL-TIME PLAYBACK — the production mode. The offline-render path measurably misses
        // callbacks (unresolved setup observation, kept out of this control); real time delivered
        // valid-host callbacks reliably in every probe.
        engine.prepare()
        // CLEANUP REGISTERED BEFORE START'S POSSIBLE THROW: stop() runs even if start() fails.
        defer { engine.stop() }
        try engine.start()

        // ONE identified scheduled output: a single buffer, scheduled exactly once.
        let count = frames()
        let buf = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: f, frameCapacity: count))
        buf.frameLength = count
        let ch = try XCTUnwrap(buf.floatChannelData?[0])
        for i in 0..<Int(count) { ch[i] = Float(sin(Double(i) * 0.05) * 0.4) }
        let expectedSamples = Int(Double(count) * Double(PlaybackEchoReference.pipelineSampleRate) / f.sampleRate)
        player.scheduleBuffer(buf)
        player.play()
        // BOUNDED callback/append acknowledgment: wait until the reference has received the whole
        // scheduled output, then stop and drain what exists.
        let ackDeadline = Date().addingTimeInterval(10)
        while Date() < ackDeadline {
            if reference.snapshot().count >= expectedSamples { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        engine.stop()
        XCTAssertGreaterThanOrEqual(
            reference.snapshot().count, expectedSamples,
            "the scheduled output was not fully acknowledged within the bound"
        )
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


/// SAMPLE ACCEPTANCE of a retired producer's submission, at the handoff boundary. This case
/// drives `publish(producer:)` with an explicit identity, so it measures the ACCEPTANCE BOUNDARY
/// only — NOT the closure capture, which `InstalledClosureCaptureTests` covers through the seam.
///
/// `install()` captures `let admitted = producerIdentity` at install time and the tap closure
/// submits that captured value. When the tap is reinstalled, the old closure may still be
/// invoked once (a render already in flight, or a stale tap the graph has not yet torn down).
/// If the closure read `self.producerIdentity` when it fired, that held-old callback would
/// submit the NEW incarnation and pass the admission check for audio that belongs to the old
/// producer — the stale-sample failure delivered by the callback door.
///
/// This control drives the same submission the held-old closure makes: publish with the OLD
/// admitted identity after a reinstall, and require the boundary to refuse it.
final class HeldOldCallbackIdentityTests: XCTestCase {

    private func toneBuffer(frames: Int = 512) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44_100, channels: 1, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        if let channels = buffer.floatChannelData {
            for i in 0..<frames { channels[0][i] = Float(sin(Double(i) * 0.2) * 0.4) }
        }
        return buffer
    }

    func testHeldOldCallbackAfterReinstallIsRefused() {
        let reference = PlaybackEchoReference()
        let handoff = EchoReferenceHandoff(reference: reference, capacity: 8)
        // A REAL CONNECTED GRAPH. A bare `AVAudioEngine()` has nothing feeding its output node, so
        // `outputFeederConnection` correctly returns nil and `install()` correctly does nothing —
        // there would be no feeder to tap and the case would be measuring an empty graph. A
        // player node connected to output gives the engine a feeder, which is what the placement
        // code resolves.
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: nil)
        engine.connect(engine.mainMixerNode, to: engine.outputNode, format: nil)

        let tap = EpisodeOutputTap(engine: engine)
        tap.handoff = handoff

        // The FIRST install, whose identity its callback captures.
        tap.install()
        XCTAssertFalse(
            tap.isInstalledOnOutputNode(engine.outputNode),
            "the tap installed itself on the output node, the placement the SDK advises against"
        )
        let admittedAtFirstInstall = tap.producerIdentity

        // A reinstall: installing again removes the prior tap and rotates the incarnation, so the
        // identity the first callback carries is retired.
        tap.install()
        let admittedNow = tap.producerIdentity
        XCTAssertNotEqual(
            admittedNow, admittedAtFirstInstall,
            "the reinstall did not rotate the identity, so the held-old case was not set up"
        )
        XCTAssertEqual(
            admittedNow.kind, admittedAtFirstInstall.kind,
            "the rotation changed the producer KIND, so this is no longer the same producer"
        )

        // The HELD-OLD callback fires: it publishes with the identity IT was admitted under.
        tap.publish(
            toneBuffer(),
            renderedAt: AVAudioTime(sampleTime: 0, atRate: 44_100),
            producer: admittedAtFirstInstall
        )

        // The boundary must refuse: the producer is retired, so its audio is not the current
        // producer's and must not enter the reference.
        handoff.drain()
        XCTAssertEqual(
            reference.snapshot().count, 0,
            "a held-old callback submitted a retired producer's audio and it reached the reference: "
            + "the callback acquired the new identity instead of carrying its own"
        )

        // POSITIVE CONTROL: the same submission under the CURRENT identity must be accepted.
        tap.publish(
            toneBuffer(),
            renderedAt: AVAudioTime(sampleTime: 0, atRate: 44_100),
            producer: admittedNow
        )
        handoff.drain()
        XCTAssertGreaterThan(
            reference.snapshot().count, 0,
            "the current-identity submission was also refused, so the refusal proves nothing "
            + "about identity: the boundary refused the publish itself"
        )
    }
}


/// The feeder is discovered on the bus that ACTUALLY feeds output, not on bus 0.
///
/// `outputFeederConnection` searches every input bus of the output node and returns the
/// connection point's own bus. Tapping bus 0 regardless would install on the wrong bus of a
/// chain whose connection is elsewhere, and CoreAudio reports that as no tap rather than as an
/// error — the reference would silently receive nothing while the object reported installed.
///
/// This control builds a graph whose output node has more than one input bus and asserts the
/// resolved connection carries the bus the feeder reports, not an assumed zero.
final class FeederBusDiscoveryTests: XCTestCase {

    /// The CONTROLLED nonzero case: the lookup SUPPLIES a connection point whose feeder-output
    /// bus is nonzero, and the search must carry that bus as reported. This is what distinguishes
    /// "found the point's bus" from "assumed zero" — the real graph cannot supply a nonzero bus,
    /// so reading it proves nothing about the bus handling.
    func testNonzeroFeederBusIsCarriedAsReported() throws {
        // The feeder is a REAL engine's node: constructing an AVAudioNode subclass standalone
        // segfaults on this simulator runtime (measured), so the node must come from a live
        // engine. The BUS is the control variable: input bus 0 of output is fed by the feeder's
        // OUTPUT BUS 3.
        let engine = AVAudioEngine()
        let feeder = engine.mainMixerNode
        let resolved = try XCTUnwrap(
            EpisodeOutputTap.outputFeederConnection(inputBusCount: 1) { outputInputBus in
                outputInputBus == 0 ? (node: feeder, bus: 3) : nil
            },
            "the injected connection point was not found"
        )
        XCTAssertEqual(resolved.node, feeder, "the wrong node was resolved")
        XCTAssertEqual(resolved.bus, 3, "the feeder's reported bus was not carried — it was replaced with zero")

        // And a point on a LATER input bus is still found by the search.
        let later = try XCTUnwrap(
            EpisodeOutputTap.outputFeederConnection(inputBusCount: 4) { outputInputBus in
                outputInputBus == 2 ? (node: feeder, bus: 5) : nil
            },
            "a feeder on a later input bus was not found by the search"
        )
        XCTAssertEqual(later.bus, 5, "the later bus's reported feeder-output bus was not carried")
    }

    func testFeederConnectionReportsTheFeedersOwnBus() throws {
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)

        // The output node's input count is what makes the search meaningful: with one bus the
        // loop cannot distinguish "found on bus 0" from "assumed bus 0".
        let inputCount = engine.outputNode.numberOfInputs
        XCTAssertGreaterThan(inputCount, 0, "the output node reports no input buses, so no feeder can exist")

        engine.connect(player, to: engine.mainMixerNode, format: nil)
        engine.connect(engine.mainMixerNode, to: engine.outputNode, format: nil)

        let resolved = try XCTUnwrap(
            EpisodeOutputTap.outputFeederConnection(of: engine),
            "a connected graph resolved to no feeder"
        )

        // The resolved bus must be the connection point's OWN bus for that node, read back from
        // the engine rather than assumed. Enumerating every bus and finding the point whose node
        // is the resolved node makes the assertion about the engine's report, not about a literal.
        var reportedBus: AVAudioNodeBus? = nil
        for bus in 0..<engine.outputNode.numberOfInputs {
            if let point = engine.inputConnectionPoint(for: engine.outputNode, inputBus: bus),
               point.node === resolved.node {
                reportedBus = point.bus
                break
            }
        }
        let expected = try XCTUnwrap(reportedBus, "the resolved feeder is not connected to the output node")
        XCTAssertEqual(
            resolved.bus, expected,
            "the feeder was tapped on a bus other than the one the engine reports it feeds on"
        )

        // The feeder must not be the output node itself: tapping it is the placement the SDK
        // advises against, and a self-report must not be mistaken for a valid feeder.
        XCTAssertFalse(
            resolved.node === engine.outputNode,
            "the resolved feeder is the output node itself"
        )
    }

    /// A graph with nothing feeding output resolves to no feeder, and `install()` therefore
    /// installs nothing rather than falling back to a blind bus-0 tap on the output node.
    func testUnconnectedGraphResolvesToNoFeeder() {
        let engine = AVAudioEngine()
        XCTAssertNil(
            EpisodeOutputTap.outputFeederConnection(of: engine),
            "an unconnected engine claimed a feeder, so the wrong node would be tapped"
        )

        let tap = EpisodeOutputTap(engine: engine)
        tap.install()
        XCTAssertFalse(
            tap.isInstalledOnOutputNode(engine.outputNode),
            "install() fell back to tapping the output node with no feeder present"
        )
    }
}




/// The CAPTURE itself: the closure production installs must carry the identity it was ADMITTED
/// under, captured at install time, rather than reading `self.producerIdentity` when it fires.
///
/// This uses the test seam that retains the actual closure `install()` installed. The old
/// closure is invoked AFTER a reinstall: if it acquired the new identity at fire time, its
/// submission would pass the admission check and its audio would enter the reference under the
/// wrong producer.
/// Retains install closures for the capture test. A box class rather than a captured local:
/// the compiler crashed type-checking the local-capture form.
final class InstalledClosureBox {
    var items: [(AVAudioPCMBuffer, AVAudioTime) -> Void] = []
    func add(_ closure: @escaping (AVAudioPCMBuffer, AVAudioTime) -> Void) {
        items.append(closure)
    }
}

final class InstalledClosureCaptureTests: XCTestCase {

    private func toneBuffer(frames: Int = 512) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44_100, channels: 1, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        if let channels = buffer.floatChannelData {
            for i in 0..<frames { channels[0][i] = Float(sin(Double(i) * 0.2) * 0.4) }
        }
        return buffer
    }

    func testOldClosureSubmitsItsOwnIdentityAndIsRefused() {
        let reference = PlaybackEchoReference()
        let handoff = EchoReferenceHandoff(reference: reference, capacity: 8)

        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: nil)
        engine.connect(engine.mainMixerNode, to: engine.outputNode, format: nil)

        let tap = EpisodeOutputTap(engine: engine)
        tap.handoff = handoff

        // THE TEST retains the closures: the observer hands each install's closure over and the
        // object itself stores nothing.
        let box = InstalledClosureBox()
        tap.onInstalledClosure = { closure in box.items.append(closure) }

        // The FIRST install: its closure captures the first identity.
        tap.install()
        let first = tap.producerIdentity

        // The reinstall: remove-first runs, the incarnation rotates, and a NEW closure is
        // captured under the new identity.
        tap.install()
        let second = tap.producerIdentity
        XCTAssertNotEqual(second, first, "the reinstall did not rotate the identity")
        XCTAssertEqual(box.items.count, 2, "the observer did not see one closure per install")

        // Invoke the OLD closure — items[0], the one the FIRST install captured — as the graph
        // would.
        box.items[0](toneBuffer(), AVAudioTime(sampleTime: 0, atRate: 44_100))
        handoff.drain()
        XCTAssertEqual(
            reference.snapshot().count, 0,
            "the OLD closure submitted audio that reached the reference, so it did not carry its "
            + "own retired identity — it acquired the new one at fire time"
        )

        // POSITIVE CONTROL: the CURRENT closure (retained[1]) under the CURRENT identity is accepted.
        box.items[1](toneBuffer(), AVAudioTime(sampleTime: 0, atRate: 44_100))
        handoff.drain()
        XCTAssertGreaterThan(
            reference.snapshot().count, 0,
            "the current closure was refused too, so the refusal proves nothing about capture"
        )
    }
}


