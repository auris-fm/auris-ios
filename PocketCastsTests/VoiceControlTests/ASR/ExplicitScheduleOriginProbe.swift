import AVFoundation
import XCTest

/// EXPLICIT-SCHEDULE ORIGIN EXPERIMENT (corrected setup).
///
/// A file whose FIRST sample is a marker is scheduled at an explicit HOST time, so the marker's
/// render instant is stated by the schedule itself. The setup is established first (asserted
/// target-ahead at submission, an audible control, synchronized polling, cleanup before start);
/// only then are the two interpretations compared:
///   START: the callback's buffer begins at its sampleTime, so the marker sits at (T + j)/rate
///          after the buffer start → its host instant is hostTime-derived from the same event.
///   END:   the callback's buffer ends at its sampleTime, so the buffer start is T - N and the
///          marker sits at (T - N + j) → the marker's host instant is one buffer later in the
///          START reading than in the END reading, a difference of N/rate seconds.
/// The comparison is between the marker's expected host instant (from the schedule) and the
/// callback's own hostTime adjusted by the marker's index under each reading.
final class ExplicitScheduleOriginProbe: XCTestCase {

    func testExplicitScheduleMarkerDiscriminates() throws {
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: nil)
        engine.connect(engine.mainMixerNode, to: engine.outputNode, format: nil)

        let rate = 48_000.0
        let totalFrames = 48_000
        let markerIndex = 0

        func writeMarkerFile(name: String, withMarker: Bool) throws -> AVAudioFile {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString).caf")
            let fmt = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
            let file = try AVAudioFile(forWriting: url, settings: fmt.settings)
            let b = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(totalFrames)))
            b.frameLength = AVAudioFrameCount(totalFrames)
            if let ch = b.floatChannelData {
                for c in 0..<2 {
                    for i in 0..<totalFrames {
                        ch[c][i] = (withMarker && i == markerIndex) ? 1.0 : Float(sin(Double(i) * 0.05) * 0.15)
                    }
                }
            }
            try file.write(from: b)
            return try AVAudioFile(forReading: url)
        }
        let markerFile = try writeMarkerFile(name: "marker", withMarker: true)
        let controlFile = try writeMarkerFile(name: "control", withMarker: false)

        var hits: [(sampleTime: Double, frames: Int, j: Int?, hostTime: UInt64, hostValid: Bool, peak: Float, rate: Double)] = []
        let lock = NSLock()
        engine.mainMixerNode.installTap(onBus: 0, bufferSize: 4_096, format: nil) { buffer, when in
            var j: Int? = nil
            var peak: Float = 0
            if let ch = buffer.floatChannelData?[0] {
                for i in 0..<Int(buffer.frameLength) where abs(ch[i]) > peak { peak = abs(ch[i]); j = i }
                if peak < 0.45 { j = nil }
            }
            lock.lock()
            hits.append((
                sampleTime: when.isSampleTimeValid ? Double(when.sampleTime) : Double.nan,
                frames: Int(buffer.frameLength),
                j: j,
                hostTime: when.isHostTimeValid ? when.hostTime : 0,
                hostValid: when.isHostTimeValid,
                peak: peak,
                rate: buffer.format.sampleRate
            ))
            lock.unlock()
        }

        var ti = mach_timebase_info_data_t(); mach_timebase_info(&ti)
        let secondsPerTick = Double(ti.numer) / Double(ti.denom) / 1_000_000_000.0
        let ticksPerSecond = 1.0 / secondsPerTick

        // CLEANUP BEFORE START.
        defer { engine.stop() }
        engine.prepare()
        try engine.start()

        // The CONTROL first: proves the setup renders audio, and its silence would invalidate the run.
        player.scheduleFile(controlFile, at: nil)
        player.play()
        var deadline = Date().addingTimeInterval(3)
        var controlPeak: Float = 0
        while Date() < deadline {
            lock.lock(); controlPeak = max(controlPeak, hits.map(\.peak).max() ?? 0); lock.unlock()
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        print("PROBE controlPeak=\(controlPeak)")

        // TARGET COMPUTED AND ASSERTED IMMEDIATELY AT SUBMISSION.
        let nowHost = mach_absolute_time()
        let target = nowHost + UInt64(0.5 * ticksPerSecond)
        let aheadSeconds = Double(target - mach_absolute_time()) * secondsPerTick
        print("PROBE targetAheadSeconds=\(aheadSeconds)")
        XCTAssertGreaterThan(aheadSeconds, 0.4, "the schedule target was not ahead at submission")

        lock.lock(); hits.removeAll(); lock.unlock()
        player.scheduleFile(markerFile, at: AVAudioTime(hostTime: target))
        let targetSeconds = Double(target) * secondsPerTick

        // SYNCHRONIZED POLL for the marker.
        deadline = Date().addingTimeInterval(8)
        var marker: (sampleTime: Double, frames: Int, j: Int, hostSeconds: Double, rate: Double)? = nil
        while Date() < deadline {
            lock.lock()
            for h in hits where h.j != nil && h.hostValid {
                marker = (h.sampleTime, h.frames, h.j!, Double(h.hostTime) * secondsPerTick, h.rate)
                break
            }
            lock.unlock()
            if marker != nil { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        player.stop()
        engine.mainMixerNode.removeTap(onBus: 0)

        let m = try XCTUnwrap(marker, "the marker was never observed; the setup did not render it")
        print("PROBE marker T=\(m.sampleTime) N=\(m.frames) j=\(m.j) callbackHostSeconds=\(m.hostSeconds) targetSeconds=\(targetSeconds)")
        // Both readings expressed as the marker's own elapsed time from the schedule target.
        // HOST-DOMAIN COMPARISON, no node-frame origin invented. The marker sits at SOURCE-FILE
        // offset 0 (asserted below), so its expected host instant is the asserted schedule target.
        // Callback host instant H, marker index j, buffer length N, callback rate R:
        //   START predicts the marker at H + j/R   (the buffer begins at H)
        //   END   predicts the marker at H + (j-N)/R (the buffer ends at H)
        XCTAssertEqual(markerIndex, 0, "the marker must be at source offset 0 for this expected instant")
        // R FROM THE CALLBACK BUFFER FORMAT, not the file rate: the comparison is only exact if R is
        // the rate the reported sample times are counted in.
        let callbackRate = m.rate
        XCTAssertGreaterThan(callbackRate, 0, "the callback reported no rate")
        XCTAssertEqual(callbackRate, rate, "the callback rate differs from the file rate; the predictions must be expressed at the callback rate")
        print("PROBE markerSourceOffsetFrames=\(markerIndex) callbackRate=\(callbackRate) fileRate=\(rate)")
        let startPrediction = m.hostSeconds + Double(m.j) / callbackRate
        let endPrediction = m.hostSeconds + (Double(m.j) - Double(m.frames)) / callbackRate
        let startError = startPrediction - targetSeconds
        let endError = endPrediction - targetSeconds
        print("PROBE expectedMarkerInstant=\(targetSeconds)")
        print("PROBE START prediction=\(startPrediction) error=\(startError)")
        print("PROBE END   prediction=\(endPrediction) error=\(endError)")
        print("PROBE ONE_BUFFER=\(Double(m.frames) / callbackRate) (the gap between the predictions)")

        // THE DISCRIMINATION, asserted. EXPECTED_PLACEMENT: sampleTime labels the buffer's START.
        // The START error must be within a small tolerance of the asserted schedule instant while
        // the END error is a full buffer away — a gap far outside any jitter seen here.
        XCTAssertLessThan(
            abs(startError), 0.005,
            "the marker did not land at the schedule instant under START semantics (error \(startError))"
        )
        XCTAssertGreaterThan(
            abs(endError), 0.05,
            "END semantics was not excluded: its error (\(endError)) is within half a buffer"
        )
        // The CONTROL file carries NO marker, so its peak is the tone (~0.15), not a marker peak.
        XCTAssertGreaterThan(controlPeak, 0.05, "the control was silent: the setup cannot render audio")
    }
}
