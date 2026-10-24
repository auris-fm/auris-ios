import AVFoundation
import XCTest

/// VERIFIED SAMPLE-TIME ORIGIN EXPERIMENT.
///
/// The player renders control file A (pure tone, L_A frames) scheduled at nil, then impulse file B
/// (frame 0 = impulse) scheduled at `AVAudioTime(sampleTime: L_A, atRate: R)` in the PLAYER's own
/// domain. B's frame 0 therefore corresponds to player sample L_A — an origin that is explicit and
/// verifiable (A's audible length defines it).
///
/// The tap on the PLAYER node reports each callback's sampleTime T, frames N, and the impulse's
/// sub-index j. The two hypotheses predict B's origin differently:
///   END   predicts origin = T - N + j
///   START predicts origin = T + j
/// Comparing each against the scheduled L_A is the discrimination, all in one recorded domain.
final class SampleTimeOriginProbe: XCTestCase {

    func testSampleTimeScheduledOriginDiscriminatesSemantics() throws {
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: nil)
        engine.connect(engine.mainMixerNode, to: engine.outputNode, format: nil)

        let rate = 48_000.0
        let controlFrames = 48_000   // 1 s of tone
        let impulseFrames = 48_000   // 1 s with the impulse at frame 0

        func writeFile(name: String, impulseAtZero: Bool) throws -> AVAudioFile {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString).caf")
            let fmt = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
            let file = try AVAudioFile(forWriting: url, settings: fmt.settings)
            let b = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(impulseFrames)))
            b.frameLength = AVAudioFrameCount(controlFrames)
            if let ch = b.floatChannelData {
                for c in 0..<2 {
                    for i in 0..<controlFrames {
                        ch[c][i] = (impulseAtZero && i == 0) ? 1.0 : Float(sin(Double(i) * 0.05) * 0.15)
                    }
                }
            }
            try file.write(from: b)
            return try AVAudioFile(forReading: url)
        }
        let controlFile = try writeFile(name: "control", impulseAtZero: false)
        let impulseFile = try writeFile(name: "impulse", impulseAtZero: true)

        var hits: [(sampleTime: Double, frames: Int, j: Int?, hostValid: Bool)] = []
        let lock = NSLock()
        // Tap the PLAYER node: its sample time is the schedule domain the origin is stated in.
        player.installTap(onBus: 0, bufferSize: 4_096, format: nil) { buffer, when in
            var j: Int? = nil
            if let ch = buffer.floatChannelData?[0] {
                var best: Float = 0
                for i in 0..<Int(buffer.frameLength) where abs(ch[i]) > best { best = abs(ch[i]); j = i }
                if best < 0.45 { j = nil }
            }
            lock.lock()
            hits.append((
                sampleTime: when.isSampleTimeValid ? Double(when.sampleTime) : Double.nan,
                frames: Int(buffer.frameLength),
                j: j,
                hostValid: when.isHostTimeValid
            ))
            lock.unlock()
        }

        try engine.start()
        player.scheduleFile(controlFile, at: nil)
        // THE SCHEDULED ORIGIN: impulse frame 0 at player sample L_A.
        player.scheduleFile(impulseFile, at: AVAudioTime(sampleTime: AVAudioFramePosition(controlFrames), atRate: rate))
        player.play()

        var deadline = Date().addingTimeInterval(12)
        var seenImpulse = false
        while Date() < deadline && !seenImpulse {
            lock.lock(); seenImpulse = hits.contains { $0.j != nil }; lock.unlock()
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        deadline = Date().addingTimeInterval(1)
        while Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        player.stop()
        player.removeTap(onBus: 0)
        engine.stop()

        lock.lock()
        let captured = hits
        lock.unlock()

        print("PROBE scheduledOrigin=\(controlFrames) rate=\(rate) captured=\(captured.count)")
        for (index, h) in captured.enumerated() {
            let delta = index > 0 ? h.sampleTime - captured[index - 1].sampleTime : 0
            print("PROBE series[\(index)] T=\(h.sampleTime) N=\(h.frames) delta=\(delta) j=\(h.j as Any) hostValid=\(h.hostValid)")
            if let j = h.j {
                let endPrediction = h.sampleTime - Double(h.frames) + Double(j)
                let startPrediction = h.sampleTime + Double(j)
                print("PROBE   scheduledOrigin=\(controlFrames)  END predicts \(endPrediction)  START predicts \(startPrediction)")
                print("PROBE   endMatchesScheduled=\(endPrediction == Double(controlFrames)) startMatchesScheduled=\(startPrediction == Double(controlFrames))")
            }
        }
        XCTAssertFalse(captured.isEmpty, "no callbacks captured")
        XCTAssertTrue(seenImpulse, "the impulse was never observed; the origin cannot be read")
    }
}
