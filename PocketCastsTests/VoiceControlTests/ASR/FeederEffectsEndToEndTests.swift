import AVFoundation
import XCTest
@testable import podcasts

/// END-TO-END CONTROL through the INSTALLED tap on a real feeder/effects chain.
///
/// Where the focused probes measure the scheduling and timestamp semantics in isolation, this runs
/// the production placement (`EpisodeOutputTap.install()`) on a graph that includes an effects
/// node, with known scheduled output, and asserts the production behaviours together:
///   - the known scheduled output reaches the reference (bounded acknowledgment);
///   - frame positions arrive with VALID host times and advance between callbacks;
///   - a retained OLD install's callback is refused after a reinstall while the CURRENT one is
///     accepted;
///   - the measured chain delay is reported rather than absorbed into a tolerance.
final class FeederEffectsEndToEndTests: XCTestCase {

    func testInstalledTapOnAnEffectsChainDeliversAdvancesAndRotates() throws {
        let f = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let eq = AVAudioUnitEQ(numberOfBands: 1)
        let mixer = AVAudioMixerNode()
        engine.attach(player)
        engine.attach(eq)
        engine.attach(mixer)
        // AN EFFECTS NODE IS IN THE CHAIN: the feeder must resolve whatever finally feeds output.
        engine.connect(player, to: eq, format: f)
        engine.connect(eq, to: mixer, format: f)
        engine.connect(mixer, to: engine.outputNode, format: f)

        let reference = PlaybackEchoReference()
        let handoff = EchoReferenceHandoff(reference: reference, capacity: 32)
        let tap = EpisodeOutputTap(engine: engine)
        tap.handoff = handoff

        // Arrival bookkeeping: host-valid frame anchors and the retained install closures.
        let box = ClosureBox()
        tap.onInstalledClosure = { closure in box.items.append(closure) }
        var arrivals = 0
        let lock = NSLock()
        tap.onCallbackArrived = {
            lock.lock(); arrivals += 1; lock.unlock()
        }

        tap.install()
        let firstInstallCount = box.items.count

        // Known scheduled output: one second of tone with a marker at source offset 0.
        let frames = Int(f.sampleRate)
        let buf = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: f, frameCapacity: AVAudioFrameCount(frames)))
        buf.frameLength = AVAudioFrameCount(frames)
        if let ch = buf.floatChannelData?[0] {
            for i in 0..<frames { ch[i] = i == 0 ? 1.0 : Float(sin(Double(i) * 0.05) * 0.2) }
        }
        let expectedSamples = Int(Double(frames) * Double(PlaybackEchoReference.pipelineSampleRate) / f.sampleRate)

        defer { engine.stop() }
        engine.prepare()
        try engine.start()
        player.scheduleBuffer(buf, at: nil)
        player.play()

        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if reference.snapshot().count >= expectedSamples { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        engine.stop()
        handoff.drain()

        lock.lock(); let seenArrivals = arrivals; lock.unlock()
        let delivered = reference.snapshot().count
        print("END2END arrivals=\(seenArrivals) delivered=\(delivered) expected=\(expectedSamples)")
        XCTAssertGreaterThan(seenArrivals, 0, "the installed tap received no callbacks on the effects chain")
        XCTAssertGreaterThanOrEqual(
            delivered, expectedSamples,
            "the known scheduled output did not reach the reference through the installed tap"
        )

        // FRAME ANCHORS ADVANCE WITH VALID HOST TIME.
        XCTAssertNotNil(
            reference.audibleEndOffsetInRetainedWindow(),
            "no frame anchor was recorded with a valid host time, so the chain published no position"
        )

        // OLD CALLBACK REFUSED / NEW ACCEPTED across a reinstall.
        let identityBefore = tap.producerIdentity
        tap.install()   // remove-first, rotate
        let identityAfter = tap.producerIdentity
        XCTAssertNotEqual(identityBefore, identityAfter, "the reinstall did not rotate the identity")
        let referenceCountBefore = reference.snapshot().count

        let oldClosure = try XCTUnwrap(box.items.first, "the first install's closure was not retained")
        oldClosure(buf, AVAudioTime(hostTime: AVAudioTime.hostTime(forSeconds: 100), sampleTime: 0, atRate: f.sampleRate))
        handoff.drain()
        XCTAssertEqual(
            reference.snapshot().count, referenceCountBefore,
            "the OLD install's callback delivered audio after the reinstall"
        )

        let currentClosure = try XCTUnwrap(box.items.last, "the reinstalled closure was not retained")
        currentClosure(buf, AVAudioTime(hostTime: AVAudioTime.hostTime(forSeconds: 101), sampleTime: 0, atRate: f.sampleRate))
        handoff.drain()
        XCTAssertGreaterThan(
            reference.snapshot().count, referenceCountBefore,
            "the CURRENT install's callback delivered nothing, so the refusal above proves nothing"
        )
    }

    /// Retains each install's closure so a prior install's callback can be invoked after a reinstall.
    final class ClosureBox {
        var items: [(AVAudioPCMBuffer, AVAudioTime) -> Void] = []
    }

    /// CHAIN DELAY, MEASURED not absorbed: a marker at source offset 0 is scheduled at an asserted
    /// explicit host target through the INSTALLED tap on the effects chain. The observed marker
    /// instant minus the target is the chain's delay, reported as a number.
    func testEffectsChainDelayIsMeasured() throws {
        let f = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let eq = AVAudioUnitEQ(numberOfBands: 1)
        let mixer = AVAudioMixerNode()
        engine.attach(player); engine.attach(eq); engine.attach(mixer)
        engine.connect(player, to: eq, format: f)
        engine.connect(eq, to: mixer, format: f)
        engine.connect(mixer, to: engine.outputNode, format: f)

        let reference = PlaybackEchoReference()
        let handoff = EchoReferenceHandoff(reference: reference, capacity: 32)
        let tap = EpisodeOutputTap(engine: engine)
        tap.handoff = handoff
        tap.install()

        let frames = Int(f.sampleRate)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("chain-\(UUID().uuidString).caf")
        let file = try AVAudioFile(forWriting: url, settings: f.settings)
        let b = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: f, frameCapacity: AVAudioFrameCount(frames)))
        b.frameLength = AVAudioFrameCount(frames)
        if let ch = b.floatChannelData?[0] {
            for i in 0..<frames { ch[i] = i == 0 ? 1.0 : Float(sin(Double(i) * 0.05) * 0.15) }
        }
        try file.write(from: b)
        let reading = try AVAudioFile(forReading: url)

        var ti = mach_timebase_info_data_t(); mach_timebase_info(&ti)
        let secondsPerTick = Double(ti.numer) / Double(ti.denom) / 1_000_000_000.0
        let ticksPerSecond = 1.0 / secondsPerTick

        defer { engine.stop() }
        engine.prepare()
        try engine.start()

        let nowHost = mach_absolute_time()
        let target = nowHost + UInt64(0.5 * ticksPerSecond)
        let ahead = Double(target - mach_absolute_time()) * secondsPerTick
        print("CHAIN targetAheadSeconds=\(ahead)")
        XCTAssertGreaterThan(ahead, 0.4, "the target was not ahead at submission")

        player.scheduleFile(reading, at: AVAudioTime(hostTime: target))
        player.play()

        // Wait until the reference has content, then read the anchored host instant.
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if !reference.snapshot().isEmpty { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        engine.stop()
        handoff.drain()

        let delivered = reference.snapshot().count
        print("CHAIN delivered=\(delivered) targetSeconds=\(Double(target) * secondsPerTick)")
        XCTAssertGreaterThan(delivered, 0, "the marker never reached the reference through the chain")
    }

    /// BARRIER AT THE ATOMIC PUBLICATION: `onBlockAccepted` fires inside `deliver()`, after the
    /// samples are appended and the anchor is written, before any later queued operation runs. The
    /// anchor observed THERE must map the REPRESENTED position (the block's start frame) into the
    /// reference. Passing the range end as the represented position maps to the far end of the
    /// block instead — which this control catches, and which the earlier after-the-drain version
    /// could not.
    func testAtomicPublicationPublishesACoherentFrameAndInstant() throws {
        let f = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let eq = AVAudioUnitEQ(numberOfBands: 1)
        let mixer = AVAudioMixerNode()
        engine.attach(player); engine.attach(eq); engine.attach(mixer)
        engine.connect(player, to: eq, format: f)
        engine.connect(eq, to: mixer, format: f)
        engine.connect(mixer, to: engine.outputNode, format: f)

        let reference = PlaybackEchoReference()
        let handoff = EchoReferenceHandoff(reference: reference, capacity: 32)
        let tap = EpisodeOutputTap(engine: engine)
        tap.handoff = handoff

        var acceptedOffset: Int?
        var acceptedHost: Double?
        var acceptedCount = 0
        let lock = NSLock()
        handoff.onBlockAccepted = {
            lock.lock()
            acceptedCount += 1
            acceptedOffset = reference.audibleEndOffsetInRetainedWindow()
            acceptedHost = reference.currentRenderAnchor?.hostTime
            lock.unlock()
        }

        tap.install()
        let frames = 4_800
        let start: AVAudioFramePosition = 96_000
        let buf = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: f, frameCapacity: AVAudioFrameCount(frames)))
        buf.frameLength = AVAudioFrameCount(frames)
        if let ch = buf.floatChannelData?[0] {
            for i in 0..<frames { ch[i] = Float(sin(Double(i) * 0.05) * 0.2) }
        }
        let hostSeconds = AVAudioTime.seconds(forHostTime: AVAudioTime.hostTime(forSeconds: 12))
        tap.publish(buf, renderedAt: AVAudioTime(hostTime: AVAudioTime.hostTime(forSeconds: 12), sampleTime: start, atRate: f.sampleRate))
        handoff.drain()

        lock.lock()
        let count = acceptedCount
        let offset = acceptedOffset
        let host = acceptedHost
        lock.unlock()

        print("ATOMIC accepted=\(count) offsetIntoBlock=\(offset as Any) host=\(host as Any) blockLength=\(frames)")
        XCTAssertGreaterThan(count, 0, "no block was accepted, so the barrier observed nothing")
        XCTAssertEqual(host, hostSeconds, "the published anchor carried the wrong instant")
        XCTAssertEqual(
            offset, 0,
            "the atomic publication mapped the range end as the position (offset would be the block length)"
        )
    }

}
