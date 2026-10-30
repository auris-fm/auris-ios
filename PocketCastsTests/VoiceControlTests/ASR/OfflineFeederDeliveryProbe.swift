import AVFoundation
import XCTest

/// MEASUREMENT PROBE (repeat-install work): does a feeder tap fire callbacks reliably under
/// MANUAL OFFLINE rendering? The failing lifecycle case renders offline and intermittently
/// delivers zero audio with IDENTICAL rendered-frame counts, so the question is whether the tap
/// callback entry itself is the varying part. Runs the same offline render N times and reports
/// callbacks and delivered frames per run.
final class OfflineFeederDeliveryProbe: XCTestCase {

    func testFeederTapCallbacksUnderRepeatedOfflineRenders() throws {
        let f = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        var summaries: [String] = []
        for run in 0..<10 {
            let engine = AVAudioEngine()
            let player = AVAudioPlayerNode()
            let mixer = AVAudioMixerNode()
            engine.attach(player)
            engine.attach(mixer)
            engine.connect(player, to: mixer, format: f)
            engine.connect(mixer, to: engine.outputNode, format: f)

            var callbacks = 0
            var deliveredFrames = 0
            let lock = NSLock()
            // Tap the feeder exactly as EpisodeOutputTap.install() resolves it (mixer feeds output).
            mixer.installTap(onBus: 0, bufferSize: 4_096, format: nil) { buffer, _ in
                lock.lock()
                callbacks += 1
                deliveredFrames += Int(buffer.frameLength)
                lock.unlock()
            }

            try engine.enableManualRenderingMode(.offline, format: f, maximumFrameCount: 4_096)
            engine.prepare()
            try engine.start()

            let count = 32_768
            let buf = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: f, frameCapacity: AVAudioFrameCount(count)))
            buf.frameLength = AVAudioFrameCount(count)
            if let ch = buf.floatChannelData?[0] {
                for i in 0..<count { ch[i] = Float(sin(Double(i) * 0.05) * 0.4) }
            }
            player.scheduleBuffer(buf)
            player.play()
            let out = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat,
                                                     frameCapacity: engine.manualRenderingMaximumFrameCount))
            var rendered = 0
            while rendered < count {
                let s = try engine.renderOffline(engine.manualRenderingMaximumFrameCount, to: out)
                if s == .success { rendered += Int(out.frameLength) } else if s == .error { break }
            }
            mixer.removeTap(onBus: 0)
            engine.stop()
            lock.lock()
            summaries.append("run\(run): rendered=\(rendered) callbacks=\(callbacks) tapFrames=\(deliveredFrames)")
            lock.unlock()
        }
        for s in summaries { print("OFFLINEPROBE \(s)") }
        XCTAssertFalse(summaries.isEmpty)
    }
}
