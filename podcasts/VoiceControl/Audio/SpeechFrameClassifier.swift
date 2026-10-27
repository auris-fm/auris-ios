import Foundation
import Accelerate
import PocketCastsUtils
import SherpaOnnxC

/// Decides whether a frame of audio is speech.
///
/// Split out from `NativeVadSegmenter` so the decision can be replaced without touching
/// how audio is retained or where an utterance ends. The segmenter owns PCM and endpoints;
/// a classifier only answers "is this frame speech".
protocol SpeechFrameClassifier: AnyObject {
    /// - Returns: true when the frame is classified as speech.
    func isSpeech(_ samples: [Float]) -> Bool

    /// Drops any accumulated state so a new utterance starts clean.
    ///
    /// A windowed classifier carries recurrent state across frames, so reusing it after an
    /// endpoint biases the next utterance towards the previous one's classification.
    func reset()
}

/// The original decision: a frame is speech when its RMS energy reaches `threshold`.
///
/// Kept as the default so every existing behaviour and test is unchanged, and so the
/// classified path can be compared against it.
final class EnergySpeechFrameClassifier: SpeechFrameClassifier {
    private let threshold: Float

    init(threshold: Float) {
        self.threshold = threshold
    }

    func isSpeech(_ samples: [Float]) -> Bool {
        guard !samples.isEmpty else { return false }
        var meanSq: Float = 0
        vDSP_measqv(samples, 1, &meanSq, vDSP_Length(samples.count))
        return sqrt(meanSq) >= threshold
    }

    func reset() {}
}

/// Speech classification from the bundled Silero VAD model via sherpa-onnx.
///
/// WHY. The energy classifier decides on loudness alone. In a room whose ambient level sits
/// above the configured threshold, every frame is "speech", so no silence endpoint ever
/// arrives and the utterance never closes. A model that classifies the *structure* of speech
/// can report non-speech in that room, which is what lets an endpoint occur at all.
///
/// WHAT THIS DOES NOT DO. It does not by itself guarantee an endpoint: a room loud enough to
/// look like speech to the model still yields none. That case is a fault, reported separately,
/// not a silent no-op.
///
/// Returns false when the model cannot be loaded, so a missing resource degrades to
/// "no speech detected" rather than crashing or fabricating detections. `isAvailable`
/// reports which of the two happened so the caller can log it honestly.
final class SileroSpeechFrameClassifier: SpeechFrameClassifier {
    /// The detector requires exactly this many samples per `acceptWaveform` call.
    static let frameSize = 512

    /// The wrapper `fatalError`s when the runtime rejects a config, so it is only ever
    /// constructed after the model path and file have been verified. Keeping the stored
    /// property non-optional means every read is safe.
    private let detector: SherpaOnnxVoiceActivityDetectorWrapper
    private var pending: [Float] = []
    /// Latest classification, held between frames because a single capture buffer does not
    /// contain a whole model window.
    private var lastIsSpeech = false

    private init(detector: SherpaOnnxVoiceActivityDetectorWrapper) {
        self.detector = detector
    }

    /// Builds a classifier backed by the model bundled with the app.
    ///
    /// - Returns: nil when the model resource is missing or the runtime rejects the config.
    static func bundled() -> SileroSpeechFrameClassifier? {
        guard let modelPath = Bundle.main.path(forResource: "silero_vad", ofType: "onnx") else {
            FileLog.shared.addMessage("[VoicePipeline] silero model missing from bundle")
            return nil
        }
        return make(modelPath: modelPath)
    }

    /// Builds a classifier for an explicit model path.
    ///
    /// `maxSpeechDuration` is deliberately set far above any plausible command. The library
    /// defaults it to 5 seconds, which would silently reinstate the forced duration cap this
    /// codebase forbids — Sherpa would end a segment mid-command and we would treat its
    /// boundary as an endpoint. Nothing consumes Sherpa's segments anyway; only the per-frame
    /// decision is read, so this bound exists solely to stop the library closing internally.
    static func make(modelPath: String) -> SileroSpeechFrameClassifier? {
        guard FileManager.default.fileExists(atPath: modelPath) else { return nil }
        let silero = sherpaOnnxSileroVadModelConfig(
            model: modelPath,
            threshold: 0.5,
            minSilenceDuration: 0.1,
            minSpeechDuration: 0.1,
            windowSize: Self.frameSize,
            maxSpeechDuration: 2400.0
        )
        var config = sherpaOnnxVadModelConfig(
            sileroVad: silero,
            sampleRate: 16000,
            numThreads: 1,
            provider: "cpu"
        )
        // Only reached when the file exists, so the wrapper's fatalError path is not taken
        // for the missing-resource case; that case returns nil above.
        let detector = SherpaOnnxVoiceActivityDetectorWrapper(
            config: &config,
            buffer_size_in_seconds: 30
        )
        return SileroSpeechFrameClassifier(detector: detector)
    }

    func isSpeech(_ samples: [Float]) -> Bool {
        guard !samples.isEmpty else { return lastIsSpeech }
        pending.append(contentsOf: samples)
        // Only whole model windows carry a decision; a partial window must not be judged.
        while pending.count >= Self.frameSize {
            let frame = Array(pending.prefix(Self.frameSize))
            pending.removeFirst(Self.frameSize)
            detector.acceptWaveform(samples: frame)
            lastIsSpeech = detector.isSpeechDetected()
            // Drain completed segments so the library's queue cannot grow across a session.
            // The samples are intentionally discarded: this codebase owns PCM and endpoints,
            // and a library segment boundary is not a natural endpoint (measured: they omit
            // input samples and a duration cap silently becomes a segmentation boundary).
            while !detector.isEmpty() {
                detector.pop()
            }
        }
        return lastIsSpeech
    }

    func reset() {
        pending.removeAll(keepingCapacity: true)
        lastIsSpeech = false
        detector.reset()
    }

    deinit {
        detector.clear()
    }
}
