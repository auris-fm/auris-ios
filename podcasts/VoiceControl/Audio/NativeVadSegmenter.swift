import Foundation
import Accelerate
import PocketCastsUtils

class NativeVadSegmenter {
    /// The level this segmenter treats as speech.
    ///
    /// It decides where an utterance starts and ends — not whether a command
    /// follows the wake. The wake trimmer does not read it: a positive detection
    /// and its window do not establish that nothing was said after it, so no
    /// consumer may use this level to discard a transcript.
    let threshold: Float
    private let silenceTimeoutMs: Int
    private let minSpeechFrames: Int
    private let maxUtteranceSamples: Int?  // nil = unlimited
    private var buffer: [Float] = []
    private var speechActive = false
    private var silenceStart: Date?
    private var speechFrameCount = 0

    var onUtterance: (([Float]) -> Void)?

    // MARK: - Contribution observation hooks (observe-only)
    //
    // The Voice Sharing collector needs three signals that `onUtterance` cannot provide, because completion
    // arrives AFTER wake/bleed rejection and only for segments that reach an endpoint:
    //
    //   * `capture_id` must be minted at confirmed speech start, before any rejection decision exists — a
    //     bleed- or wake-rejected segment is still collectable audio (spec), and rejections are silent
    //     `return`s downstream, so a completion-only view never sees them at all.
    //   * Long in-progress speech must be admitted against clip ceilings BEFORE completion, otherwise a
    //     segment whose completion never arrives (permission closes mid-speech) has already exceeded its
    //     memory/disk bound.
    //   * A reset while speech is active is a CANCELLATION, not a completion: the partial contribution is
    //     discarded rather than finalized.
    //
    // These fire alongside the existing logic and read state only. Nothing here appends to, trims, or
    // reorders `buffer`, and no hook return value influences recognition. Retention behaviour stays pinned by
    // NativeAudioCaptureTests.

    /// Fires once when speech is CONFIRMED (the frame that reaches `minSpeechFrames`), not on pending energy:
    /// an unconfirmed burst is discarded by design and must not open a contribution.
    var onSpeechStarted: ((_ confirmationFrameSamples: Int) -> Void)?

    /// Fires per retained frame while a segment is active, reporting the total samples retained so far. Lets a
    /// consumer enforce a ceiling during the utterance instead of discovering overshoot after it ends.
    /// Carries the REAL new PCM since the previous call (not a copy of the whole buffer, not a count).
    /// The contribution consumer appends exactly these bytes to its own bounded copy, so what it claims to
    /// hold is what actually arrived. Kept separate from `onUtterance` so in-progress bounds hold even if
    /// the utterance is never emitted.
    var onSpeechAccumulated: ((_ newSamples: ArraySlice<Float>, _ bufferCount: Int) -> Void)?

    /// Fires when `reset()` interrupts ACTIVE speech. Not fired on a natural end or on a reset with nothing
    /// open, so a cancelled partial is never confused with a completed utterance.
    var onSpeechCancelled: (() -> Void)?

    /// - Parameters:
    ///   - threshold: RMS energy threshold above which audio is considered speech
    ///   - silenceTimeoutMs: milliseconds of silence before ending an utterance
    ///   - minSpeechFrames: minimum consecutive speech frames before triggering
    ///   - maxUtteranceMs: maximum utterance duration in ms (nil = unlimited). Forces end when buffer exceeds this.
    static let defaultThreshold: Float = 0.002

    /// How long the segmenter waits after the last speech before emitting.
    ///
    /// Only this segmenter's own timing needs it; nothing outside reads it to
    /// discount the hangover, because the hangover cannot be separated from a
    /// quietly spoken word by a consumer that only has the buffer.
    static let defaultSilenceTimeoutMs = 500

    init(threshold: Float = NativeVadSegmenter.defaultThreshold, silenceTimeoutMs: Int = NativeVadSegmenter.defaultSilenceTimeoutMs, minSpeechFrames: Int = 5, maxUtteranceMs: Int? = nil) {
        self.threshold = threshold
        self.silenceTimeoutMs = silenceTimeoutMs
        self.minSpeechFrames = minSpeechFrames
        self.maxUtteranceSamples = maxUtteranceMs.map { $0 * 16000 / 1000 }
    }

    func process(_ samples: [Float]) {
        let energy = rms(samples)

        if energy >= threshold {
            buffer.append(contentsOf: samples)
            speechFrameCount += 1
            let wasActive = speechActive
            if !speechActive && speechFrameCount >= minSpeechFrames {
                speechActive = true
                // Edge-triggered at confirmation only; the argument is this frame's size for provenance, and
                // the callback cannot affect anything downstream.
                onSpeechStarted?(samples.count)
            }
            if speechActive {
                if !wasActive {
                    // CONFIRMATION DELIVERS THE WHOLE CONFIRMED PREFIX — every buffered frame INCLUDING the
                    // pre-confirmation ones and the confirming frame itself — exactly once. The frames that
                    // merely accumulated toward minSpeechFrames are part of the segment (the segmenter kept
                    // them in its buffer), so a delta-only scheme would silently drop that prefix and the
                    // contribution copy could never match the emitted audio. Later calls deliver only their
                    // own delta, so nothing is duplicated.
                    onSpeechAccumulated?(buffer[...], buffer.count)
                } else {
                    onSpeechAccumulated?(buffer[buffer.count - samples.count ..< buffer.count], buffer.count)
                }
            }
            silenceStart = nil
            // Max duration: force utterance end when buffer exceeds limit
            if let maxSamples = maxUtteranceSamples, speechActive, buffer.count >= maxSamples {
                emitUtterance()
                return
            }
        } else if speechActive {
            if silenceStart == nil {
                silenceStart = Date()
            }
            buffer.append(contentsOf: samples)
            if speechActive {
                onSpeechAccumulated?(buffer[buffer.count - samples.count ..< buffer.count], buffer.count)
            }
            if let start = silenceStart,
               Date().timeIntervalSince(start) * 1000 > Double(silenceTimeoutMs) {
                emitUtterance()
            }
        } else {
            // Speech confirmation requires consecutive energetic frames. An
            // interruption invalidates both the pending count and its audio.
            buffer.removeAll(keepingCapacity: true)
            speechFrameCount = 0
            silenceStart = nil
        }
    }

    private func emitUtterance() {
        let utterance = Array(buffer)
        let durationMs = Int(Float(utterance.count) / 16.0)
        FileLog.shared.addMessage("[VoicePipeline] vad ~\(durationMs)ms (\(utterance.count) samples)")
        buffer.removeAll()
        speechActive = false
        silenceStart = nil
        speechFrameCount = 0
        onUtterance?(utterance)
    }

    func reset() {
        // Only an interrupted ACTIVE segment is a cancellation. Resetting while idle is routine housekeeping
        // and must not look like a discarded contribution.
        let wasActive = speechActive
        buffer.removeAll()
        speechActive = false
        silenceStart = nil
        speechFrameCount = 0
        if wasActive { onSpeechCancelled?() }
    }

    /// Root-mean-square energy of the signal.
    /// Uses vDSP for vectorized computation.
    private func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var meanSq: Float = 0
        vDSP_measqv(samples, 1, &meanSq, vDSP_Length(samples.count))
        return sqrt(meanSq)
    }
}
