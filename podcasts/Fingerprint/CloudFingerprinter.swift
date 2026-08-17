import Foundation

/// Streaming windowed spectral-peak fingerprinter — the Swift port of the
/// server's `SpectralGenerator` (Go, `internal/fingerprint/spectral.go`).
///
/// It computes per-window (8 s windows, 1 s stride) sorted `[UInt32]` hash
/// sets that are bit-identical to the server's reference fingerprints for the
/// same audio, so the client can match against `fingerprint-compact-v2` data
/// served by `/api/v1/episodes/{id}/fingerprints`.
///
/// Pipeline: PCM → downmix → windowed-sinc resample to 16 kHz → Hann STFT
/// (4096-pt FFT, 1024 hop) → spectral peak picking (adaptive floor) →
/// anchor/target pairing into 32-bit hashes → per-window sorted hash sets.
///
/// IMPORTANT: every constant and float operation mirrors the Go implementation
/// exactly (all trig from fdlibm-derived libm). Do not "improve" the math here
/// without changing the server in lockstep and regenerating the parity fixtures
/// (`CloudFingerprinterTests`).
final class CloudFingerprinter {
    struct Window: Equatable {
        let timestampSec: Int
        let hashes: [UInt32]
    }

    private struct Peak {
        let bin: Int
        let frame: Int
    }

    // Window geometry mirrors the server constants (also the mobile
    // FingerprintConstants where the same concept exists).
    private let windowDurationMs = 8000
    private let windowIntervalMs = 1000
    private let targetSampleRate = 16000
    private let fftSize = 4096
    private let hopSize = 1024
    private let maxPeaksPerFrame = 8
    private let peakMinSeparation = 3
    private let peakFloorRatio = 0.05
    private let targetZoneFrames = 24
    private let maxTargetsPerAnchor = 5
    private let resampleTaps = 16
    private let frameDurationS = 1024.0 / 16000.0

    // Input (downmixed, source rate) and resampled (16 kHz mono) buffers.
    private var input: [Float] = []
    private var resampled: [Float] = []
    private var sourceRate = 16000

    // STFT frames and their peaks, computed incrementally.
    private var framePeaks: [[Peak]] = []
    private var frameStart = 0

    private let hannWindow: [Double]

    private var windows: [Window] = []
    private var consumedWindows = 0
    private var nextWindowStartSec = 0
    private var finished = false

    init() {
        // Uses the fftSize constant (4096) via a local to avoid referencing
        // self before all members are initialized.
        let size = 4096
        hannWindow = (0..<size).map { i in
            0.5 - 0.5 * Foundation.cos(2.0 * Double.pi * Double(i) / Double(size - 1))
        }
    }

    /// Feeds a chunk of decoded PCM (normalized float, [-1, 1]) at the source sample rate.
    func pushSamples(_ samples: [Float], channels: Int, sampleRate: Int) {
        guard !finished else { return }
        if sampleRate > 0 { sourceRate = sampleRate }
        appendDownmixed(samples, channels: channels)
        drainResampled()
        computeFrames()
        emitWindows()
    }

    /// Signals the end of the stream: flushes remaining samples, computes the
    /// final frames, and emits every remaining window (mirrors the server's
    /// whole-file processing).
    @discardableResult
    func finish() -> [Window] {
        guard !finished else { return windows }
        finished = true
        drainResampled()
        computeFrames()
        while nextWindowStartSec <= lastFullWindowStartSec() {
            emitWindow(nextWindowStartSec)
            nextWindowStartSec += windowIntervalMs / 1000
        }
        return windows
    }

    /// Windows emitted so far (a window is only emitted once its tail lookahead is available).
    var windowsSoFar: [Window] { windows }

    /// Returns the windows emitted since the last call to this method.
    func drainWindows() -> [Window] {
        let emitted = Array(windows.dropFirst(consumedWindows))
        consumedWindows = windows.count
        return emitted
    }

    private func appendDownmixed(_ samples: [Float], channels: Int) {
        if channels <= 1 {
            input.append(contentsOf: samples)
        } else {
            let frameCount = samples.count / channels
            for i in 0..<frameCount {
                var sum: Float = 0
                for c in 0..<channels {
                    sum += samples[i * channels + c]
                }
                input.append(sum / Float(channels))
            }
        }
    }

    private func drainResampled() {
        guard !input.isEmpty else { return }
        // Mirror the server's output length: floor(count × toRate / fromRate).
        let targetOutLen = Int(Double(input.count) * Double(targetSampleRate) / Double(sourceRate))
        let ratio = Double(sourceRate) / Double(targetSampleRate)
        let cutoff: Double
        if targetSampleRate < sourceRate {
            cutoff = 0.9 * Double(targetSampleRate) / Double(sourceRate)
        } else {
            cutoff = 0.9
        }
        while resampled.count < targetOutLen {
            let pos = Double(resampled.count) * ratio
            let i0 = Int(pos)
            let frac = pos - Double(i0)
            var sum = 0.0
            for k in -resampleTaps...resampleTaps {
                let idx = i0 + k
                if idx < 0 || idx >= input.count { continue }
                sum += Double(input[idx]) * sincKernel(Double(k) - frac, cutoff: cutoff)
            }
            resampled.append(Float(sum))
        }
    }

    /// Blackman-windowed sinc kernel — mirrors the server's `sincKernel`.
    private func sincKernel(_ t: Double, cutoff: Double) -> Double {
        let value: Double
        if t == 0.0 {
            value = cutoff
        } else {
            value = Foundation.sin(Double.pi * t * cutoff) / (Double.pi * t)
        }
        let n = 2.0 * Double(resampleTaps)
        let win = 0.42 -
            0.5 * Foundation.cos(2.0 * Double.pi * (t + Double(resampleTaps)) / n) +
            0.08 * Foundation.cos(4.0 * Double.pi * (t + Double(resampleTaps)) / n)
        return value * win
    }

    private func computeFrames() {
        while frameStart + fftSize <= resampled.count {
            var re = [Double](repeating: 0, count: fftSize)
            var im = [Double](repeating: 0, count: fftSize)
            for i in 0..<fftSize {
                re[i] = Double(resampled[frameStart + i]) * hannWindow[i]
            }
            fft(re: &re, im: &im)
            let mag = (0..<(fftSize / 2 + 1)).map { i in Foundation.hypot(re[i], im[i]) }
            framePeaks.append(pickPeaks(mag))
            frameStart += hopSize
        }
    }

    private func pickPeaks(_ mag: [Double]) -> [Peak] {
        let floor = (mag.max() ?? 0) * peakFloorRatio
        var local: [Int] = []
        for b in 2..<(mag.count - 2) {
            if mag[b] > floor &&
                mag[b] >= mag[b - 1] && mag[b] >= mag[b - 2] &&
                mag[b] >= mag[b + 1] && mag[b] >= mag[b + 2] {
                local.append(b)
            }
        }
        // Descending magnitude, deterministic tie-break by bin (matches Go).
        local.sort { a, b in
            if mag[a] != mag[b] { return mag[a] > mag[b] }
            return a < b
        }
        var selected: [Int] = []
        for b in local {
            if selected.count >= maxPeaksPerFrame { break }
            if !selected.contains(where: { abs($0 - b) < peakMinSeparation }) {
                selected.append(b)
            }
        }
        return selected.map { Peak(bin: $0, frame: framePeaks.count) }
    }

    private func emitWindows() {
        guard !finished else { return }
        while nextWindowStartSec <= lastFullWindowStartSec() && canEmit(nextWindowStartSec) {
            emitWindow(nextWindowStartSec)
            nextWindowStartSec += windowIntervalMs / 1000
        }
    }

    private func lastFullWindowStartSec() -> Int {
        let duration = windowDurationMs / 1000
        let totalDuration = Int(Double(resampled.count) / Double(targetSampleRate))
        return max(0, totalDuration - duration)
    }

    // A window can be emitted once its last anchor frame's target zone is
    // within the computed frames: lastFrame(start) + targetZoneFrames < size.
    private func canEmit(_ startSec: Int) -> Bool {
        let lastFrame = Int(Double(startSec + windowDurationMs / 1000) / frameDurationS)
        return lastFrame + targetZoneFrames < framePeaks.count
    }

    private func emitWindow(_ startSec: Int) {
        windows.append(Window(timestampSec: startSec, hashes: windowHashes(startSec)))
    }

    private func windowHashes(_ startSec: Int) -> [UInt32] {
        let firstFrame = Int(Double(startSec) / frameDurationS)
        let lastFrame = Int(Double(startSec + windowDurationMs / 1000) / frameDurationS)

        var seen = Set<UInt32>()
        var hashes: [UInt32] = []
        for fi in firstFrame...lastFrame {
            guard fi < framePeaks.count else { break }
            for anchor in framePeaks[fi] {
                var targets = 0
                var tf = fi + 1
                while tf < framePeaks.count && tf <= fi + targetZoneFrames && targets < maxTargetsPerAnchor {
                    for target in framePeaks[tf] {
                        if targets >= maxTargetsPerAnchor { break }
                        let h = pairHash(anchor.bin, target.bin, dt: tf - fi)
                        if seen.insert(h).inserted { hashes.append(h) }
                        targets += 1
                    }
                    tf += 1
                }
            }
        }
        return hashes.sorted()
    }

    /// Mirrors the server's `pairHash` and `freqCode`.
    private func pairHash(_ bin1: Int, _ bin2: Int, dt: Int) -> UInt32 {
        (UInt32(freqCode(bin1)) << 22) | (UInt32(freqCode(bin2)) << 12) | UInt32(dt & 0xFFF)
    }

    private func freqCode(_ bin: Int) -> Int {
        var hz = Double(bin) * Double(targetSampleRate) / Double(fftSize)
        if hz < 20.0 { hz = 20.0 }
        let lo = log2(20.0)
        let hi = log2(Double(targetSampleRate) / 2.0)
        var v = (log2(hz) - lo) / (hi - lo)
        if v < 0 { v = 0.0 }
        if v > 1 { v = 1.0 }
        return Int(v * 1023)
    }

    // Mirrors Go math.Log2: Log(x) * (1 / Ln2).
    private func log2(_ x: Double) -> Double {
        Foundation.log(x) * (1.0 / 0.6931471805599453)
    }

    /// In-place radix-2 Cooley-Tukey FFT — verbatim port of the server's `fft`.
    private func fft(re: inout [Double], im: inout [Double]) {
        let n = re.count
        var j = 0
        for i in 1..<n {
            var bit = n >> 1
            while j & bit != 0 {
                j ^= bit
                bit >>= 1
            }
            j ^= bit
            if i < j {
                re.swapAt(i, j)
                im.swapAt(i, j)
            }
        }
        var length = 2
        while length <= n {
            let ang = -2.0 * Double.pi / Double(length)
            let wRe = Foundation.cos(ang)
            let wIm = Foundation.sin(ang)
            let half = length / 2
            var i = 0
            while i < n {
                var curRe = 1.0
                var curIm = 0.0
                for k in 0..<half {
                    let uRe = re[i + k]
                    let uIm = im[i + k]
                    let vRe = re[i + k + half] * curRe - im[i + k + half] * curIm
                    let vIm = re[i + k + half] * curIm + im[i + k + half] * curRe
                    re[i + k] = uRe + vRe
                    im[i + k] = uIm + vIm
                    re[i + k + half] = uRe - vRe
                    im[i + k + half] = uIm - vIm
                    let nextRe = curRe * wRe - curIm * wIm
                    curIm = curRe * wIm + curIm * wRe
                    curRe = nextRe
                }
                i += length
            }
            length <<= 1
        }
    }
}
