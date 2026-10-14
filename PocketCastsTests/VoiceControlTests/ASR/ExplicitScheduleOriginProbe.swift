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
        // Build the tone at the node's rendering rate to keep the domain single; the graph is
        // connected in THAT mono format so the player accepts the buffer.
        let rate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        let mono = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
        engine.connect(player, to: engine.mainMixerNode, format: mono)
        engine.connect(engine.mainMixerNode, to: engine.outputNode, format: mono)
        let frames = AVAudioFrameCount(rate) // one second
        let buf = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: frames))
        buf.frameLength = frames
        if let ch = buf.floatChannelData?[0] {
            for i in 0..<Int(frames) { ch[i] = i == 0 ? 1.0 : Float(sin(Double(i) * 0.05) * 0.15) }
        }

        var hits: [(sampleTime: Double, frames: Int, j: Int?, hostTime: UInt64, peak: Float)] = []
        let lock = NSLock()
        engine.mainMixerNode.installTap(onBus: 0, bufferSize: 4_096, format: nil) { buffer, when in
            var j: Int? = nil
            // The resampler can smear the impulse; take the loudest sample instead of a threshold.
            if let ch = buffer.floatChannelData?[0] {
                var best: Float = 0
                for i in 0..<Int(buffer.frameLength) where abs(ch[i]) > best { best = abs(ch[i]); j = i }
                if best < 0.6 { j = nil }
            }
            lock.lock()
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
        player.scheduleBuffer(buf, at: AVAudioTime(hostTime: target), options: [])
        player.play()

        var deadline = Date().addingTimeInterval(10)
        while hits.isEmpty && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
        deadline = Date().addingTimeInterval(2)
        while Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
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
        XCTAssertTrue(found, "the frame-0 impulse was not observed; semantics cannot be read")
    }
}
