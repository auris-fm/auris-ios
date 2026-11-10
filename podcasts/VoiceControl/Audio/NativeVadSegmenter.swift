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
    /// Decides whether one tap buffer contains speech. Injected so the energy rule can be
    /// replaced by a classifier without this type owning model assets or their lifecycle.
    private let speechClassifier: SpeechFrameClassifier
    private var buffer: [Float] = []
    private var speechActive = false
    private var silenceStart: Date?

    /// Whether the early wake-scoring prefix has already been emitted for this utterance.
    private var wakeScorablePrefixEmitted = false

    /// The wake result computed from the CURRENT utterance's early-scored prefix, if any.
    ///
    /// Owned here because this is where the utterance lifecycle is known: it is cleared when the
    /// utterance is delivered, abandoned, or the session resets. The engine's capture callback
    /// launches an asynchronous task, so an engine-side slot could be overwritten by the next
    /// utterance before that task read it — one command's score addressing another's audio.
    var earlyWakeResultForCurrentUtterance: WakeWordResult?
    private var speechFrameCount = 0
    /// Audio that arrived while the classifier had not yet reported speech.
    ///
    /// A windowed classifier cannot report speech until it has judged a full window, and Silero
    /// additionally requires `minSpeechDuration` (100 ms) of confirmed speech before it reports
    /// any. Frames arriving inside that latency are real captured speech, not silence, so they
    /// are held here and prepended when the utterance is confirmed. Measured before this: a
    /// command starting at capture sample zero lost its first 3_840 samples (240 ms) — the
    /// entire attack of its first word.
    private var preRoll: [Float] = []
    /// Capture instant of the earliest frame held in `preRoll`.
    ///
    /// The utterance's start is the start of `preRoll`, not of the frame that confirmed it, so
    /// this is carried through promotion. Without it the utterance is reported as beginning up
    /// to `maxPreRollSamples` later than its first sample, which misplaces the segment against
    /// the emitted reference the echo filter uses.
    private var preRollCapturedAt: MonotonicTime?

    /// Capture session these samples belong to, if the caller supplies one.
    private(set) var currentSession: Int?
    /// Continuous-speech bound that marks a stuck detector. See `defaultStuckActiveMs`.
    private let stuckActiveSamples: Int
    /// Samples of continuously-active speech since it began, used for the stuck check.
    private(set) var activeSamples = 0
    /// Capture instant of each sample in `preRoll`, parallel to it — one entry per SAMPLE, not
    /// per frame. Trimming evicts the OLDEST samples, so the instant of the first retained
    /// sample moves forward with them. Keeping a single start instant while dropping samples
    /// would name a moment that is no longer in the buffer, and keeping only frame-level
    /// instants would misalign the parallel arrays when trimming lands mid-frame.
    private var preRollInstants: [MonotonicTime?] = []
    /// Retains at most this much pre-confirmation audio. 0.5 s covers the classifier's window
    /// plus `minSpeechDuration` with margin while bounding memory when a room never confirms.
    static let maxPreRollSamples = 8000

    /// Capture rate used to convert a sample index into an instant offset.
    static let captureSampleRate = 16_000
    /// Capture instant of the first retained sample, preserved across the buffers that
    /// make up one utterance.
    private var utteranceCapturedAt: MonotonicTime?

    /// Delivers the completed utterance with the instant its **first retained sample** was
    /// captured, and the wake result computed from that same utterance's prefix while it was still
    /// being spoken (nil when the utterance was too short to score early).
    ///
    /// The result travels WITH the utterance rather than through a slot the engine shares with
    /// these callbacks. The engine launches an asynchronous task from this callback, so a shared
    /// slot could be overwritten by the next utterance's prefix before that task read it — an
    /// utterance addressed by another utterance's audio. Carrying it here makes the pairing
    /// structural instead of a timing assumption.
    ///
    /// Preserved through buffering: the segmenter appends several tap buffers before it
    /// emits, so the utterance's start is not the start of the buffer that completed it.
    /// Carrying the first buffer's instant is what lets the echo filter place the segment
    /// against the emitted reference; using the completing buffer's time would shift it by
    /// the segment's own length.
    var onUtterance: (([Float], MonotonicTime?, WakeWordResult?) -> Void)?

    /// Delivers the audio of an in-progress utterance once enough exists to score the wake word
    /// definitively, so detection can run while the user is still speaking.
    ///
    /// The detector only scores classifier windows that end within the eligible span after onset —
    /// about 1.96s. Once that much speech has been captured, every window that could contribute
    /// exists, so scoring this prefix yields exactly the maximum the finished segment would. This
    /// callback carries exactly that prefix: onset through the eligible span, including the
    /// retained pre-speech context that `onUtterance` would have carried.
    ///
    /// It fires at most once per utterance. A shorter utterance never reaches the threshold and is
    /// scored at end of speech, as before.
    var onWakeScorablePrefix: (([Float]) -> Void)?

    /// Called once when trailing silence begins on an utterance that has active speech — the
    /// moment the user appears to have finished talking, before the hangover elapses and before the
    /// utterance closes.
    ///
    /// Deliberately carries no wake information: the segmenter does not know whether an utterance
    /// is addressed, and giving it that judgement would put routing semantics inside audio
    /// segmentation. The consumer decides using its own state.
    var onTrailingSilenceBegan: (() -> Void)?

    /// True while an utterance is open and its trailing silence has begun but not yet ended.
    ///
    /// Exposed so a consumer that only becomes able to open a connection LATER in the silence — a
    /// short utterance whose wake result is not final at onset — can tell whether it is already
    /// too late to wait for another onset. Without this it would wait for an event that has
    /// already happened and never open at all.
    var isInTrailingSilence: Bool { speechActive && silenceStart != nil }

    /// Called when continuously-classified speech reaches the supported duration ceiling.
    ///
    /// `recognition-pipeline.md`: "A detector stuck active is a surfaced segmentation fault, not
    /// ordinary long speech." The fault is a **persistent** state, not an event:
    ///
    /// - The utterance is never dispatched. A fragment must not reach ASR.
    /// - The segmenter does not rearm on its own. Rearming immediately would treat the tail of
    /// the *same* still-spoken request as a brand-new command, which is the very failure this
    /// state exists to prevent.
    /// - It leaves the faulty state only on genuine silence (`process` sees enough
    /// non-speech to establish the utterance ended) or an explicit `clearStuckActiveFault`.
    var onStuckActiveFault: ((StuckActiveFault) -> Void)?

    /// True while the segmenter is in the surfaced stuck-active state. Nothing is dispatched and
    /// no audio accumulates while set.
    private(set) var isStuckActive = false

    struct StuckActiveFault: Equatable {
        /// Samples discarded without being dispatched. Reported so the loss is measurable.
        let discardedSamples: Int
        /// How long the detector had been continuously reporting speech when it tripped.
        let elapsedMs: Int
    }

    /// Set when no speech classifier is available at all.
    ///
    /// This is not a fallback condition. The energy rule is what made a noisy room's ambient
    /// noise look like unending speech, so silently running it would restore the exact defect
    /// while reporting normal listening. Unavailability is surfaced instead, and the segmenter
    /// dispatches nothing: with no classifier there is no trustworthy endpoint.
    private(set) var isClassifierUnavailable = false

    /// The reason recorded when classification became unavailable, retained so a late observer
    /// can still learn about it.
    ///
    /// Assembly decides availability at construction, before the engine installs its forwarding.
    /// An event that fires only at that moment is lost, which is why unavailability is held as
    /// state as well as delivered as an event.
    private(set) var classifierUnavailableReason: String?

    struct ClassifierUnavailableFault: Equatable {
        let reason: String
    }

    /// Announces that a fault ended, so a listener can clear the interruption.
    var onRecoveredFromFault: (() -> Void)?

    /// Delivers unavailability. Setting it replays the current reason if classification is
    /// ALREADY unavailable, because the condition is decided at construction and an observer
    /// installed afterwards would otherwise never hear about it.
    var onClassifierUnavailable: ((ClassifierUnavailableFault) -> Void)? {
        didSet {
            if let reason = classifierUnavailableReason, onClassifierUnavailable != nil {
                onClassifierUnavailable?(ClassifierUnavailableFault(reason: reason))
            }
        }
    }

    /// Reports that speech classification cannot run, so capture must not pretend to work.
    func reportClassifierUnavailable(_ reason: String) {
        guard !isClassifierUnavailable else { return }
        isClassifierUnavailable = true
        classifierUnavailableReason = reason
        FileLog.shared.addMessage("[VoicePipeline] vad classifier unavailable: \(reason); not falling back to the energy rule")
        onClassifierUnavailable?(ClassifierUnavailableFault(reason: reason))
    }

    /// Leaves the stuck-active state deliberately (for example when listening is restarted).
    ///
    /// Not called from `process`: an automatic exit is what would convert the tail of one
    /// request into a second command.
    func clearStuckActiveFault() {
        guard isStuckActive else { return }
        isStuckActive = false
        reset()
    }

    /// Resets all segmentation state at a real session boundary (stop/restart).
    ///
    /// Unlike `clearStuckActiveFault` this is not guarded on `isStuckActive`: an ordinary
    /// partially buffered utterance would otherwise survive a restart, letting PCM from the old
    /// session concatenate with the new one and be dispatched as a single command. Classifier
    /// unavailability is deliberately not reset — it describes the assembled pipeline, not a
    /// session, and clearing it would let listening resume with no classifier to segment it.
    func resetForNewSession() {
        reset()
    }

    // MARK: - Contribution observation hooks (observe-only)
    //
    // The Voice Sharing collector needs three signals that `onUtterance` cannot provide, because completion
    // arrives after wake/bleed rejection and only for segments that reach an endpoint:
    //
    // * `capture_id` must be minted at confirmed speech start, before any rejection decision exists — a
    // bleed- or wake-rejected segment is still collectable audio (spec), and rejections are silent
    // `return`s downstream, so a completion-only view never sees them at all.
    // * Long in-progress speech must be admitted against clip ceilings before completion, otherwise a
    // segment whose completion never arrives (permission closes mid-speech) has already exceeded its
    // memory/disk bound.
    // * A reset while speech is active is a CANCELLATION, not a completion: the partial contribution is
    // discarded rather than finalized.
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

    /// Fires when `reset` interrupts ACTIVE speech. Not fired on a natural end or on a reset with nothing
    /// open, so a cancelled partial is never confused with a completed utterance.
    var onSpeechCancelled: (() -> Void)?

    /// - Parameters:
    /// - threshold: RMS energy threshold above which audio is considered speech (energy
    /// classifier only; the injected classifier decides when one is supplied)
    /// - silenceTimeoutMs: milliseconds of silence before ending an utterance
    /// - minSpeechFrames: minimum consecutive speech frames before triggering
    static let defaultThreshold: Float = 0.002

    /// How long the segmenter waits after the last speech before emitting.
    ///
    /// Only this segmenter's own timing needs it; nothing outside reads it to
    /// discount the hangover, because the hangover cannot be separated from a
    /// quietly spoken word by a consumer that only has the buffer.
    static let defaultSilenceTimeoutMs = 500

    /// The span after onset within which a classifier window's final embedding must fall for the
    /// window to be eligible. Every window that can affect the wake maximum ends inside it, so
    /// audio past this point cannot change the result. 2 seconds at the capture rate.
    static let wakeEligibleSpanSamples = 32_000

    /// The supported utterance-duration ceiling, in milliseconds.
    ///
    /// `arch/ios.md` ("Speech classification mapping"): "The iOS safety ceiling is 240 seconds,
    /// matching the supported Android ceiling; reaching it surfaces an explicit duration-limit
    /// interruption under the linked utterance lifecycle, rather than classifying the input as
    /// noise or emitting a completed command. Retain an inspectable fault state and suppress the
    /// continuing tail until a genuine silence boundary or explicit listening restart."
    ///
    /// It is a safety ceiling, not a command-length policy: reaching it says only that the
    /// supported limit was exceeded, never that the audio was noise.
    static let defaultStuckActiveMs = 240_000

    init(threshold: Float = NativeVadSegmenter.defaultThreshold, silenceTimeoutMs: Int = NativeVadSegmenter.defaultSilenceTimeoutMs, minSpeechFrames: Int = 5, stuckActiveMs: Int = NativeVadSegmenter.defaultStuckActiveMs, classifier: SpeechFrameClassifier? = nil) {
        self.threshold = threshold
        self.silenceTimeoutMs = silenceTimeoutMs
        self.minSpeechFrames = minSpeechFrames
        self.speechClassifier = classifier ?? EnergySpeechFrameClassifier(threshold: threshold)
        self.stuckActiveSamples = stuckActiveMs * 16000 / 1000
    }

    func process(_ samples: [Float], capturedAt: MonotonicTime? = nil, session: Int? = nil) {
        // Recorded so a fault raised by THESE samples can be attributed to the capture session
        // that produced them. `capture.stop` does not drain already-queued callbacks, so the
        // session that ends can differ from the one delivering the notification.
        currentSession = session
        if isClassifierUnavailable {
            // Nothing may be dispatched without a classifier: an energy decision here is the
            // defect this change exists to remove.
            return
        }
        // Speech classification, not a fixed level: a room whose ambient noise exceeds the
        // threshold makes every frame "speech" under the energy rule, so no silence endpoint
        // ever arrives and the utterance never closes.
        if speechClassifier.isSpeech(samples) {
            if isStuckActive {
                // Still the same unending request: keep discarding, do not accumulate.
                //
                // The silence interval must be cleared here. Leaving it running while speech
                // continues would let two brief gaps, separated by a long positive tail, add up to
                // one elapsed time and clear the fault from inside a still-speaking request —
                // rearm through the back door, which is what this state exists to prevent.
                silenceStart = nil
                return
            }
            if buffer.isEmpty { utteranceCapturedAt = capturedAt }
            if !speechActive { activeSamples = 0 }
            buffer.append(contentsOf: samples)
            speechFrameCount += 1
            let wasActive = speechActive
            if !speechActive && speechFrameCount >= minSpeechFrames {
                speechActive = true
                if !preRoll.isEmpty {
                    // Confirmed: the held audio precedes this frame and belongs to the command.
                    // The utterance therefore starts when the earliest held frame was captured,
                    // not when this frame was.
                    buffer.insert(contentsOf: preRoll, at: 0)
                    utteranceCapturedAt = preRollCapturedAt ?? utteranceCapturedAt
                    preRoll.removeAll(keepingCapacity: true)
                    preRollInstants.removeAll()
                    preRollCapturedAt = nil
                }
            } else if !speechActive, !preRoll.isEmpty || preRollCapturedAt == nil {
                // Still unconfirmed: keep holding this frame with the earlier ones so ordering
                // is preserved, and let the buffer stay empty until confirmation.
                buffer.removeAll(keepingCapacity: true)
                appendPreRoll(samples, capturedAt: capturedAt)
                return
            }
            if speechActive {
                if !wasActive {
                    onSpeechStarted?(samples.count)
                    onSpeechAccumulated?(buffer[...], buffer.count)
                } else {
                    onSpeechAccumulated?(buffer.suffix(samples.count), buffer.count)
                }
            }
            silenceStart = nil
            if checkRetainedCeiling() { return }
            emitWakeScorablePrefixIfReady()
        } else if speechActive || isStuckActive {
            if silenceStart == nil {
                silenceStart = Date()
                // Fires once per silence run, not once per silent frame: the flag above is what
                // makes the consumer see the BEGINNING of the silence rather than a steady stream
                // of "still silent" notifications.
                onTrailingSilenceBegan?()
            }
            // While stuck-active nothing accumulates: the audio is discarded, not dispatched.
            if !isStuckActive {
                buffer.append(contentsOf: samples)
                // Hangover frames are retained audio and count toward the ceiling. Checking only
                // on positive classification would let a long hangover cross the bound and then
                // be emitted by the endpoint without any interruption.
                if checkRetainedCeiling() { return }
                onSpeechAccumulated?(buffer.suffix(samples.count), buffer.count)
            }
            if let start = silenceStart,
               Date().timeIntervalSince(start) * 1000 > Double(silenceTimeoutMs) {
                if isStuckActive {
                    // Genuine silence ended the request: leave the faulty state without
                    // dispatching anything from it. Recovery is announced so an observer can
                    // clear the interruption instead of leaving it presented forever.
                    FileLog.shared.addMessage("[VoicePipeline] vad duration-limit interruption cleared after silence; nothing dispatched")
                    isStuckActive = false
                    reset()
                    onRecoveredFromFault?()
                } else {
                    // The first silent frame is the acoustic end of speech; the emission happens a
                    // whole hangover later. They are different instants and the log must not merge
                    // them, or the endpoint decision looks instantaneous and the configured wait
                    // disappears into the segment length.
                    emitUtterance(silenceObserved: start)
                }
            }
        } else if !speechActive {
            // Unconfirmed: the consecutive count is invalidated, but the AUDIO is not.
            // A frame the classifier has not yet called speech may still be the opening of the
            // command, so it is held as pre-roll and prepended on confirmation.
            speechFrameCount = 0
            silenceStart = nil
            appendPreRoll(samples, capturedAt: capturedAt)
        } else {
            // Active utterance: a sub-threshold frame is part of the utterance (silence inside
            // or after the command) and is retained for the endpoint decision above.
            buffer.append(contentsOf: samples)
        }
    }

    /// Hold unconfirmed audio, keeping its capture instants aligned under eviction.
    /// Enforces the supported ceiling against the RETAINED utterance.
    ///
    /// Must be called after every append that grows the retained buffer, in both the positive and
    /// negative branches: pre-roll prepended on confirmation and hangover frames kept inside the
    /// utterance are audio the user genuinely spoke. Counting only post-confirmation positives —
    /// or checking only when a positive frame arrives — lets the emitted utterance exceed the
    /// ceiling the platform promises, with no interruption.
    ///
    /// - Returns: true when the fault tripped and the caller must stop processing this frame.
    @discardableResult
    private func checkRetainedCeiling() -> Bool {
        guard speechActive, !isStuckActive else { return false }
        activeSamples = buffer.count
        guard activeSamples >= stuckActiveSamples else { return false }

        let discarded = buffer.count
        let elapsedMs = activeSamples / 16
        FileLog.shared.addMessage("[VoicePipeline] vad duration-limit interruption: \(elapsedMs)ms retained; discarded \(discarded) samples without dispatching; staying in the fault state until silence")
        isStuckActive = true
        // The utterance is abandoned, so a prefix score already computed for it must go with it.
        // Keeping it would let a long positive utterance that is never dispatched lend its score to
        // the next short utterance — a command addressed by audio that was discarded.
        earlyWakeResultForCurrentUtterance = nil
        // Discard the captured audio and refuse to dispatch any of it.
        buffer.removeAll(keepingCapacity: true)
        preRoll.removeAll(keepingCapacity: true)
        preRollInstants.removeAll()
        preRollCapturedAt = nil
        utteranceCapturedAt = nil
        speechFrameCount = 0
        silenceStart = nil
        onStuckActiveFault?(StuckActiveFault(discardedSamples: discarded, elapsedMs: elapsedMs))
        return true
    }

    /// Holds unconfirmed audio with a per-sample capture instant.
    ///
    /// `capturedAt` is the instant of the buffer's FIRST sample, so each sample's instant is that
    /// offset forward by its position at the capture rate. Storing one instant per frame would be
    /// wrong as soon as trimming cuts inside a frame: the first retained sample would be reported
    /// at the frame's start rather than its own position. Copying a value per sample costs memory
    /// only inside the bounded pre-roll window.
    private func appendPreRoll(_ samples: [Float], capturedAt: MonotonicTime?) {
        preRoll.append(contentsOf: samples)
        if let base = capturedAt {
            preRollInstants.append(contentsOf: (0..<samples.count).map { index in
                base + Double(index) / Double(Self.captureSampleRate)
            })
        } else {
            preRollInstants.append(contentsOf: repeatElement(nil, count: samples.count))
        }
        if preRoll.count > Self.maxPreRollSamples {
            let excess = preRoll.count - Self.maxPreRollSamples
            preRoll.removeFirst(excess)
            preRollInstants.removeFirst(excess)
        }
        // The buffer's start is the instant of the oldest retained SAMPLE, not of its frame.
        // flatMap flattens the double optional (first gives MonotonicTime??). Written this
        // way because SwiftFormat rewrites `?? nil` here, which does not compile.
        preRollCapturedAt = preRollInstants.first.flatMap { $0 }
    }

    /// Emits the preamble for early wake scoring, once, when the prefix that can affect the result
    /// is complete.
    ///
    /// The threshold is the eligible span itself, expressed in samples at the capture rate. Using
    /// samples rather than elapsed wall-clock time is deliberate: the comparison must be exact, and
    /// a clock-based test could fire a frame early or late depending on scheduling, which would
    /// make the early score differ from the finished-segment score for a reason unrelated to the
    /// detector.
    private func emitWakeScorablePrefixIfReady() {
        guard !wakeScorablePrefixEmitted, let onWakeScorablePrefix else { return }
        guard buffer.count >= Self.wakeEligibleSpanSamples else { return }
        wakeScorablePrefixEmitted = true
        // The prefix, not the whole buffer: only the eligible span can affect the maximum, and
        // handing over the full in-progress buffer would make the early run depend on how long the
        // user happened to keep talking.
        onWakeScorablePrefix(Array(buffer.prefix(Self.wakeEligibleSpanSamples)))
    }

    private func emitUtterance(silenceObserved: Date?) {
        let utterance = Array(buffer)
        let durationMs = Int(Float(utterance.count) / 16.0)
        // Two distinct events, reported as two, and named for what they actually measure rather
        // than for the nearest capture concept.
        //
        // `silenceObserved` is the instant VAD first PROCESSED a frame as silence. It is not the
        // instant of the last captured speech sample: the two differ by the capture-to-process
        // latency, which this file does not measure. The interval below is therefore the
        // process-side dwell in silence, which is what the endpoint logic actually waits on.
        // Calling it the acoustic end of speech would claim a capture-domain measurement that does
        // not exist here — the per-sample capture instants are monotonic and are not mixed into
        // this wall-clock interval.
        let dwellMs = silenceObserved.map { Int((Date().timeIntervalSince($0) * 1000).rounded()) }
        FileLog.shared.addMessage(
            "[VoicePipeline] vad ~\(durationMs)ms (\(utterance.count) samples) silenceDwell=\(dwellMs.map { "\($0)" } ?? "?")ms hangoverLimit=\(silenceTimeoutMs)ms endpointDecision"
        )
        // A windowed classifier carries state across frames; clearing it here keeps the next
        // utterance from being biased by the one that just closed.
        speechClassifier.reset()
        preRoll.removeAll()
        preRollInstants.removeAll()
        preRollCapturedAt = nil
        buffer.removeAll()
        speechActive = false
        silenceStart = nil
        speechFrameCount = 0
        // The next utterance scores early again. Without this only the first command in a session
        // would ever get an early wake result, and every later one would silently fall back to
        // end-of-speech scoring — the regression the whole item exists to avoid, and invisible
        // because the fallback still works.
        wakeScorablePrefixEmitted = false
        // Delivered with its own result, then cleared: the value leaves with the utterance it
        // describes, so nothing can be inherited by the next one.
        let carriedWakeResult = earlyWakeResultForCurrentUtterance
        earlyWakeResultForCurrentUtterance = nil
        onUtterance?(utterance, utteranceCapturedAt, carriedWakeResult)
    }

    func reset() {
        let wasActive = speechActive
        speechClassifier.reset()
        activeSamples = 0
        isStuckActive = false
        wakeScorablePrefixEmitted = false
        earlyWakeResultForCurrentUtterance = nil
        preRoll.removeAll()
        preRollInstants.removeAll()
        preRollCapturedAt = nil
        buffer.removeAll()
        utteranceCapturedAt = nil
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
