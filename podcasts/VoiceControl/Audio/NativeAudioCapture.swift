import AVFoundation
import PocketCastsUtils

/// Boundary over the shared `AVAudioSession` used by capture. The
/// ownership-sensitive teardown goes through this seam so a unit test can prove
/// that a session playback owns is never deactivated.
protocol CaptureAudioSession: AnyObject {
    /// Configure the shared session for simultaneous input and output.
    func configureForCapture() throws
    /// Restore the playback-friendly category. This is safe even while playback
    /// owns the session; it does not deactivate it.
    func restorePlaybackCategory()
    /// Activate or deactivate the session.
    func setActive(_ active: Bool, notifyOthers: Bool) throws
}

/// The microphone source the ASR engine consumes.
///
/// Extracted so a test can substitute capture and drive the REAL start/input path — the service
/// reaches `start(in:)` only through its gate, and `start(in:)` begins capture, so without this
/// seam a caller-level control cannot run without opening the microphone. Substituting is
/// behaviourally what the production object does; nothing about the listening or provenance
/// semantics changes.
protocol AudioCaptureSource: AnyObject {
    var onCapturedSamples: (([Float], MonotonicTime?) -> Void)? { get set }
    func start() throws
    func stop()
}


/// Live `AVAudioSession` adapter for capture.
final class RealCaptureAudioSession: CaptureAudioSession {
    private var session: AVAudioSession { AVAudioSession.sharedInstance() }

    func configureForCapture() throws {
        // defaultToSpeaker: ensure audio plays through the main speaker, not the
        // earpiece, so podcast playback isn't silenced when VoiceControl is active.
        // mixWithOthers: allow other app audio to play alongside wake-word listening.
        // allowBluetooth: support Bluetooth headsets with built-in mics.
        try session.setCategory(.playAndRecord, options: [.mixWithOthers, .allowBluetooth, .defaultToSpeaker])
        try session.setMode(.default)
    }

    func restorePlaybackCategory() {
        // Match `PlaybackManager.setAudioSessionProperties`, which selects `.spokenAudio`: restoring
        // `.default` here would silently change the mode of a live playback session.
        try? session.setCategory(.playback, mode: .spokenAudio, policy: .longFormAudio)
    }

    func setActive(_ active: Bool, notifyOthers: Bool) throws {
        if notifyOthers {
            try session.setActive(active, options: .notifyOthersOnDeactivation)
        } else {
            try session.setActive(active)
        }
    }
}

class NativeAudioCapture: AudioCaptureSource {
    let engine = AVAudioEngine()
    private let sampleRate = 16000.0
    private var energyLogged = false
    private var tapInstalled = false
    /// Periodic capture telemetry.
    ///
    /// `First buffer` is logged once per process and the VAD logs only when an utterance is
    /// emitted, so after the first buffer nothing reports whether samples still arrive. A user
    /// reporting "everything is ready but still no wake word" could not be diagnosed from the log
    /// at all: a quiet room, a level under the VAD threshold, and a dead tap all produce silence
    /// (#core:25b91a1b `98ba5c48`). This reports buffer arrival and the peak level against the
    /// threshold, throttled so a healthy pipeline does not flood the log.
    ///
    /// Observability only: it does not gate, alter or delay sample delivery.
    private var telemetry = CaptureTelemetry()
    private static let telemetryInterval: TimeInterval = 5
    private let session: CaptureAudioSession
    /// Live playback-ownership signal, re-read at teardown. Deactivating a
    /// session playback owns would stop the user's podcast, so only a session
    /// capture itself activated may be deactivated.
    private let isPlaybackActive: () -> Bool
    /// Delivers converted samples with the instant the hardware captured them (from the
    /// buffer's own `AVAudioTime`), or nil when that host time is invalid on the route.
    var onCapturedSamples: (([Float], MonotonicTime?) -> Void)?

    init(
        session: CaptureAudioSession = RealCaptureAudioSession(),
        isPlaybackActive: @escaping () -> Bool = { PlaybackManager.shared.isAudioSessionInUse }
    ) {
        self.session = session
        self.isPlaybackActive = isPlaybackActive
    }

    /// The callback BOUNDARY: maps the tap buffer's own time to a capture instant.
    /// A valid host time IS the hardware capture moment; an invalid one yields nil so
    /// the consumer declines to align rather than guessing from arrival time.
    static func captureInstant(when: AVAudioTime) -> MonotonicTime? {
        when.isHostTimeValid ? AVAudioTime.seconds(forHostTime: when.hostTime) : nil
    }

    /// Delivers one tap buffer to the subscribed consumer with its capture instant.
    ///
    /// The tap calls THIS, and a control observes the same function, so the boundary under test
    /// is the one production runs — not a parallel copy of its arithmetic. `when` is the
    /// buffer's own capture time, not this call's arrival; on a route whose host time is invalid
    /// the instant is nil and the echo filter declines to align rather than guessing.
    func deliver(_ samples: [Float], when: AVAudioTime) {
        onCapturedSamples?(samples, Self.captureInstant(when: when))
    }

    func start() throws {
        try session.configureForCapture()
        // NOTE: Do NOT call setPreferredSampleRate — it locks the hardware to one
        // rate and breaks playback at other rates. The resample below handles any
        // rate mismatch between hardware input and the model's 16kHz requirement.
        try session.setActive(true, notifyOthers: false)

        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        let formatDescription = inputFormat.description  // includes commonFormat, sampleRate, channelCount

        // Tap receives audio on the real-time audio thread. Copy samples off
        // immediately and dispatch to a processing queue — Swift Task {} and
        // FileLog silently fail on the real-time thread.
        let bufferSize: AVAudioFrameCount = 1024
        let processingQueue = DispatchQueue(label: "fm.auris.audio.processing", qos: .userInitiated)

        // On real iOS devices the input format is always Float32, but the simulator
        // may deliver Int16 PCM from the Mac's audio hardware. When floatChannelData
        // is nil (non-float format), fall back to int16ChannelData and convert.
        var formatWarningLogged = false
        inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: nil) { [weak self] buf, when in
            guard let self else { return }
            let frameLength = Int(buf.frameLength)
            let nativeRate = buf.format.sampleRate

            let rawSamples: [Float]
            if let channelData = buf.floatChannelData {
                rawSamples = Array(UnsafeBufferPointer(start: channelData[0], count: frameLength))
            } else if let channelData = buf.int16ChannelData {
                // Simulator / Mac hardware often delivers Int16. Convert to float
                // normalized to [-1, 1] and warn once so the format is visible in logs.
                rawSamples = UnsafeBufferPointer(start: channelData[0], count: frameLength).map { Float($0) / Float(Int16.max) }
                if !formatWarningLogged {
                    formatWarningLogged = true
                    processingQueue.async {
                        FileLog.shared.addMessage("[VoicePipeline] Input format is Int16 (not Float32) — converting. Format: \(formatDescription)")
                    }
                }
            } else {
                // Unknown / unsupported format — log once and drop this buffer.
                if !formatWarningLogged {
                    formatWarningLogged = true
                    processingQueue.async {
                        FileLog.shared.addMessage("[VoicePipeline] Unsupported audio format — dropping buffers. Format: \(formatDescription)")
                    }
                }
                return
            }

            processingQueue.async { [weak self] in
                guard let self else { return }
                let converted: [Float]
                if nativeRate == self.sampleRate {
                    converted = rawSamples
                } else {
                    converted = self.resample(rawSamples, from: nativeRate, to: self.sampleRate)
                }
                // Log first buffer to confirm tap is delivering audio
                if !self.energyLogged {
                    self.energyLogged = true
                    let maxVal = converted.max() ?? 0
                    let minVal = converted.min() ?? 0
                    FileLog.shared.addMessage("[VoicePipeline] First buffer: \(converted.count) samples, min=\(String(format: "%.6f", minVal)) max=\(String(format: "%.6f", maxVal))")
                    FileLog.shared.forceFlush()
                }
                self.telemetry.record(rms: CaptureTelemetry.rms(of: converted))
                if let report = self.telemetry.takeReport(
                    now: Date(),
                    interval: Self.telemetryInterval
                ) {
                    FileLog.shared.addMessage(report)
                    // FORCE THE FLUSH. `FileLog` holds entries in memory until 100 accumulate
                    // (`bufferThreshold`), so a buffered line is invisible for minutes and is lost
                    // entirely if the process is terminated first. The whole point of this line is
                    // to be readable WHILE capture is running — a buffered diagnostic is no better
                    // than the silence it replaces. `First buffer` already forces its flush for
                    // exactly this reason.
                    FileLog.shared.forceFlush()
                }
                self.deliver(converted, when: when)
            }
        }
        tapInstalled = true

        engine.prepare()
        try engine.start()
        FileLog.shared.addMessage("[VoicePipeline] Audio engine started (input: \(formatDescription) → \(sampleRate)Hz)")
    }

    func stop() {
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        engine.stop()
        teardownSession()
    }

    /// Ownership-aware session teardown. Restoring the playback-friendly category
    /// is always safe; deactivating is not — a session playback owns must be left
    /// active or the user's podcast stops. Playback ownership is re-read live here
    /// because it can begin while capture is running.
    func teardownSession() {
        session.restorePlaybackCategory()
        // Only a session capture itself activated may be deactivated. When
        // playback owns the shared session, deactivating it would stop the
        // user's podcast; leave it active. Ownership is re-read live here
        // because playback can begin while capture is running.
        guard !isPlaybackActive() else { return }
        try? session.setActive(false, notifyOthers: true)
    }

    /// Downsample from `from` Hz to `to` Hz using linear interpolation.
    private func resample(_ samples: [Float], from: Double, to: Double) -> [Float] {
        let outputCount = Int(Double(samples.count) * to / from)
        guard outputCount > 1 else { return [] }
        var result = [Float](repeating: 0, count: outputCount)
        for i in 0..<outputCount {
            let pos = Double(i) * (Double(samples.count) - 1) / Double(outputCount - 1)
            let idx = Int(pos)
            let frac = Float(pos - Double(idx))
            let a = samples[min(idx, samples.count - 1)]
            let b = samples[min(idx + 1, samples.count - 1)]
            result[i] = a + (b - a) * frac
        }
        return result
    }
}
