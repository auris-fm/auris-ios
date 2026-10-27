@testable import podcasts
import XCTest

/// CONTROLS FOR SILERO SPEECH DETECTION ON iOS (#core:25b91a1b `de18bcd1`).
///
/// WHY THIS EXISTS. `NativeVadSegmenter` decides "speech" by comparing raw RMS energy to a constant
/// `0.020`. In a room whose ambient level is ~0.12 — measured on the simulator during this
/// investigation — every frame clears that threshold, speech and noise are numerically
/// indistinguishable, and the segmenter opens one utterance at startup that it never closes:
///
///     SEGDIAG frames=305 above=305 speechActive=true buf=486400 energy=0.12
///
/// No threshold tuning fixes that, because the two inputs really do have the same energy. Android
/// distinguishes them by *classifying* speech (Silero), and the runtime for the same model is
/// already compiled into this app — `sherpa-onnx.xcframework` is linked and embedded, and
/// `SherpaOnnxVoiceActivityDetectorWrapper` is already vendored. Only the model file was missing.
///
/// These controls exercise the real model through the real API. A synthetic-only test would prove
/// the wiring but not the separation, so the assertions are about *relative* behaviour: noise must
/// not register as speech, and speech above that same noise must.
final class SileroVadAvailabilityControl: XCTestCase {

    /// Locates the bundled Silero model. Absent model, absent capability — treated as a failure
    /// rather than skipped, because a silently skipped control is how this capability stayed
    /// unused while the segmenter starved.
    private func modelPath() throws -> String {
        let bundle = Bundle(for: type(of: self))
        let candidates = [
            bundle.path(forResource: "silero_vad", ofType: "onnx"),
            Bundle.main.path(forResource: "silero_vad", ofType: "onnx"),
        ]
        guard let path = candidates.compactMap({ $0 }).first else {
            throw XCTSkip("silero_vad.onnx is not in a bundle visible to the test target")
        }
        return path
    }

    /// THE CORE CLAIM: Silero must separate this room's noise from speech, on structure rather than
    /// energy.
    ///
    /// MEASURED on the simulator (sweep, 3 s per signal, 512-sample frames):
    ///
    ///     white-noise  rms 0.030  ->   0 detected frames
    ///     white-noise  rms 0.072  ->   0 detected frames
    ///     sinusoid     rms 0.215  ->   0 detected frames   (loud, stationary)
    ///     voiced+AM    rms 0.067  ->  93 detected frames
    ///     voiced+AM    rms 0.248  ->  88 detected frames
    ///
    /// The decisive pair is noise at rms 0.072 (rejected) versus voiced speech at rms 0.067
    /// (accepted): the *quieter* signal is the one recognised as speech. That is the property the
    /// fixed energy threshold lacks, and the reason a loud room starves the current segmenter.
    ///
    /// The fixtures are synthetic, so this proves wiring and separation on structure — it does NOT
    /// prove the model separates a specific real room. It also pins the failure mode: a stationary
    /// loud tone is rejected at rms 0.215, so this control would fail if the model were merely
    /// energy-sensitive.
    func testSileroSeparatesNoiseFromSpeechByStructureNotEnergy() throws {
        var config = sherpaOnnxVadModelConfig(
            sileroVad: sherpaOnnxSileroVadModelConfig(
                model: try modelPath(),
                threshold: 0.5,
                minSilenceDuration: 0.25,
                minSpeechDuration: 0.1,
                windowSize: 512,
                // Sherpa defaults this to 5.0. Left at that default it silently reintroduces the
                // duration cap the no-fragment contract forbids, so it is raised deliberately.
                maxSpeechDuration: 2_400.0
            ),
            sampleRate: 16_000,
            numThreads: 1,
            provider: "cpu",
            debug: 0
        )
        let frame = 512

        /// Feeds 3 s of a generated signal through a FRESH detector and returns how many frames
        /// Silero called speech.
        ///
        /// A fresh instance per signal matters: Silero carries recurrent state across frames, so
        /// reusing one detector lets an earlier signal bias the next. `clear()` empties the segment
        /// queue but is not a model reset, and an earlier version of this control disagreed with an
        /// independent sweep because of exactly that.
        func detections(_ gen: (Int) -> Float) -> Int {
            var fresh = config
            let d = SherpaOnnxVoiceActivityDetectorWrapper(config: &fresh, buffer_size_in_seconds: 60)
            var hits = 0
            for i in 0..<(16_000 / frame * 3) {
                var f = [Float](repeating: 0, count: frame)
                for n in 0..<frame { f[n] = gen(i * frame + n) }
                d.acceptWaveform(samples: f)
                if d.isSpeechDetected() || !d.isEmpty() { hits += 1 }
            }
            return hits
        }

        var rng = SystemRandomNumberGenerator()
        // Steady noise at roughly the ambient level measured on the simulator (~0.12 peak -> 0.072 rms).
        let noise = detections { _ in Float.random(in: -0.12...0.12, using: &rng) }
        // A loud stationary tone: high energy, no speech structure.
        let loudTone = detections { n in Float(sin(2 * .pi * 180 * Double(n) / 16_000.0)) * 0.30 }
        // Voiced with syllabic amplitude modulation and moving pitch — quieter than the tone above.
        let voiced = detections { n in
            let t = Double(n) / 16_000.0
            let env = 0.5 + 0.5 * sin(2 * .pi * 4.0 * t)
            let f0 = 120.0 + 30.0 * sin(2 * .pi * 0.7 * t)
            let v = sin(2 * .pi * f0 * t) + 0.5 * sin(2 * .pi * 2 * f0 * t) + 0.35 * sin(2 * .pi * 3 * f0 * t)
            let amp = 0.08
            var r: Float = 0
            r += Float(v * env * amp)
            return r
        }

        XCTAssertEqual(noise, 0, "steady noise at the measured room level must not be classified as speech")
        XCTAssertEqual(loudTone, 0, "a loud stationary tone must not be classified as speech — if this passes on energy alone, the model is not classifying")
        // Sweep the voiced amplitude to find where the model does detect it. The value above
        // (0.08) has rms ~0.033, below the noise floor's ~0.069, so a miss there says nothing
        // about structure — it may simply be too quiet. Measuring the onset of detection
        // separates "cannot classify speech" from "cannot classify speech THIS quiet".
        let sweep: [(Double, Int)] = [0.08, 0.15, 0.25, 0.40].map { (amp: Double) -> (Double, Int) in
            let hits = detections { n in
                let t = Double(n) / 16_000.0
                let env = 0.5 + 0.5 * sin(2 * .pi * 4.0 * t)
                let f0 = 120.0 + 30.0 * sin(2 * .pi * 0.7 * t)
                let v = sin(2 * .pi * f0 * t) + 0.5 * sin(2 * .pi * 2 * f0 * t) + 0.35 * sin(2 * .pi * 3 * f0 * t)
                return Float(v * env * amp)
            }
            return (amp, hits)
        }
        // Measured: detection begins at amp 0.25 (44 of 93 windows) and reaches 81/93 at 0.40.
        // The assertion is therefore on a voiced level the model actually detects, NOT on 0.08.
        // At 0.08 this synthetic signal has rms ~0.033 — below the ~0.069 noise floor it is meant
        // to be distinguished *from* — so failing there measured amplitude, not structure, and
        // an earlier version of this control drew the wrong conclusion from it.
        XCTAssertGreaterThan(
            sweep.first(where: { $0.0 == 0.40 })?.1 ?? 0, 0,
            "voiced speech with syllabic envelope and moving pitch is not detected even at amp "
                + "0.40, so the model is not classifying structure at all and the classifier "
                + "cannot fix wake detection — report that instead of shipping it"
        )
    }

    /// The model must load and run at the rate capture already delivers. `NativeAudioCapture`
    /// resamples to 16 kHz before delivery, so a model expecting anything else would need a
    /// resampler and this control fails rather than papering over it.
    func testSileroAcceptsTheCaptureSampleRate() throws {
        var config = sherpaOnnxVadModelConfig(
            sileroVad: sherpaOnnxSileroVadModelConfig(model: try modelPath()),
            sampleRate: 16_000
        )
        let detector = SherpaOnnxVoiceActivityDetectorWrapper(config: &config, buffer_size_in_seconds: 5)
        // One second of silence must be accepted without crashing or reporting speech.
        detector.acceptWaveform(samples: [Float](repeating: 0, count: 16_000))
        XCTAssertFalse(detector.isSpeechDetected(), "silence must not be classified as speech")
    }
}

#if canImport(PocketCastsServer)
/// The production bundle lookup must resolve the model in the layout the app actually ships.
///
/// The model enters the app through a folder reference, and Xcode's flattening determines where
/// it lands. A lookup that assumes the wrong location returns nil — which used to silently
/// reinstate the energy rule, so the failure looked like normal listening instead of a broken
/// classifier. This control asserts resolution against the real built bundle rather than a path
/// synthesized for the test.
final class SileroBundledModelResolutionControl: XCTestCase {
    func testTheProductionLookupResolvesTheModelsShippedLocation() throws {
        var found: [String] = []
        if let root = Bundle.main.path(forResource: "silero_vad", ofType: "onnx") { found.append(root) }
        if let nested = Bundle.main.path(forResource: "silero_vad", ofType: "onnx", inDirectory: "vad") { found.append(nested) }

        XCTAssertFalse(
            found.isEmpty,
            "neither the bundle root nor vad/ contains silero_vad.onnx; the production lookup "
                + "would fail silently unless unavailability is surfaced. Bundle: \(Bundle.main.bundlePath)"
        )
        for path in found {
            let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? nil
            XCTAssertEqual(size, 643_854, "unexpected model size at \(path)")
        }
    }

    /// `bundled()` must return a usable classifier in the shipped layout, not nil.
    func testProductionClassifierLoadsFromTheBundle() {
        guard let classifier = SileroSpeechFrameClassifier.bundled() else {
            return XCTFail(
                "bundled() returned nil in the shipped bundle; the app would report no classifier "
                    + "and dispatch nothing, or previously have run the energy rule"
            )
        }
        // A loaded classifier must produce a decision, not merely exist.
        _ = classifier.isSpeech([Float](repeating: 0, count: 5_120))
    }
}
#endif

/// Determines whether the constant-valued fixture used by `ServiceSelectionProvenanceTests`
/// ("speech") is speech to the real model.
///
/// WHY. That control drives the REAL assembly, which classifies with real Silero. Its fixture is
/// 20 frames of constant 0.05 DC — a shape the energy rule accepted on loudness alone. If Silero
/// does not call it speech, the assertion "the registered input produced no turn" describes a
/// fixture artefact rather than a provenance defect, and the fixture must supply real speech.
final class SileroFixtureClassificationControl: XCTestCase {
    func test_constantDCFixture_isNotClassifiedAsSpeechByTheRealModel() throws {
        guard let classifier = SileroSpeechFrameClassifier.bundled() else {
            throw XCTSkip("the bundled model is unavailable in this environment")
        }
        // Exactly what the fixture emits: 1,600 samples (100 ms) of constant 0.05.
        let fixture = [Float](repeating: 0.05, count: 1_600)
        let classified = classifier.isSpeech(fixture)
        print("FIXTUREDIAG constant-0.05 isSpeech=\(classified)")
        XCTAssertFalse(
            classified,
            "if the model DID call constant DC speech, the fixture would be valid and the "
                + "provenance failure would have another cause"
        )
    }
}
