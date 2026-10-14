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
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString).caf")
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
        let audibleFile = try writeImpulseFile(name: "audible")

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

        var ti = mach_timebase_info_data_t(); mach_timebase_info(&ti)
        let secondsPerTick = Double(ti.numer) / Double(ti.denom) / 1_000_000_000.0
        // ONE CLOCK: our own host clock is sampled at the moment the engine starts; every callback's
        // hostTime is compared against it using the same mach timebase. No scheduled origin is
        // added to a node timestamp, so no unmapped offset is assumed.
        let engineStartHost = mach_absolute_time()
        try engine.start()
        player.scheduleFile(audibleFile, at: nil)
        player.play()

        var deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            lock.lock(); let empty = hits.isEmpty; lock.unlock()
            if !empty { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        deadline = Date().addingTimeInterval(2)
        while Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        player.stop()
        player.removeTap(onBus: 0)
        engine.stop()

        lock.lock()
        let captured = hits
        lock.unlock()

        print("PROBE rate=\(rate) captured=\(captured.count)")
        for (index, h) in captured.prefix(10).enumerated() {
            let sinceStartHost = Double(h.hostTime &- engineStartHost) * secondsPerTick
            let T = h.sampleTime
            let startPrediction = T / rate
            let endPrediction = (T - Double(h.frames)) / rate
            print("PROBE series[\(index)] T=\(T) N=\(h.frames) j=\(h.j as Any) sinceEngineStartSeconds=\(sinceStartHost)")
            print("PROBE   START models sinceStart=T/rate=\(startPrediction) (diff \(sinceStartHost - startPrediction))")
            print("PROBE   END   models sinceStart=(T-N)/rate=\(endPrediction) (diff \(sinceStartHost - endPrediction))")
        }
        XCTAssertFalse(captured.isEmpty, "no callbacks captured")
        XCTAssertTrue(captured.contains { $0.j != nil }, "no callback carried content, so the run is inert")

        // TWO READINGS, ONE UNVERIFIED ASSUMPTION — recorded, not decided.
        //
        // The first delivered callback has T < N (e.g. T=4356, N=4800):
        //   * START model (sampleTime = the buffer's first sample): buffer spans [T, T+N) —
        //     valid only if the node clock's zero is at or before this buffer, i.e. the callback
        //     then arrives BEFORE its own buffer's span, which is unusual for a render callback.
        //   * END model (sampleTime = the buffer's last sample + 1): buffer spans [T-N, T) —
        //     requires T-N >= 0, i.e. a node clock whose zero precedes engine.start() (a negative
        //     start is otherwise impossible). The measured arrival (≈27 ms after start) sits
        //     INSIDE this span, which is the natural place for a render callback.
        // Both survive; they differ exactly in WHEN the node clock's zero occurs, which is the
        // unverified assumption. No discrimination is claimed. What IS measured and preserved:
        //   T/N/j series, constant START-model offset (−63.6 ms) and END-model offset (+36.4 ms)
        //   across all callbacks (spread ≈ 2 µs), the graph rate (48 000), and the content marker.
        if let first = captured.first {
            print("PROBE firstCallback T=\(first.sampleTime) N=\(first.frames) "
                + "ENDstart=\(first.sampleTime - Double(first.frames)) (negative ⇒ END needs a pre-start node zero)")
        }
    }
}
