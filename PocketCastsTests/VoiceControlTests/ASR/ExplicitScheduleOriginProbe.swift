import AVFoundation
import XCTest

/// ORIGIN EXPERIMENT: schedule a buffer at an EXPLICIT host time. File frame 0 then corresponds
/// to a known instant on the host clock (the schedule time), independent of any node-clock
/// inference. The callback carrying frame 0 predicts its own hostTime under each hypothesis:
///   END   predicts seconds(hostTime) = H + (sampleTime - frames + j) / rate
///   START predicts seconds(hostTime) = H + (sampleTime + j) / rate
/// where j is the impulse's sub-index within the callback buffer and H the schedule time.
/// The rate is the node's own output rate so no conversion is involved.
final class ExplicitScheduleOriginProbe: XCTestCase {

    func testExplicitScheduleTimeDiscriminatesSemantics() throws {
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        // The KNOWN-WORKING graph configuration (format-nil connects, as in the probes that
        // observed content); the tone is built at the node's rendering rate to keep the domain
        // single.
        let rate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        // scheduleBuffer(at:) requires the buffer to match the player's output format, which the
        // nil connect infers from the mixer (stereo). The impulse is in BOTH channels.
        let stereo = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
        engine.connect(player, to: engine.mainMixerNode, format: nil)
        engine.connect(engine.mainMixerNode, to: engine.outputNode, format: nil)
        let frames = AVAudioFrameCount(rate) // one second
        // FILE-based scheduling: every probe that observed content used scheduleFile; write the
        // impulse (file frame 0) to CAF files.
        func writeImpulseFile(name: String) throws -> AVAudioFile {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("\\(name)-\\(UUID().uuidString).caf")
            let fmt = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
            let file = try AVAudioFile(forWriting: url, settings: fmt.settings)
            let b = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames))
            b.frameLength = frames
            if let ch = b.floatChannelData {
                for c in 0..<2 {
                    for i in 0..<Int(frames) { ch[c][i] = i == 0 ? 1.0 : Float(sin(Double(i) * 0.05) * 0.15) }
                }
            }
            try file.write(from: b)
            return try AVAudioFile(forReading: url)
        }
        let scheduledFile = try writeImpulseFile(name: "explicit")
        let controlFile = try writeImpulseFile(name: "control")

        var hits: [(sampleTime: Double, frames: Int, j: Int?, hostTime: UInt64, peak: Float)] = []
        var lastPeak: Float = 0
        let lock = NSLock()
        engine.mainMixerNode.installTap(onBus: 0, bufferSize: 4_096, format: nil) { buffer, when in
            var j: Int? = nil
            var hitsPeak: Float = 0
            // The resampler can smear the impulse; take the loudest sample instead of a threshold.
            if let ch = buffer.floatChannelData?[0] {
                for i in 0..<Int(buffer.frameLength) where abs(ch[i]) > hitsPeak { hitsPeak = abs(ch[i]); j = i }
                if hitsPeak < 0.45 { j = nil }
            }
            lock.lock()
            lastPeak = max(lastPeak, hitsPeak)
            hits.append((
                sampleTime: when.isSampleTimeValid ? Double(when.sampleTime) : Double.nan,
                frames: Int(buffer.frameLength),
                j: j,
                hostTime: when.isHostTimeValid ? when.hostTime : 0,
                peak: buffer.floatChannelData.map { ch -> Float in
                    var m: Float = 0
                    for i in 0..<Int(buffer.frameLength) { m = Swift.max(m, abs(ch[0][i])) }
                    return m
                } ?? 0
            ))
            lock.unlock()
        }

        try engine.start()
        let nowHost = mach_absolute_time()
        var ti = mach_timebase_info_data_t(); mach_timebase_info(&ti)
        let halfSecondTicks = UInt64(0.5 * 1_000_000_000.0 * Double(ti.numer) / Double(ti.denom))
        let target = nowHost + halfSecondTicks
        // CONTROL FIRST: if the player renders the nil-scheduled file, the player itself works
        // and any silence on the explicit-time item is that item's own failure.
        player.scheduleFile(controlFile, at: nil)
        player.play()
        // The working probes' ordering (schedule, then play), now with the explicit host time.

        var deadline = Date().addingTimeInterval(10)
        while hits.isEmpty && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
        // CONTROL WINDOW: the nil-scheduled file (1 s) must be audible now.
        deadline = Date().addingTimeInterval(3)
        var controlPeak: Float = 0
        while Date() < deadline {
            lock.lock(); controlPeak = max(controlPeak, lastPeak); lock.unlock()
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        print("PROBE controlPeak=\(controlPeak)")
        // THEN the explicit-time item. Reset the peak so this window is measured on its own.
        lock.lock(); lastPeak = 0; lock.unlock()
        player.scheduleFile(scheduledFile, at: AVAudioTime(hostTime: target))
        deadline = Date().addingTimeInterval(6)
        var explicitPeak: Float = 0
        while Date() < deadline {
            lock.lock(); explicitPeak = max(explicitPeak, lastPeak); lock.unlock()
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        print("PROBE explicitPeak=\(explicitPeak)")
        player.stop()
        engine.mainMixerNode.removeTap(onBus: 0)
        engine.stop()

        lock.lock()
        let captured = hits
        lock.unlock()

        print("PROBE captured=\(captured.count) scheduleTargetHost=\(target) rate=\(rate)")
        for (index, h) in captured.prefix(6).enumerated() {
            print("PROBE series[\(index)] sampleTime=\(h.sampleTime) frames=\(h.frames) peak=\(h.peak) j=\(h.j as Any)")
        }
        var found = false
        for (index, h) in captured.enumerated() where h.j != nil {
            found = true
            let j = h.j!
            let secondsPerTick = Double(ti.numer) / Double(ti.denom) / 1_000_000_000.0
            let hostSeconds = Double(h.hostTime) * secondsPerTick
            let endPrediction = 0.5 + (h.sampleTime - Double(h.frames) + Double(j)) / rate
            let startPrediction = 0.5 + (h.sampleTime + Double(j)) / rate
            print("PROBE callback[\(index)] sampleTime=\(h.sampleTime) frames=\(h.frames) j=\(j) hostSeconds=\(hostSeconds)")
            print("PROBE   END   prediction=\(endPrediction) delta=\(hostSeconds - endPrediction)")
            print("PROBE   START prediction=\(startPrediction) delta=\(hostSeconds - startPrediction)")
        }
        XCTAssertFalse(captured.isEmpty, "no callbacks captured")
        XCTAssertGreaterThan(controlPeak, 0.6, "the positive control was silent: the setup cannot render audio")
        print("PROBE VERDICT explicitPeak=\(explicitPeak) (audible ⇒ host-time scheduling fires on this runtime)")
        XCTAssertTrue(found, "the frame-0 impulse was not observed; semantics cannot be read")
    }
}
