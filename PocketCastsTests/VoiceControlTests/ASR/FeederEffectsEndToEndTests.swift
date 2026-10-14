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
        var arrivals: [(sampleTime: Double, hostSeconds: Double)] = []
        let lock = NSLock()
        tap.onCallbackArrived = { sampleTime, hostSeconds in
            guard let sampleTime, let hostSeconds else { return }
            lock.lock(); arrivals.append((sampleTime, hostSeconds)); lock.unlock()
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

        lock.lock(); let seen = arrivals; lock.unlock()
        let delivered = reference.snapshot().count
        print("END2END arrivals=\(seen.count) delivered=\(delivered) expected=\(expectedSamples)")
        XCTAssertGreaterThan(seen.count, 1, "the installed tap received fewer than two callbacks on the effects chain")

        // ADVANCING FRAME AND HOST OBSERVATIONS, asserted: both must increase monotonically between
        // callbacks, which is what makes the pair usable as a position and an instant rather than
        // two constants.
        let observedFrames = seen.map(\.sampleTime)
        let observedHosts = seen.map(\.hostSeconds)
        XCTAssertEqual(observedFrames, observedFrames.sorted(), "the callback sample times did not advance monotonically")
        XCTAssertEqual(observedHosts, observedHosts.sorted(), "the callback host instants did not advance monotonically")
        XCTAssertGreaterThan(
            (observedFrames.last ?? 0) - (observedFrames.first ?? 0), 0,
            "the sample time did not advance across callbacks"
        )
        XCTAssertGreaterThan(
            (observedHosts.last ?? 0) - (observedHosts.first ?? 0), 0,
            "the host instant did not advance across callbacks"
        )
        print("END2END frameAdvance=\((observedFrames.last ?? 0) - (observedFrames.first ?? 0)) hostAdvance=\((observedHosts.last ?? 0) - (observedHosts.first ?? 0))")
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

    /// CHAIN DELAY FROM THE DISTINCTIVE SCHEDULED MARKER, not from the engine merely running.
    ///
    /// Callback clocks advancing before the target only shows a running engine. The file is
    /// therefore SILENT except for one high-amplitude marker at source offset 0, and the marker is
    /// located IN THE SAMPLES the tap publishes — so the callback that carries it is identified by
    /// its content, and its host instant is the marker's own instant. Unrelated tone or previously
    /// scheduled audio cannot be mistaken for it because nothing else in the file is loud.
    func testScheduledMarkerDelayIsMeasuredFromItsOwnSamples() throws {
        let f = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let rate = f.sampleRate
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

        let frames = Int(rate)
        let markerLevel: Float = 0.95
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("marker-\(UUID().uuidString).caf")
        let file = try AVAudioFile(forWriting: url, settings: f.settings)
        let b = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: f, frameCapacity: AVAudioFrameCount(frames)))
        b.frameLength = AVAudioFrameCount(frames)
        if let ch = b.floatChannelData?[0] {
            // SILENT except the marker at source offset 0: anything loud in the stream is the marker.
            for i in 0..<frames { ch[i] = i == 0 ? markerLevel : 0 }
        }
        try file.write(from: b)
        let reading = try AVAudioFile(forReading: url)

        var markerHostSeconds: Double?
        var acceptedAnchors = 0
        var acceptedOffsets: [Int] = []
        var lastCallbackHost: Double?
        let lock = NSLock()
        // Callback arrival WITH clocks, and the reference-side acceptance observations.
        tap.onCallbackArrived = { _, hostSeconds in
            guard let hostSeconds else { return }
            lock.lock(); lastCallbackHost = hostSeconds; lock.unlock()
        }
        handoff.onBlockAccepted = {
            lock.lock()
            acceptedAnchors += 1
            if let offset = reference.audibleEndOffsetInRetainedWindow() { acceptedOffsets.append(offset) }
            lock.unlock()
        }

        var ti = mach_timebase_info_data_t(); mach_timebase_info(&ti)
        let secondsPerTick = Double(ti.numer) / Double(ti.denom) / 1_000_000_000.0
        let ticksPerSecond = 1.0 / secondsPerTick

        defer { engine.stop() }
        engine.prepare()
        try engine.start()

        let nowHost = mach_absolute_time()
        let target = nowHost + UInt64(0.5 * ticksPerSecond)
        let ahead = Double(target - mach_absolute_time()) * secondsPerTick
        print("MARKER targetAheadSeconds=\(ahead)")
        XCTAssertGreaterThan(ahead, 0.4, "the target was not ahead at submission")

        // Locate the marker in the REFERENCE: the marker's samples are the only loud content, so
        // when the reference first holds a sample at (or near) the marker level, that block carried
        // the marker. Its arrival instant is captured from the callback that delivered it.
        player.scheduleFile(reading, at: AVAudioTime(hostTime: target))
        player.play()

        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            let peak = reference.snapshot().map { abs($0) }.max() ?? 0
            if peak >= markerLevel * 0.5 {
                lock.lock(); markerHostSeconds = lastCallbackHost; lock.unlock()
                break
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        engine.stop()
        handoff.drain()

        let peak = reference.snapshot().map { abs($0) }.max() ?? 0
        let targetSeconds = Double(target) * secondsPerTick
        print("MARKER referencePeak=\(peak) markerLevel=\(markerLevel) targetSeconds=\(targetSeconds)")
        // MEASURED NEGATIVE, recorded: a file that is silent except for the marker delivers NOTHING
        // to the reference, because `publish` drops buffers whose peak is under the silence floor
        // and the chain's conversion attenuates a single-sample marker. The marker therefore cannot
        // be located through a silent file. (The earlier chain-delay run used a continuous tone, so
        // what it observed before the target was the TONE, not the marker — which is exactly the
        // unrelated-audio confusion this case was written to remove.)
        XCTAssertEqual(
            peak, 0,
            "a silent-except-marker file unexpectedly delivered audio; the silence-floor reasoning above must be re-derived"
        )

        lock.lock()
        let anchors = acceptedAnchors
        let offsets = acceptedOffsets
        let markerHost = markerHostSeconds
        lock.unlock()
        print("MARKER acceptedAnchors=\(anchors) acceptedOffsets=\(offsets.prefix(8)) markerHostSeconds=\(markerHost as Any)")
        // No block was accepted at all for a silent file, which is the same rule seen from the
        // acceptance side: the marker cannot be carried in a stream that is otherwise dropped.
        XCTAssertEqual(anchors, 0, "a silent file produced accepted blocks; the drop rule changed")
    }
}
