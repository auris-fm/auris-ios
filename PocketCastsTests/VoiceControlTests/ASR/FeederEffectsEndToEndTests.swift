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

        // ONE IDENTITY-LINKED RECORD PER ACCEPTANCE. Each record carries the accepted block's
        // IDENTITY (so callbacks and acceptances link by identity rather than by matching a range to
        // a count), the range that identity covers, the OBSERVED BUFFER RATE, and the anchor the
        // reference recorded for it.
        struct AcceptedRecord {
            let identity: EchoReferenceHandoff.ProducerIdentity
            let blockKey: Int?
            let producerStart: Double?
            let producerEnd: Double?
            let rate: Double
            let anchorFrames: Double
            let anchorHost: Double
            let streamIndex: Int
        }
        var records: [AcceptedRecord] = []
        // The callback side: each published buffer with its identity-carried rate and clocks, so the
        // marker's record can be linked to an acceptance by identity.
        struct CallbackRecord {
            let blockKey: Int
            let rate: Double
            let sampleTime: Double?
            let hostSeconds: Double?
            let markerIndex: Int?
        }
        var callbackRecords: [CallbackRecord] = []
        var observedBufferRate: Double?
        let lock = NSLock()
        tap.onBuffer = { buffer, when, key in
            var index: Int? = nil
            if let ch = buffer.floatChannelData?[0] {
                for i in 0..<Int(buffer.frameLength) where ch[i] >= markerLevel * 0.8 { index = i; break }
            }
            lock.lock()
            if observedBufferRate == nil { observedBufferRate = buffer.format.sampleRate }
            callbackRecords.append(CallbackRecord(
                blockKey: key,
                rate: buffer.format.sampleRate,
                sampleTime: when.isSampleTimeValid ? Double(when.sampleTime) : nil,
                hostSeconds: when.isHostTimeValid ? AVAudioTime.seconds(forHostTime: when.hostTime) : nil,
                markerIndex: index
            ))
            lock.unlock()
        }
        handoff.onBlockAccepted = { producer, blockKey, producerStart, producerEnd, rate in
            lock.lock()
            records.append(AcceptedRecord(
                identity: producer,
                blockKey: blockKey,
                producerStart: producerStart,
                producerEnd: producerEnd,
                rate: rate,
                anchorFrames: reference.currentRenderAnchor?.renderedFrames ?? .nan,
                anchorHost: reference.currentRenderAnchor?.hostTime ?? .nan,
                streamIndex: reference.streamIndex
            ))
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

        player.scheduleFile(reading, at: AVAudioTime(hostTime: target))
        player.play()

        // Run until at least two complete accepted records exist, so adjacency is genuinely
        // exercised rather than conditionally skipped.
        var deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            lock.lock(); let count = records.count; lock.unlock()
            if count >= 2 { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        engine.stop()
        handoff.drain()

        lock.lock()
        let accepted = records
        let callbacks = callbackRecords
        let bufferRate = observedBufferRate
        lock.unlock()

        let targetSeconds = Double(target) * secondsPerTick
        print("CARRIER targetSeconds=\(targetSeconds) callbacks=\(callbacks.count) acceptedRecords=\(accepted.count) bufferRate=\(bufferRate as Any)")

        // 1. THE OBSERVED BUFFER RATE is asserted (and is the rate the records carry).
        let observedRate = try XCTUnwrap(bufferRate, "no buffer rate was observed")
        XCTAssertEqual(observedRate, f.sampleRate, "the observed buffer rate is not the graph rate")

        // 2. AT LEAST TWO COMPLETE ACCEPTED RECORDS: every field present, so neither adjacency nor
        //    the marker link can be satisfied by a single or partial record.
        XCTAssertGreaterThanOrEqual(accepted.count, 2, "fewer than two complete accepted records")
        for record in accepted {
            XCTAssertEqual(record.identity.kind, .episodeTap, "an accepted record carried the wrong producer kind")
            XCTAssertEqual(record.rate, observedRate, "an accepted record's rate is not the observed buffer rate")
            XCTAssertNotNil(record.producerStart, "an accepted record is missing its range start")
            XCTAssertNotNil(record.producerEnd, "an accepted record is missing its range end")
            XCTAssertFalse(record.anchorHost.isNaN, "an accepted record is missing its anchor host instant")
        }
        // 3. EVERY ADJACENT PAIR strictly advances, in frame and in host.
        for (previous, next) in zip(accepted, accepted.dropFirst()) {
            XCTAssertGreaterThan(next.anchorFrames, previous.anchorFrames, "adjacent accepted anchor frames did not strictly advance")
            XCTAssertGreaterThan(next.anchorHost, previous.anchorHost, "adjacent accepted anchor host instants did not strictly advance")
            XCTAssertGreaterThan(next.streamIndex, previous.streamIndex, "adjacent accepted stream indices did not strictly advance")
        }
        // 4. THE MARKER'S CALLBACK AND ITS ACCEPTANCE LINK BY IDENTITY: find the callback record that
        //    carried the marker, take its producer position, and require that EXACTLY ONE accepted
        //    record's HALF-OPEN range contains it, with that record's anchor host equal to the
        //    marker callback's own instant.
        let markerCallback = try XCTUnwrap(
            callbacks.first { $0.markerIndex != nil },
            "no callback record carried the marker"
        )
        let markerIndex = try XCTUnwrap(markerCallback.markerIndex, "marker index missing")
        let markerSampleTime = try XCTUnwrap(markerCallback.sampleTime, "marker callback had no sample time")
        let markerHost = try XCTUnwrap(markerCallback.hostSeconds, "marker callback had no host instant")
        let markerPosition = markerSampleTime + Double(markerIndex)
        // PRIMARY LINK: THE BLOCK KEY. The marker callback's own key must match exactly one
        // accepted record's key, which identifies the marker-bearing block without relying on a
        // producer identity (shared by many blocks) or on range arithmetic.
        let byKey = accepted.filter { $0.blockKey == markerCallback.blockKey }
        print("CARRIER markerBlockKey=\(markerCallback.blockKey) byKey=\(byKey.count) markerPosition=\(markerPosition) markerHost=\(markerHost)")
        XCTAssertEqual(byKey.count, 1, "the marker's block key did not match exactly one accepted record")
        let matched = try XCTUnwrap(byKey.first)
        // CORROBORATION: the marker's producer position also lies in that record's HALF-OPEN range,
        // so the key and the range agree rather than the key standing alone.
        let matchedStart = try XCTUnwrap(matched.producerStart, "the matched record has no range start")
        let matchedEnd = try XCTUnwrap(matched.producerEnd, "the matched record has no range end")
        XCTAssertTrue(
            markerPosition >= matchedStart && markerPosition < matchedEnd,
            "the marker's position is outside the half-open range of the record its key identifies"
        )
        XCTAssertEqual(
            matched.anchorHost, markerHost, accuracy: 0.001,
            "the matched acceptance's anchor host is not the marker callback's instant"
        )
        // 5. THE MARKER LANDS AT ITS ASSERTED SCHEDULE INSTANT once its own index is applied.
        let markerInstant = markerHost + Double(markerIndex) / observedRate
        let elapsed = markerInstant - targetSeconds
        let anchorSeconds = matched.anchorHost
        print("CARRIER markerInstant=\(markerInstant) elapsed=\(elapsed) matchedAnchorHostSeconds=\(anchorSeconds)")
        XCTAssertGreaterThan(elapsed, -0.005, "the marker appeared before its asserted schedule instant")
        XCTAssertLessThan(elapsed, 1.0, "the marker appeared more than a second after its target")
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
        handoff.onBlockAccepted = { _, _, _, _, _ in
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
