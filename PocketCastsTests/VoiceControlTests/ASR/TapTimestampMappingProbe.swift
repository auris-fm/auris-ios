import AVFoundation
import XCTest

/// MEASUREMENT PROBE (not a contract control): what does the tap callback's `AVAudioTime`
/// actually carry on a live render?
///
/// Measured so far (real-time engine, feeder tap, this simulator):
///   - sampleTime is CUMULATIVE across callbacks and counted at the GRAPH rate (48000), not the
///     source file's rate.
///   - hostTime is valid and advances in lockstep with sampleTime (4800 frames = 2 400 000 host
///     ticks = 0.1 s).
///   - output-node taps deliver ZERO callbacks; the feeder tap is the one that fires.
/// This probe settles START-vs-END semantics with an impulse at a known file index.
final class TapTimestampMappingProbe: XCTestCase {

    func testProbeRecordsCallbackTimesAcrossARender() throws {
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: nil)
        engine.connect(engine.mainMixerNode, to: engine.outputNode, format: nil)

        let rate = 48_000.0
        let impulseIndex = 20_000
        let totalFrames = 120_000

        var hits: [(sampleTime: Double, frames: Int, hasImpulse: Bool)] = []
        let lock = NSLock()
        engine.mainMixerNode.installTap(onBus: 0, bufferSize: 4_096, format: nil) { buffer, when in
            var hasImpulse = false
            if let ch = buffer.floatChannelData?[0] {
                for i in 0..<Int(buffer.frameLength) where ch[i] > 0.5 { hasImpulse = true }
            }
            lock.lock()
            hits.append((
                sampleTime: when.isSampleTimeValid ? Double(when.sampleTime) : Double.nan,
                frames: Int(buffer.frameLength),
                hasImpulse: hasImpulse
            ))
            lock.unlock()
        }

        try engine.start()
        let audioFile = try self.impulseFile(frames: totalFrames, rate: rate, impulseIndex: impulseIndex)
        player.scheduleFile(audioFile, at: nil)
        player.play()

        var deadline = Date().addingTimeInterval(10)
        while hits.isEmpty && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        deadline = Date().addingTimeInterval(3)
        while Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        player.stop()
        engine.mainMixerNode.removeTap(onBus: 0)
        engine.stop()

        lock.lock()
        let captured = hits
        lock.unlock()

        print("PROBE captured=\(captured.count)")
        for (index, h) in captured.enumerated() where h.hasImpulse {
            print("PROBE impulse in callback[\(index)] sampleTime=\(h.sampleTime) frames=\(h.frames)")
            print("PROBE   impulseIndex=\(impulseIndex)")
            print("PROBE   END semantics predicts impulseIndex in [\(h.sampleTime - Double(h.frames)), \(h.sampleTime))")
            print("PROBE   START semantics predicts impulseIndex in [\(h.sampleTime), \(h.sampleTime + Double(h.frames)))")
            print("PROBE   endContains=\((Double(impulseIndex) >= h.sampleTime - Double(h.frames)) && (Double(impulseIndex) < h.sampleTime)) "
                + "startContains=\((Double(impulseIndex) >= h.sampleTime) && (Double(impulseIndex) < h.sampleTime + Double(h.frames)))")
        }
        XCTAssertFalse(captured.isEmpty, "the tap fired no callbacks, so there is nothing to map")
        XCTAssertTrue(
            captured.contains { $0.hasImpulse },
            "no callback carried the impulse at index \(impulseIndex), so semantics cannot be read"
        )
    }

    private func impulseFile(frames: Int, rate: Double, impulseIndex: Int) throws -> AVAudioFile {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("probe-\(UUID().uuidString).caf")
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buf.frameLength = AVAudioFrameCount(frames)
        if let ch = buf.floatChannelData?[0] {
            ch[impulseIndex] = 1.0
        }
        try file.write(from: buf)
        return try AVAudioFile(forReading: url)
    }
}
