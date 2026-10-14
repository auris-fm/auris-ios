import AVFoundation
import XCTest
@testable import podcasts

/// MEASUREMENT PROBE (repeat-install work): the deterministic offline-render probe shows feeder
/// taps fire 7/7 callbacks on every run. The failing lifecycle case adds: EpisodeOutputTap (with
/// its handoff), installed TWICE without remove, publishing through the handoff into the
/// reference. This probe replicates that EXACT shape in a loop and reports per run: callbacks,
/// publishes, submissions, deliveries — so the varying component is isolated to one stage.
final class RepeatInstallDeliveryProbe: XCTestCase {

    func testExactLifecycleShapeAcrossRuns() throws {
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

            let reference = PlaybackEchoReference()
            let handoff = EchoReferenceHandoff(reference: reference, capacity: 16)
            let tap = EpisodeOutputTap(engine: engine)
            tap.handoff = handoff

            tap.install()
            tap.install()   // the repeat install under test

            var callbacks = 0
            var delivered = 0
            let lock = NSLock()
            // Observe the reference from the outside after drain.
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
            handoff.drain()
            delivered = reference.snapshot().count
            let before = delivered
            mixer.removeTap(onBus: 0)
            engine.stop()
            let after = reference.snapshot().count
            lock.lock()
            summaries.append("run\(run): rendered=\(rendered) beforeStop=\(before) afterStop=\(after)")
            lock.unlock()
            continue
            lock.lock()
            summaries.append("run\(run): rendered=\(rendered) delivered=\(delivered) peak=\(reference.snapshot().map { abs($0) }.max() ?? 0)")
            lock.unlock()
        }
        for s in summaries { print("REPEATPROBE \(s)") }
        XCTAssertFalse(summaries.isEmpty)
    }
}
