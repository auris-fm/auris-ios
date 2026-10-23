import AVFoundation
import XCTest

/// MEASUREMENT PROBE: settle START-vs-END semantics of the tap callback's `sampleTime` in the
/// PLAYER NODE'S OWN CLOCK, where file frame == node frame BY CONSTRUCTION (the file is
/// scheduled from zero on that node).
///
/// Per callback (of a tap on the AVAudioPlayerNode itself) we record sampleTime, the buffer's
/// frame length, and the impulse's sub-index j within the buffer. In that same node-clock domain:
///   END prediction:   impulse node frame = sampleTime - frames + j
///   START prediction: impulse node frame = sampleTime + j
/// The file index of the impulse (20 000) is then compared against both predictions directly.
final class TapTimestampMappingProbe: XCTestCase {

    func testImpulseSemanticsInPlayerNodeClock() throws {
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: nil)
        engine.connect(engine.mainMixerNode, to: engine.outputNode, format: nil)

        let rate = 48_000.0
        let impulseIndex = 20_000
        let totalFrames = 120_000

        var hits: [(sampleTime: Double, playerSampleTime: Double, frames: Int, j: Int?)] = []
        let lock = NSLock()
        // Tap the PLAYER NODE: its sample time is the schedule's own frame count, so no
        // source-to-graph conversion or schedule-origin inference is needed.
        player.installTap(onBus: 0, bufferSize: 4_096, format: nil) { [weak player] buffer, when in
            var j: Int? = nil
            if let ch = buffer.floatChannelData?[0] {
                for i in 0..<Int(buffer.frameLength) where ch[i] > 0.5 { j = i }
            }
            // The PLAYER's own clock: file frame == playerTime by construction.
            let playerTime = player.flatMap { $0.playerTime(forNodeTime: when) }
            lock.lock()
            hits.append((
                sampleTime: when.isSampleTimeValid ? Double(when.sampleTime) : Double.nan,
                playerSampleTime: playerTime.map { Double($0.sampleTime) } ?? Double.nan,
                frames: Int(buffer.frameLength),
                j: j
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
        player.removeTap(onBus: 0)
        engine.stop()

        lock.lock()
        let captured = hits
        lock.unlock()

        print("PROBE captured=\(captured.count)")
        for (index, h) in captured.prefix(8).enumerated() {
            let delta = index > 0 ? h.sampleTime - captured[index - 1].sampleTime : 0
            print("PROBE series[\(index)] sampleTime=\(h.sampleTime) frames=\(h.frames) delta=\(delta) j=\(h.j as Any)")
        }
        var found = false
        for (index, h) in captured.enumerated() where h.j != nil {
            found = true
            let endPrediction = h.playerSampleTime - Double(h.frames) + Double(h.j!)
            let startPrediction = h.playerSampleTime + Double(h.j!)
            print("PROBE callback[\(index)] playerSampleTime=\(h.playerSampleTime) nodeSampleTime=\(h.sampleTime) frames=\(h.frames) j=\(h.j!)")
            print("PROBE   END   prediction: impulse at player frame \(endPrediction) (file index \(impulseIndex))")
            print("PROBE   START prediction: impulse at player frame \(startPrediction)")
            print("PROBE   endMatchesFileIndex=\(endPrediction == Double(impulseIndex)) startMatchesFileIndex=\(startPrediction == Double(impulseIndex))")
        }
        XCTAssertFalse(captured.isEmpty, "the tap fired no callbacks, so there is nothing to map")
        XCTAssertTrue(found, "no callback carried the impulse, so semantics cannot be read")
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
