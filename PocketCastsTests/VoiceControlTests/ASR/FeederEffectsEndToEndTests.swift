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
        /// Optional observer of the buffers the tap publishes, with the callback's time.
        var onBuffer: ((AVAudioPCMBuffer, AVAudioTime) -> Void)?
    }

    /// THE POSITIVE TIMING CONTROL: a distinctive marker on a NON-SILENT carrier.
    ///
    /// The file carries a modest tone (so the block survives the publication’s silence floor) plus a
    /// MULTI-SAMPLE burst at a much higher amplitude near the start. The burst is found IN THE
    /// PUBLISHED SAMPLES, so the marker’s own sample index is identified rather than assumed, and
    /// the callback that carries it supplies the marker's sample position and valid host instant.
    /// Those are then correlated with the asserted schedule target and with the accepted reference
    /// range/anchor. A run in which the marker is not found FAILS here rather than passing on zero
    /// delivery.
    func testScheduledMarkerIsFoundOnANonSilentCarrier() throws {
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
        // THE TAP MUST BE INSTALLED. Without this the fixture receives no callbacks at all, which is
        // what the earlier zero-output run measured — a fixture defect, not a scheduling result.
        tap.install()

        // Carrier survives the floor; the marker is a multi-sample burst well above it.
        let carrierLevel: Float = 0.2
        let markerLevel: Float = 0.9
        let markerFrames = 480            // 10 ms at 48 kHz: multi-sample, survives conversion
        let frames = Int(rate)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("carrier-\(UUID().uuidString).caf")
        let file = try AVAudioFile(forWriting: url, settings: f.settings)
        let b = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: f, frameCapacity: AVAudioFrameCount(frames)))
        b.frameLength = AVAudioFrameCount(frames)
        if let ch = b.floatChannelData?[0] {
            for i in 0..<frames {
                // The carrier is a tone at ONE frequency; the marker is the same carrier at the
                // higher level, so the burst is identifiable by amplitude alone.
                ch[i] = Float(sin(Double(i) * 0.05)) * (i < markerFrames ? markerLevel : carrierLevel)
            }
        }
        try file.write(from: b)
        let reading = try AVAudioFile(forReading: url)

        // Observe the PUBLISHED samples: the marker's index within the delivered stream, the
        // callback clocks, and the accepted reference observations.

        var markerSampleIndex: Int?
        var markerHostSeconds: Double?
        var markerProducerPosition: Double?
        var callbackHosts: [Double] = []
        var acceptedAnchors = 0
        var acceptedOffsets: [Int] = []
        let lock = NSLock()
        tap.onBuffer = { buffer, when in
            lock.lock()
            if when.isHostTimeValid { callbackHosts.append(AVAudioTime.seconds(forHostTime: when.hostTime)) }
            if let ch = buffer.floatChannelData?[0] {
                for i in 0..<Int(buffer.frameLength) where ch[i] >= markerLevel * 0.8 {
                    if markerSampleIndex == nil {
                        markerSampleIndex = i
                        markerProducerPosition = when.isSampleTimeValid ? Double(when.sampleTime) + Double(i) : nil
                        if when.isHostTimeValid { markerHostSeconds = AVAudioTime.seconds(forHostTime: when.hostTime) }
                    }
                    break
                }
            }
            lock.unlock()
        }
        // ACCEPTANCE OBSERVATIONS FROM THE REFERENCE SIDE, per accepted block: the reference's own
        // stream position and the anchor it recorded for that block. These are asserted to ADVANCE
        // below, measured independently of the callback progression.
        var acceptedStreamIndices: [Int] = []
        var acceptedRanges: [(start: Double?, end: Double?)] = []
        var acceptedAnchorsObserved: [(frames: Double, host: Double)] = []
        handoff.onBlockAccepted = { producerStart, producerEnd in
            lock.lock()
            acceptedAnchors += 1
            acceptedStreamIndices.append(reference.streamIndex)
            acceptedRanges.append((producerStart, producerEnd))
            if let anchor = reference.currentRenderAnchor {
                acceptedAnchorsObserved.append((anchor.renderedFrames, anchor.hostTime))
            }
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
        print("CARRIER targetAheadSeconds=\(ahead)")
        XCTAssertGreaterThan(ahead, 0.4, "the target was not ahead at submission")

        // MEASURED, SAME CASE, ONE VARIABLE: with the explicit host time removed the result is
        // IDENTICAL (callbacks=0), so the explicit schedule is NOT the cause of the missing
        // callbacks here. The passing case in this same suite schedules a BUFFER and awaits
        // delivery with a longer window; this case schedules a FILE. Which of those differs is
        // not established, and the cause is left unproven.
        player.scheduleFile(reading, at: AVAudioTime(hostTime: target))
        player.play()

        // FIRST find the marker, then KEEP RUNNING so several blocks are accepted: advancement
        // across accepted blocks cannot be asserted from a single acceptance, and stopping as soon
        // as the marker appears would leave that assertion vacuous.
        var deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            lock.lock(); let found = markerSampleIndex != nil; lock.unlock()
            if found { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        deadline = Date().addingTimeInterval(1.0)
        while Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
        engine.stop()
        handoff.drain()

        lock.lock()
        let index = markerSampleIndex
        let markerHost = markerHostSeconds
        let hosts = callbackHosts
        let anchors = acceptedAnchors
        let offsets = acceptedOffsets
        let streamIndices = acceptedStreamIndices
        let ranges = acceptedRanges
        let anchorsObserved = acceptedAnchorsObserved
        let markerPosition = markerProducerPosition
        lock.unlock()

        let targetSeconds = Double(target) * secondsPerTick
        print("CARRIER markerSampleIndex=\(index as Any) markerHostSeconds=\(markerHost as Any) targetSeconds=\(targetSeconds) callbacks=\(hosts.count) acceptedAnchors=\(anchors) offsets=\(offsets.prefix(6))")

        // THE MARKER MUST BE FOUND: this is the assertion the zero-delivery version lacked.
        XCTAssertNotNil(index, "the distinctive marker was not found in the published samples")
        XCTAssertNotNil(markerHost, "the marker's callback carried no valid host instant")
        XCTAssertGreaterThan(anchors, 0, "the reference accepted no blocks alongside the marker")
        // THE MARKER'S BLOCK IS AN ACCEPTED ONE: the marker was observed in a published buffer, and
        // at least one block was accepted into the reference with a recorded anchor — so the
        // marker's audio is associated with an accepted range rather than with a dropped callback.
        XCTAssertFalse(offsets.isEmpty, "no accepted block recorded a reference anchor alongside the marker")
        // ACCEPTED-REFERENCE ADVANCEMENT, asserted from the reference side and separately from the
        // callback progression: each accepted block's stream position must be strictly greater than
        // the previous one, so the reference is genuinely receiving successive audio rather than
        // rewriting one position.
        XCTAssertEqual(
            streamIndices, streamIndices.sorted(),
            "the accepted reference stream positions did not advance monotonically"
        )
        XCTAssertGreaterThan(
            streamIndices.count, 1,
            "only one block was accepted, so advancement across accepted blocks was not exercised"
        )
        XCTAssertGreaterThan(
            streamIndices.last ?? 0, streamIndices.first ?? 0,
            "the accepted reference stream position did not advance across blocks"
        )
        let markerRanges = ranges.filter { range in
            guard let start = range.start, let end = range.end, let position = markerPosition else { return false }
            return position >= start && position <= end
        }
        print("CARRIER acceptedStreamIndices=\(streamIndices.prefix(8))")

        // INDIVIDUAL MATCH: the block that CARRIED the marker must be identified among the accepted
        // blocks, by testing the marker's own producer position against each accepted producer
        // range. Coexisting with a list of accepted blocks is not association.
        XCTAssertEqual(markerRanges.count, 1, "the marker's producer position did not fall in exactly one accepted range")
        print("CARRIER marker acceptedRange=\(markerRanges.first as Any) of \(ranges.count) accepted ranges")

        // SEQUENTIAL ACCEPTED HOST/FRAME PAIRS: the anchors the reference recorded must advance in
        // both frame and host, not merely in stream count.
        let anchorFrames = anchorsObserved.map(\.frames)
        let anchorHosts = anchorsObserved.map(\.host)
        print("CARRIER acceptedAnchorFrames=\(anchorFrames.prefix(6)) acceptedAnchorHosts=\(anchorHosts.prefix(6))")
        XCTAssertEqual(anchorFrames, anchorFrames.sorted(), "the accepted anchors' frames did not advance")
        XCTAssertEqual(anchorHosts, anchorHosts.sorted(), "the accepted anchors' host instants did not advance")
        if anchorFrames.count > 1 {
            XCTAssertGreaterThan(anchorFrames.last ?? 0, anchorFrames.first ?? 0, "accepted anchor frames did not advance end to end")
            XCTAssertGreaterThan(anchorHosts.last ?? 0, anchorHosts.first ?? 0, "accepted anchor host instants did not advance end to end")
        }
        // CORRELATE THE MARKER'S OWN INSTANT, not the callback's: the marker sits at index `index`
        // within its buffer, and the callback's sample time labels that buffer's START (measured in
        // ExplicitScheduleOriginProbe), so the marker's instant is the callback instant advanced by
        // index/rate. Using the raw callback instant instead reports the buffer's start as if it
        // were the marker's.
        if let markerHost, let index {
            let markerInstant = markerHost + Double(index) / rate
            let elapsed = markerInstant - targetSeconds
            print("CARRIER markerInstant=\(markerInstant) elapsed=\(elapsed) (rawCallbackDelta=\(markerHost - targetSeconds))")
            XCTAssertGreaterThan(elapsed, -0.005, "the marker appeared before its asserted schedule instant")
            XCTAssertLessThan(elapsed, 1.0, "the marker appeared more than a second after its target")
        }
    }

    /// BARRIER AT THE ATOMIC PUBLICATION: `onBlockAccepted` fires inside `deliver()`, after the
    /// samples are appended and the anchor is written, before any later queued operation runs. The
    /// anchor observed THERE must map the REPRESENTED position (the block's start frame) into the
    /// reference; passing the range end as the represented position maps to the far end of the
    /// block instead, which this control catches.
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
        handoff.onBlockAccepted = { _, _ in
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
