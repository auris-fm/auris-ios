import Foundation
import PocketCastsUtils

class VoiceAsrEngine {
    private let capture: any AudioCaptureSource
    private let segmenter: NativeVadSegmenter
    private let backend: AsrBackend
    private let signalFilter: SignalFilter
    private let wakeWordDetector: WakeWordDetectorProtocol
    private let gracePeriodSignal: GracePeriodSignal
    private let stageTimer: RecognitionStageTimer
    private let wakeThreshold: Float
    private let translationStage: TranslationStage?

    /// Which echo-filter scope applies to the current output route.
    ///
    /// `recognition-pipeline.md` "Signal Filter" distinguishes route classes rather
    /// than treating "exposed" as a single flag: the built-in loudspeaker uses aligned
    /// playback cross-correlation against the shared reference, external routes must
    /// use delay tracking instead of that window, and an isolated route reduces
    /// exposure without proving echo is absent.
    enum EchoFilterRoute {
        /// Built-in loudspeaker: cross-correlation against the reference applies.
        case builtInSpeaker
        /// External output: codec latency is large and variable, so the built-in
        /// correlation window's alignment assumption does not hold.
        case external
        /// Headset/earbud. Reduced acoustic exposure, but **not** proof of no echo.
        case isolated

        /// Whether the built-in-speaker correlation window may be applied.
        var appliesCorrelationWindow: Bool { self == .builtInSpeaker }

        /// Maps an observed output port to the filter scope it implies.
        ///
        /// Only the built-in loudspeaker allows the aligned correlation window: its
        /// local latency is bounded and the emitted buffer matches what leaves the
        /// device. Every other output — wired, Bluetooth, AirPlay — has large and
        /// variable codec latency, so alignment is unreliable and the window is not
        /// applied. A headset input does not change the output's alignment properties.
        static func forOutput(_ output: AudioRouteOutput) -> EchoFilterRoute {
            switch output {
            case .builtInSpeaker:
                return .builtInSpeaker
            case .headphones, .bluetoothLE:
                return .isolated
            case .bluetoothHFP, .bluetoothA2DP, .airPlay, .unknown:
                return .external
            }
        }
    }

    var contributionCollector: VoiceSharingCollector?
    /// Segments that completed with NO collector attached. Zero in a healthy
    /// process; a non-zero value names the exact failure shape the incident forensics could not
    /// obtain, and the first occurrence is logged immediately.
    private(set) var segmentsWithoutCollectorCount = 0

    /// Records one segment delivered to a nil collector: counted every time, LOGGED once so a
    /// standing nil cannot flood the log, then flushed (a diagnosis must survive termination).
    private func noteSegmentWithoutCollector() {
        segmentsWithoutCollectorCount += 1
        guard segmentsWithoutCollectorCount == 1 else { return }
        FileLog.shared.addMessage(
            "[VoicePipeline] segment completed with NO contribution collector: "
                + "collection skipped (init-order or a cleared reference)")
        FileLog.shared.forceFlush()
    }
    private(set) var echoFilterRoute: EchoFilterRoute = .external
    /// How long the reference survives a route change so the handover is still filtered.
    ///
    /// **This is a chosen software limit, not a measurement of audibility.** It bounds
    /// how much emitted audio is kept after the output path changes; it does not claim
    /// that sound stops reaching the microphone at 0.25 s. Output latency, route delay
    /// and the device's own buffering all contribute to the real figure, and none of
    /// them is measured here. The value exists so the handover window is filtered at
    /// all rather than cleared instantly, and it is expected to be revised if a
    /// measured acoustic figure becomes available.
    static let acousticTailSeconds: Double = 0.25
    /// The shared emitted-PCM reference the echo filter correlates against. Producers
    /// append what they send to the output; the filter reads it on the segment path.
    /// When no reference is attached the filter has nothing to correlate and cannot
    /// reject anything, so the scope alone is not sufficient wiring.
    private var echoReference: PlaybackEchoReference?

    /// Attaches the shared emitted-PCM reference.
    func setEchoReference(_ reference: PlaybackEchoReference) {
        echoReference = reference
    }

    /// Where the segment about to be examined begins within the retained reference.
    ///
    /// Returns a negative offset when the segment cannot be placed: without an observed
    /// render position the node may not be rendering, or may have restarted, and the
    /// retained audio's position relative to the segment is then unknown. A negative
    /// offset makes the filter decline to claim alignment rather than align against the
    /// wrong instant — the failure this exists to avoid.
    ///
    /// **The offset is deliberately coarse while the capture side carries no segment
    /// instant.** A segment arriving now is at the newest end of what has been emitted,
    /// so the window is anchored to the reference's end; that is correct under steady
    /// playback and is not correct across a queue lead or a restart, which is why the
    /// segment instant is required before this closes. It is written this way rather
    /// than guessing a precise value from the render anchor alone, because a precise
    /// wrong offset is worse than an honest coarse one.
    /// Where the audible end of the emitted stream sits in the retained window.
    ///
    /// Placed from the output node's **rendered** position, not from the retained end: the
    /// retained end is the newest *submitted* sample, which is ahead of what has been
    /// heard by however much audio is still queued. Using it is misaligned whenever the
    /// queue is non-empty, which is most of streaming playback — not only across a
    /// restart. A negative value means the position is unknown and the filter declines to
    /// align rather than aligning against the wrong instant.
    ///
    /// **Still coarse:** the segment instant is not carried yet, so a segment is assumed
    /// to end at the current audible position. That holds when the segment arrives as it
    /// is captured and not when capture buffering delays it, which is why the capture-side
    /// timestamp is required before alignment acceptance can close.
    func playbackEndOffsetForTesting(capturedAt: MonotonicTime?, segmentSamples: Int) -> Int {
        playbackEndOffsetForSegment(
            capturedAt: capturedAt, segmentSamples: segmentSamples,
            observation: echoReference?.consistentObservation())
    }

    /// TEST-only: fires between the filter-path observation and the filter call. See call site.
    var echoObservationTakenForTesting: (() -> Void)?

    /// TEST seam: the offset arithmetic applied to a CALLER-SUPPLIED observation,
    /// so a control can prove the filter uses the observation it took rather than a fresh
    /// (post-append, displaced) read.
    func engineOffsetFromObservationForTesting(
        observation: PlaybackEchoReference.ConsistentObservation
    ) -> Int {
        playbackEndOffsetForSegment(
            capturedAt: 0, segmentSamples: 0, observation: observation)
    }

    private func playbackEndOffsetForSegment(
        capturedAt: MonotonicTime?, segmentSamples: Int,
        observation: PlaybackEchoReference.ConsistentObservation?
    ) -> Int {
        guard let observation, let anchor = observation.renderAnchor else { return -1 }
        // Without the segment's own instant the position is unknown, so no alignment
        // claim is made. The callback's arrival time is not a substitute: the tap runs on
        // a processing queue, so arrival lags capture by an indeterminate amount and would
        // place the segment later than it was spoken.
        guard let capturedAt else { return -1 }
        // How far the render position in the reference window is *behind* the segment's
        // capture: emitted audio keeps playing while the segment is being captured, so the
        // audible position at capture is earlier than the audible position now.
        // `capturedAt` is the instant of the segment's FIRST sample
        // (`NativeVadSegmenter.utteranceCapturedAt` is set when the buffer first fills), while
        // the value returned here is used as `segmentEndOffset` — the position the compared
        // window ENDS at. Using the first sample's instant for the end places the whole window
        // one segment-length early, and the displacement is not absorbable by the correlation:
        // the window is exactly `mic.count` long, so the real alignment falls outside it and
        // the filter stops rejecting the echo it exists for.
        let segmentEndInstant = capturedAt
            + Double(segmentSamples) / PlaybackEchoReference.pipelineSampleRate

        // How far the render position is *behind* the segment's end: emitted audio keeps playing
        // while the segment is captured, so the audible position then is earlier than now.
        let latency = max(0, anchor.hostTime - segmentEndInstant)
        let latencySamples = Int(latency * PlaybackEchoReference.pipelineSampleRate)
        // The offset is the one computed WITH these samples under the same lock — not a fresh
        // read, which could describe a window an append has already shifted.
        let nowOffset = observation.audibleEndOffset ?? -1
        guard nowOffset >= 0 else { return -1 }
        return max(0, nowOffset - latencySamples)
    }
    var listeningMode: ListeningMode = .wakeWord
    /// INJECTABLE for controls: mints the utterance identity at ADMISSION. Production uses a fresh
    /// UUID; a control can supply a known sequence so it can prove the id the routing input carries
    /// is the ADMITTED one rather than a value rebuilt downstream.
    var utteranceIdGeneratorForTesting: (() -> String)?

    /// TEST SEAM: the engine's live grace signal, so controls can prove a discarded capture did
    /// NOT renew the window (generation unchanged) — cleanup, not consumption (reviewer 1f2c96ce).
    var gracePeriodSignalForTesting: GracePeriodSignal { gracePeriodSignal }

    /// Invoked once the wake decision has established THIS turn's window origin and before the
    /// backend wait, so the turn can be recorded as admitted while its window is still live.
    ///
    /// It has to be here rather than at `onRoutingInput`: that callback runs after recognition, and
    /// on a cold backend the deadline can pass first — in which case a reservation recorded there
    /// would be rejected outright and the turn silently lost (spec `voice-control-core.md:270`: an
    /// utterance observed before the deadline stays eligible through recognition). It also has to
    /// be after the wake decision, not at the top of the method: a wake-selected turn opens its own
    /// window there, and reserving earlier would sample the preceding window's origin.
    var onTurnAdmitted: ((_ utteranceId: String, _ origin: Int?) -> Void)?

    /// Hands the router an input. It returns the ROUTER'S OWN acceptance result: a rejection (e.g.
    /// the service stopped) means nobody took ownership, so the engine keeps the turn and its
    /// `defer` releases rather than assuming a chain that never started will.
    ///
    /// This is deliberately the same single operation that enqueues. A separate "can you accept?"
    /// precheck would be a DIFFERENT operation from the one that takes ownership, so a stop landing
    /// between them could reject the enqueue with no owner left to release.
    var onRoutingInputWithContext: ((IntentRoutingInput, VoiceSharingCollector.CaptureContext?) -> Bool)?
    var onRoutingInput: ((IntentRoutingInput) -> Bool)? {
        get { onRoutingInputWithContext.map { consumer in { consumer($0, nil) } } }
        set { onRoutingInputWithContext = newValue.map { consumer in { input, _ in consumer(input) } } }
    }

    /// Invoked when a turn that was admitted leaves the engine WITHOUT reaching routing — a
    /// backend/recognition/translation drop or a cancellation. The routing path does not call it;
    /// ownership transfers to the routing chain there.
    var onTurnReleased: ((_ utteranceId: String) -> Void)?
    /// Opens the early connection when the utterance is routable AND its trailing silence is
    /// already under way.
    ///
    /// One definition shared by both entry points, because they answer the same question at
    /// different instants: silence began first and the score arrived later, or the score was
    /// already held when silence began. Two copies would let one path drift and silently stop
    /// opening for the utterances it exists for.
    private func openEarlyConnectionIfRoutableDuringTrailingSilence(result: WakeWordResult?) {
        guard segmenter.isInTrailingSilence else { return }
        let positive: Bool = {
            if case .detected? = result { return true }
            return false
        }()
        // Addressed means routable, not merely wake-positive. A follow-up spoken during grace is a
        // real turn even though its wake score is negative, and it needs the same connection:
        // requiring a positive score would open for first commands and never for follow-ups, which
        // is the half a user in a conversation is most likely waiting on.
        let duringGrace = gracePeriodSignal.isActive
        guard positive || duringGrace else {
            FileLog.shared.addMessage("[VoicePipeline] trailing silence — not routable (wake positive=\(positive), grace=\(duringGrace)), no early open")
            return
        }
        FileLog.shared.addMessage("[VoicePipeline] opening early connection (wake positive=\(positive), grace=\(duringGrace))")
        onAddressedTrailingSilenceBegan?()
    }

    /// Called on every positive detection so the service can reset grace and
    /// play the `WAKE_WORD` earcon exactly once.
    var onWakeWordDetected: (() -> Void)?

    /// Called once when trailing silence begins on an utterance whose early wake score is already
    /// positive — that is, an addressed utterance the user appears to have finished speaking.
    ///
    /// This is the instant a cloud connection can usefully be opened: the request is coming, and
    /// the handshake can overlap the hangover and the ASR work instead of following them. It is
    /// deliberately NOT the wake decision, which happens after the endpoint and therefore after
    /// the wait this exists to remove.
    var onAddressedTrailingSilenceBegan: (() -> Void)?
    /// Called when a positive wake result leaves no routable transcript, i.e. the
    /// user woke the assistant and said nothing else. Silent by contract: the wake
    /// is the start of a session, not a failed question, so nothing is played.
    var onWakeOnly: (() -> Void)?
    /// Called when a capture was heard but cannot be routed (a translation failed,
    /// so the English-only intent model must not see it). This — not `onWakeOnly`
    /// — is what the service renders as the `ERROR` earcon: the capture was a
    /// question we could not understand, which is a different event.
    var onUnroutable: (() -> Void)?
    /// Emitted after ASR with monotonic stage durations per
    /// recognition-pipeline.md "Production Recognition Latency Metrics".
    var onStageTiming: ((PipelineStageTiming) -> Void)?

    /// Surfaces a segmentation fault the user must be told about.
    ///
    /// `recognition-pipeline.md`: a detector stuck active is a **surfaced** segmentation fault,
    /// and `arch/ios.md` requires an explicit duration-limit interruption with an inspectable
    /// fault state. A flag private to the segmenter is not surfaced — nothing outside it could
    /// observe the interruption, so the user would see silence with no explanation.
    var onSegmentationFault: ((SegmentationFault) -> Void)?

    /// Announces that the surfaced fault ended, so a listener can clear the interruption.
    var onSegmentationFaultRecovered: (() -> Void)?

    /// Surfaces that speech classification cannot run at all.
    ///
    /// Distinct from a segmentation fault: no classifier means no trustworthy endpoint, so the
    /// engine cannot capture. Reporting this as ordinary listening would present a broken
    /// pipeline as a working one.
    var onClassifierUnavailable: ((String) -> Void)?

    /// A fault the user-facing layer can render.
    struct SegmentationFault: Equatable {
        public enum Kind: Equatable {
            /// Reached the supported utterance-duration ceiling.
            case durationLimitReached
            /// No speech classifier available.
            case classifierUnavailable
        }

        public let kind: Kind
        public let discardedSamples: Int
        public let elapsedMs: Int
        public let reason: String?
    }

    init(
        capture: any AudioCaptureSource = NativeAudioCapture(),
        segmenter: NativeVadSegmenter,
        backend: AsrBackend,
        signalFilter: SignalFilter,
        wakeWordDetector: WakeWordDetectorProtocol,
        gracePeriodSignal: GracePeriodSignal,
        clock: MonotonicClock = SystemMonotonicClock(),
        wakeThreshold: Float = 0.8,
        translationStage: TranslationStage? = nil
    ) {
        self.capture = capture
        self.segmenter = segmenter
        self.backend = backend
        self.signalFilter = signalFilter
        self.wakeWordDetector = wakeWordDetector
        self.gracePeriodSignal = gracePeriodSignal
        self.stageTimer = RecognitionStageTimer(clock: clock)
        self.wakeThreshold = wakeThreshold
        self.translationStage = translationStage
    }

    private final class BackendReadyTaskBox {
        var task: Task<Result<Void, Error>, Never>?
    }

    private let backendReadyBox = BackendReadyTaskBox()
    private let backendReadyLock = NSLock()

    /// Kick off SenseVoice/Canary download+init before capture starts so the
    /// first wake is not blocked behind a silent backend-ready wait.
    /// Only successes are cached: a failed preload clears the task so a later
    /// `start` (gate restart) re-attempts `ensureReady` instead of reusing
    /// the failure forever.
    ///
    /// Concurrency note: `preloadBackend`'s check-then-set is not atomic — two
    /// concurrent calls can both spawn `ensureReady` (last writer wins the
    /// cache; the identity guard still prevents stale clears). Backends must
    /// therefore tolerate concurrent `ensureReady` calls ( SenseVoice/Canary/
    /// Whisper all do: the call is idempotent per instance).
    func preloadBackend() {
        backendReadyLock.lock()
        let existing = backendReadyBox.task
        backendReadyLock.unlock()
        guard existing == nil else { return }
        let box = BackendReadyTaskBox()
        // Intentional box→task→box cycle: the strong capture keeps `box` alive
        // until the task completes so the failure path can always clear the
        // cache; the cycle frees itself when the task returns.
        let task = Task { [backend, self] in
            let result = await backend.ensureReady()
            switch result {
            case .success:
                FileLog.shared.addMessage("[VoicePipeline] backend ready \(backend.requiredModel.id)")
            case .failure(let error):
                FileLog.shared.addMessage("[VoicePipeline] backend FAILED \(backend.requiredModel.id): \(error)")
                self.clearBackendReadyTask(box)
            }
            return result
        }
        box.task = task
        backendReadyLock.lock()
        backendReadyBox.task = task
        backendReadyLock.unlock()
    }

    private func clearBackendReadyTask(_ box: BackendReadyTaskBox) {
        backendReadyLock.lock()
        defer { backendReadyLock.unlock() }
        guard let cached = backendReadyBox.task, box.task != nil, cached == box.task else { return }
        backendReadyBox.task = nil
    }

    /// Current classifier availability, so a caller can refuse listening instead of presenting
    /// a pipeline that cannot produce an utterance.
    var isClassifierUnavailable: Bool { segmenter.isClassifierUnavailable }

    /// Identifies the current capture session.
    ///
    /// `capture.stop` does not drain callbacks already queued by the capture, so a stopped
    /// session's samples and the faults they produce can arrive after a restart. Main-queue
    /// delivery does not order events produced on different threads, so the fence has to be a
    /// generation: notifications carrying an older generation are dropped instead of reviving
    /// state that a stop or restart already cleared.
    private var sessionGeneration = 0
    private let sessionLock = NSLock()

    /// Serializes segmenter mutation between queued capture processing and stop/start().
    private let segmenterLock = NSLock()

    private func currentSession() -> Int {
        sessionLock.lock()
        defer { sessionLock.unlock() }
        return sessionGeneration
    }

    /// Invalidates queued work from the previous session.
    @discardableResult
    private func beginNewSession() -> Int {
        sessionLock.lock()
        defer { sessionLock.unlock() }
        sessionGeneration += 1
        return sessionGeneration
    }

    /// Runs `body` on the main actor, preserving order with previously queued deliveries.
    ///
    /// Capture callbacks arrive on an audio thread; the consumers mutate published state that
    /// views read, so the transition must be applied where those are valid. Sequential hops keep
    /// a fault and the recovery that follows it in the order they were produced.
    private func deliverOnMain(session: Int? = nil, fenced: Bool = true, _ body: @escaping (VoiceAsrEngine) -> Void) {
        let generation = session ?? currentSession()
        deliveryQueueForTesting.async { [weak self] in
            guard let self else { return }
            guard fenced else {
                body(self)
                return
            }
            // Drop notifications produced by a session that has since been stopped or replaced:
            // otherwise a fault queued by the old session reappears after the restart's recovery
            // already cleared it. Main-queue delivery alone cannot order events produced on
            // different threads, so the session is what has to be compared.
            guard generation == self.currentSession() else {
                FileLog.shared.addMessage("[VoicePipeline] dropped stale session notification generation=\(generation) current=\(self.currentSession())")
                return
            }
            body(self)
        }
    }

    /// TEST seam: the main queue deliveries are posted to. Passing a queue whose blocks the
    /// control releases by hand lets it place a `stop`/`start` BETWEEN a delivery being
    /// enqueued and that delivery running — the real interleave, forced rather than hoped for.
    var deliveryQueueForTesting: DispatchQueue = .main

    /// The single recovery-delivery path, shared by the silence boundary and an explicit stop.
    ///
    /// Delivered WITHOUT a session fence: recovery reports that the fault state is gone, not work
    /// owned by a capture session, and a restart bumping the generation after this is queued must
    /// not suppress it — `stop` sees `isStuckActive == false` once silence already cleared it and
    /// would queue no replacement, leaving the interruption presented forever.
    ///
    /// Because it is unfenced, it must not clear a NEWER fault. That state is read under
    /// `segmenterLock`, the same lock capture processing mutates it under: reading it unlocked on
    /// the delivery queue is a data race with the audio thread.
    private func queueRecoveryNotification() {
        deliverOnMain(fenced: false) { [weak self] engine in
            guard let self else { return }
            self.segmenterLock.lock()
            let stillFaulted = self.segmenter.isStuckActive
            self.segmenterLock.unlock()
            guard !stillFaulted else {
                FileLog.shared.addMessage("[VoicePipeline] recovery dropped: a newer fault is active")
                return
            }
            engine.onSegmentationFaultRecovered?()
        }
    }

    /// TEST seam: installs the capture/segmenter callbacks without opening the microphone, so a
    /// control can prove a fault reaches an observer through the engine's own forwarding.
    func installCaptureCallbacksForTesting() {
        wireCaptureCallbacks()
    }

    /// Single definition of the capture wiring, so the fault forwarding cannot exist on one path
    /// and be missing on another.
    private func wireCaptureCallbacks() {
        segmenter.onUtterance = { [weak self] utterance, capturedAt, earlyWakeResult in
            guard let self else { return }
            // Fenced as well as the notifications: an utterance emitted from a stopped session
            // is stale PCM, and suppressing only its UI event would still let that audio reach
            // ASR and change the next turn.
            let session = self.segmenter.currentSession ?? self.currentSession()
            guard session == self.currentSession() else {
                FileLog.shared.addMessage("[VoicePipeline] dropped utterance from stale session=\(session) current=\(self.currentSession())")
                return
            }
            let frozen = self.contributionCollector?.currentCaptureContext()
            self.contributionCollector?.segmentationEnded(frozen)
            Task { [weak self] in
                guard let self else { return }
                // Re-check when the task actually runs: a stop can land between enqueue and
                // execution, and the check above only proves the session was valid then.
                guard session == self.currentSession() else {
                    FileLog.shared.addMessage("[VoicePipeline] dropped utterance queued before a session change session=\(session) current=\(self.currentSession())")
                    return
                }
                self.utteranceBodyGateForTesting?()
                await self.processUtterance(
                    utterance,
                    capturedAt: capturedAt,
                    frozenContext: frozen,
                    earlyWakeResult: self.segmenter.earlyWakeResultForCurrentUtterance
                )
            }
        }
        segmenter.onSpeechStarted = { [weak self] count in
            // PHASE 2 (name schema v1): freeze the REAL grace state at segment start — this closure
            // runs on the segmenter's start delivery, before any mode change, so the value is the
            // state the speech actually began under. Wake-word mode without grace requires the wake
            // word; anything else (grace window active, continuous mode) does not.
            guard let self else { return }
            // NO-COLLECTOR observability: every capture call site is
            // `contributionCollector?.…`, so a nil reference skips collection with NO log line —
            // indistinguishable from a detector that never ran. The reference is a plain optional
            // assigned once inside `buildVoiceControlService` (VoiceControlAssembly.swift), so nil
            // is unreachable in a live process; if that reading is ever wrong, this is the line
            // that says so. Counted separately from segments seen, because a segment that
            // completes with no collector was never seen by one.
            guard let collector = contributionCollector else {
                self.noteSegmentWithoutCollector()
                return
            }
            let wakeRequired = listeningMode == .wakeWord && !gracePeriodSignal.isActive
            collector.speechStarted(confirmationFrameSamples: count, wakeRequired: wakeRequired)
        }
        segmenter.onSpeechAccumulated = { [weak self] samples, total in
            self?.contributionCollector?.appendSamples(samples, reportedTotal: total)
        }
        segmenter.onSpeechCancelled = { [weak self] in self?.contributionCollector?.speechCancelled() }
        // Early wake scoring: score the eligible prefix while the user is still speaking, so the
        // decision does not wait for the endpoint.
        //
        // The result is held and consumed by the turn this utterance closes. It is deliberately
        // keyed to the utterance in flight: a result left over from an earlier utterance would
        // address a command using audio that is not that command's.
        segmenter.onWakeScorablePrefix = { [weak self] prefix in
            guard let self else { return }
            let session = self.segmenter.currentSession ?? self.currentSession()
            guard session == self.currentSession() else {
                FileLog.shared.addMessage("[VoicePipeline] dropped early wake prefix from stale session=\(session) current=\(self.currentSession())")
                return
            }
            let result = self.wakeWordDetector.detect(samples: prefix, sampleRate: 16000)
            // Handed to the segmenter, which delivers it with the utterance it belongs to. Keeping
            // it here until a later task read it is what let one utterance's score address another.
            self.segmenter.earlyWakeResultForCurrentUtterance = result
            FileLog.shared.addMessage("[VoicePipeline] wake scored early over \(prefix.count) samples")
            // No open here: this callback runs in the SPEECH branch, so by the time a prefix is
            // complete the utterance is still being spoken and no silence has begun. The
            // short-utterance case — no prefix at all — is handled at the gate's forward verdict.
        }
        // Trailing silence on an ADDRESSED utterance: the user appears to have finished, so the
        // connection that the coming turn will need can be opened now. The segmenter reports the
        // silence; whether the utterance is addressed is this engine's judgement, made from the
        // early wake score it already holds.
        segmenter.onTrailingSilenceBegan = { [weak self] in
            guard let self else { return }
            let session = self.segmenter.currentSession ?? self.currentSession()
            guard session == self.currentSession() else { return }
            // When the score is already held, it decides; when it is not (a short utterance with
            // no early prefix), grace alone can still make the utterance routable, and the late
            // result path opens if the score arrives before the silence ends.
            self.openEarlyConnectionIfRoutableDuringTrailingSilence(
                result: self.segmenter.earlyWakeResultForCurrentUtterance
            )
        }
        // Segmentation faults are forwarded so the interruption is observable outside this
        // component. A private flag would leave the user with unexplained silence.
        segmenter.onStuckActiveFault = { [weak self] fault in
            guard let self else { return }
            self.contributionCollector?.speechCancelled()
            // Attribute the fault to the session whose samples raised it, not to whatever session
            // happens to be current when the delivery runs.
            let session = self.segmenter.currentSession ?? self.currentSession()
            self.deliverOnMain(session: session) { engine in
                engine.onSegmentationFault?(SegmentationFault(
                    kind: .durationLimitReached,
                    discardedSamples: fault.discardedSamples,
                    elapsedMs: fault.elapsedMs,
                    reason: nil
                ))
            }
        }
        // These fire from capture processing on an audio thread, and their consumers mutate
        // published UI state. Hops are queued rather than dispatched synchronously so transitions
        // cannot interleave: a recovery announced while a fault is still being delivered would
        // otherwise clear the interruption before it was ever shown.
        segmenter.onRecoveredFromFault = { [weak self] in
            guard let self else { return }
            // Recovery is a statement about segmenter state, not work owned by a capture session,
            // so it is delivered UNFENCED. It must not be suppressible by an unrelated session
            // change: if a stop/restart lands while this is queued, it would be dropped and —
            // `isStuckActive` already being false — stop would queue no replacement, leaving the
            // interruption presented with nothing left to clear it.
            //
            // It is still delivered in order, and it must not report recovery over a NEWER fault:
            // if one was raised after this silence boundary, the interruption is real and stays.
            self.queueRecoveryNotification()
        }
        segmenter.onClassifierUnavailable = { [weak self] fault in
            self?.deliverOnMain { engine in
                engine.onSegmentationFault?(SegmentationFault(
                    kind: .classifierUnavailable,
                    discardedSamples: 0,
                    elapsedMs: 0,
                    reason: fault.reason
                ))
                engine.onClassifierUnavailable?(fault.reason)
            }
        }
        capture.onCapturedSamples = { [weak self] samples, capturedAt, tapSession in
            guard let self else { return }
            // Ownership is the session carried WITH the buffer — stamped when the tap was
            // installed — never the session current at delivery.
            // Segmenter mutation is serialized against start's wiring and stop's reset, which
            // run on other threads. Without this the two would interleave and stale PCM could
            // change the next utterance even though its notification was suppressed.
            self.segmenterLock.lock()
            defer { self.segmenterLock.unlock() }
            guard tapSession == self.currentSession() else {
                FileLog.shared.addMessage("[VoicePipeline] dropped capture buffer from stale tap session=\(tapSession) current=\(self.currentSession())")
                return
            }
            self.segmenter.process(samples, capturedAt: capturedAt, session: tapSession)
        }
    }

    /// Starts capture and returns whether it actually started. Capture errors
    /// are reported rather than swallowed: the caller must not treat a failed
    /// start as listening, and must release any acquired input route.
    @discardableResult
    func start() -> Bool {
        contributionCollector?.pipelineStarting()
        FileLog.shared.addMessage("[VoicePipeline] engine starting backend=\(backend.requiredModel.id)")
        // The new session must exist before callbacks are installed: installing them replays
        // current state (a missing classifier) through the delivery fence, and a replay tagged
        // with the previous generation would be dropped as stale — losing the very fault that
        // explains why capture is about to be refused.
        // The tap is stamped with the value `beginNewSession` RETURNED: re-reading the property
        // here would race a concurrent stop and could stamp the tap with a superseded session.
        let session = beginNewSession()
        capture.tapSession = session
        // Mutates the segmenter (installs callbacks, replays state), so it is serialized against
        // capture processing and stop on other threads.
        segmenterLock.lock()
        wireCaptureCallbacks()
        segmenterLock.unlock()

        // Never present a pipeline that cannot segment. Without a classifier there is no
        // trustworthy endpoint, so opening the microphone would capture audio the engine can
        // never close into an utterance — listening that looks active and can never work.
        if segmenter.isClassifierUnavailable {
            FileLog.shared.addMessage("[VoicePipeline] engine start refused: no speech classifier; capture not opened")
            return false
        }

        preloadBackend()

        do {
            try capture.start()
            FileLog.shared.addMessage("[VoicePipeline] engine started mode=\(listeningMode)")
            return true
        } catch {
            FileLog.shared.addMessage("[VoicePipeline] engine start failed: \(error)")
            // Clean up a partially started capture (configure succeeded, engine
            // start failed) so teardown still restores the playback category
            // and releases a session capture owned.
            capture.stop()
            return false
        }
    }

    func stop() {
        FileLog.shared.addMessage("[VoicePipeline] engine stopped")
        capture.stop()
        beginNewSession()
        // Clearing the segmenter races queued capture processing on another thread; serialize
        // against it so a stale buffer cannot mutate the segmenter while it is being reset.
        segmenterLock.lock()
        defer { segmenterLock.unlock() }
        // An explicit stop is the advertised escape from a surfaced fault, so the faulty state
        // must not survive it. Routine frames never clear it — only this deliberate restart and a
        // genuine silence boundary do, so the tail of a still-spoken request cannot be dispatched.
        if segmenter.isStuckActive {
            FileLog.shared.addMessage("[VoicePipeline] explicit stop clearing the fault state")
            segmenter.clearStuckActiveFault()
            queueRecoveryNotification()
        }
        // Reset all remaining segmentation state at the boundary. A partially buffered utterance
        // is not a fault, so the block above does not cover it; leaving it in place would
        // concatenate old-session PCM with the new session's and dispatch them as one command.
        segmenter.resetForNewSession()
        contributionCollector?.pipelineStopped()
    }

    /// Test seam: the capture→segmenter closure installed by `start`. Reading it proves the production
    /// wiring exists without needing a live audio session; production callers use `start` itself.
    var captureCallbackForTesting: (([Float]) -> Void)? {
        capture.onCapturedSamples.map { callback in { [weak self] samples in
            guard let self else { return }
            callback(samples, nil, self.currentSession())
        } }
    }

    /// Test seam: the route condition the bleed branch reads. Production derives it from the audio route;
    /// forcing it here lets the branch be exercised without a simulator-wide route change.
    var isExposedSpeakerRouteForTesting: Bool {
        get { echoFilterRoute.appliesCorrelationWindow }
        set { echoFilterRoute = newValue ? .builtInSpeaker : .external }
    }

    /// Exposed for focused translate-drop tests (`@testable`).
    /// Entry point for one segmented utterance. The capture identity is frozen SYNCHRONOUSLY here — before
    /// the Task exists — so a queued-but-not-yet-running utterance A keeps A's identity even if B starts and
    /// opens its own capture before A's body ever runs. Reading "what is current" inside the async body would
    /// hand A's audio to B.
    /// `taskBodyGate`, when provided (tests only), runs as the Task body's first statement — after the
    /// freeze, so tests can hold the body back and mutate collector state in between deterministically.
    /// Test-only body gate used by the PRODUCTION closure path too, so the start-installed
    /// `onUtterance` closure can be held mid-flight deterministically (nil in production).
    var utteranceBodyGateForTesting: (() -> Void)?

    func beginUtteranceProcessing(_ utterance: [Float], taskBodyGate: (() -> Void)? = nil) -> Task<Void, Never> {
        let frozenContext = contributionCollector?.currentCaptureContext()
        return beginUtteranceProcessing(utterance, preFrozenContext: frozenContext, taskBodyGate: taskBodyGate)
    }

    /// Outcome launch for a context ALREADY frozen synchronously (production onUtterance path).
    func beginUtteranceProcessing(_ utterance: [Float], preFrozenContext: VoiceSharingCollector.CaptureContext?, taskBodyGate: (() -> Void)? = nil) -> Task<Void, Never> {
        let bodyGate = taskBodyGate ?? utteranceBodyGateForTesting
        return Task {
            bodyGate?()
            await self.processUtterance(utterance, frozenContext: preFrozenContext)
        }
    }

    /// `frozenContext` is captured by the synchronous `onUtterance` closure before this Task was created.
    /// `processUtterance` itself must not read "current" state: by the time an async body runs, a successor
    /// may have started.
    /// The context frozen for the most recent utterance — what the service's routing/execution decision
    /// sites attribute their observations to. Test-visible so a control can report against the same capture.
    private(set) var lastUtteranceContextForTesting: VoiceSharingCollector.CaptureContext?

    func processUtterance(_ utterance: [Float], capturedAt: MonotonicTime? = nil, frozenContext: VoiceSharingCollector.CaptureContext? = nil, earlyWakeResult: WakeWordResult? = nil) async {
        // The early result ARRIVED with this utterance, so it cannot belong to another by
        // construction. Every exit below simply stops using it.
        let earlyResult = earlyWakeResult
        stageTimer.mark() // VAD segment ready
        // ONE identity from admission: the utterance is admitted HERE, so its
        // identity is minted here — not rebuilt later. Retries/duplicates that re-emit the SAME
        // capture carry this id; an independent utterance has its own. It flows unchanged through
        // trimming, router diagnostics, the prepared wire request_id and server diagnostics.
        let utteranceId = utteranceIdGeneratorForTesting?() ?? UUID().uuidString
        FileLog.shared.addMessage("[VoicePipeline] utterance admitted id=\(utteranceId)")

        if echoFilterRoute.appliesCorrelationWindow {
            // ONE consistent observation: samples, offset and anchor
            // come from a single lock acquisition, so the offset always describes exactly the
            // samples the mic segment is correlated against — an append landing between two
            // separate reads can no longer shift the window out from under the offset.
            let observation = echoReference?.consistentObservation()
            // TEST-only boundary hook: fires after the observation is
            // taken and before the filter call, so a control can force an append/anchor advance
            // into the exact window a split-read regression would read across — deterministically,
            // no timing. Nil in production.
            echoObservationTakenForTesting?()
            let segmentEndOffset = playbackEndOffsetForSegment(
                capturedAt: capturedAt,
                segmentSamples: utterance.count,
                observation: observation)
            if signalFilter.isPlaybackBleed(
                mic: utterance,
                reference: observation?.samples ?? [],
                segmentEndOffset: segmentEndOffset) {
                // THE detector ran and returned A VERDICT: the bleed stage is
                // `completed` with `decision: overlap` and NO reason, because that is what actually
                // happened. An earlier version of this fix used `unknown`/`no_playback_reference`,
                // which passes the deployed schema's membership check but asserts the OPPOSITE of
                // the observed fact — "there was no reference" when the detector had just consulted
                // one. A well-formed record that misstates an observation is worse than a rejected
                // one, because it enters the dataset looking clean. The original
                // "playback_bleed" was in neither enumeration nor the deployed schema
                // (`record_schema.ts:93`), so every bleed rejection failed validation and vanished.
                // Why recognition did not run is carried separately, on the ASR stage, as
                // `not_run`/`rejected_by_bleed`.
                contributionCollector?.engineReported(stage: "bleed", outcome: .init(state: "completed", reason: nil), context: utteranceContext, decision: "overlap")
                contributionCollector?.segmentRejected(kind: .rejectedBleed, samples: utterance.count, context: utteranceContext)
                FileLog.shared.addMessage("[VoicePipeline] → drop (bleed filter)")
                return
            }
        }

        // ENGINE-PRODUCED observation: reaching here means the bleed filter produced a
        // verdict for this capture. When the reference is not exposed the filter is not consulted at all,
        // which is not a verdict — that case stays `unknown`/`no_playback_reference` from the caller.
        if echoFilterRoute.appliesCorrelationWindow {
            contributionCollector?.engineReported(
                stage: "bleed",
                outcome: .init(state: "completed", reason: nil),
                context: utteranceContext, decision: "no_overlap")
        }

        // The detector observes every segment in both listening modes.
        //
        // If the eligible prefix was already scored while the user was still speaking, that score
        // is definitive: no window past the prefix can change the maximum, so re-running on the
        // finished segment would cost the same latency the early scoring exists to remove and
        // could not change the answer. A short utterance has no early result and is scored here.
        //
        // Consumed at the TOP of the turn, not here. The bleed filter above can return before this
        // line, and a score left behind by a dropped utterance would then address the next one
        // using this utterance's audio — a wrong command rather than a missing one.
        let result: WakeWordResult
        if let earlyResult {
            result = earlyResult
            FileLog.shared.addMessage("[VoicePipeline] wake used early result")
        } else {
            result = wakeWordDetector.detect(samples: utterance, sampleRate: 16000) { [weak contributionCollector] identity in
                contributionCollector?.engineUsedModel(slot: "wakeword", reference: identity, context: utteranceContext)
            }
        }
        stageTimer.mark() // wake result

        let score = wakeScore(of: result)
        // PHASE 2 (name schema v1): whenever the detector ran it MEASURED a score against a threshold,
        // and the record must carry both values rather than `na`. A detector error measured nothing,
        // so the pair stays nil there.
        let measuredWake: (score: Double, threshold: Double)? = score.map { (Double($0), Double(wakeThreshold)) }
        let wakeCmp: String = {
            guard let score else { return "error" }
            let op = score >= wakeThreshold ? ">=" : "<"
            return "\(String(format: "%.3f", score)) \(op) \(String(format: "%.3f", wakeThreshold))"
        }()

        let detectedConfidence: Float?
        let completionSample: Int
        // What SELECTED this utterance, captured from the gate's own decision. A detected wake
        // is a new conversation even during grace; a non-detected pass is a follow-up continuing
        // the current one. Read from live `isActive` instead, the two are identical — both arrive
        // with grace active — so the distinction has to come from here, where it is actually made.
        let selection: CloudConversationSelection
        switch WakeGate.decide(result: result, listeningMode: listeningMode, graceActive: gracePeriodSignal.isActive) {
        case .discardProcessing(let errorCode):
            FileLog.shared.addMessage("[VoicePipeline] wake error \(errorCode) → drop")
            // ENGINE-PRODUCED observation: the DETECTOR failed for this capture — a real
            // observed error, reported from the site that made the decision.
            contributionCollector?.engineReported(
                stage: "wake",
                outcome: .init(state: "failed", reason: "detector_error"),
                context: utteranceContext)
            contributionCollector?.segmentRejected(kind: .rejectedWake, samples: utterance.count, context: utteranceContext)
            return
        case .dropUtterance:
            FileLog.shared.addMessage("[VoicePipeline] wake \(wakeCmp) → drop (no grace)")
            // Wake-negative: collectable audio. Notifying here adds NO ASR/router/action work — the very
            // next statement returns, and nothing downstream runs for this segment either way.
            // ENGINE-PRODUCED observation: the detector RAN and reported no wake for
            // this segment — reported from the decision site, never inferred from receiving frames.
            // An OBSERVED negative is still `completed`: the detector ran and gave a verdict. The
            // verdict lives in the DECISION field, because a completed stage carries no reason
            // emitting the reason here would be refused by the binding and the
            // capture would vanish instead of being recorded as a real no-wake observation.
            contributionCollector?.engineReported(
                stage: "wake",
                outcome: .init(state: "completed", reason: nil, decision: "rejected",
                               score: measuredWake?.score, threshold: measuredWake?.threshold),
                context: utteranceContext)
            contributionCollector?.segmentRejected(kind: .rejectedWake, samples: utterance.count, context: utteranceContext)
            return
        case .forward(let detected):
            // ENGINE-PRODUCED observation: the wake decision below is made HERE, by
            // the detector, so this is the only place entitled to report the wake stage.
            // The detector RAN and returned a verdict either way. A forwarded NEGATIVE segment in
            // grace/continuous mode observed `no_wake_detected` exactly as a dropped one did, so the
            // same outcome must be reported here — dropping it would lose a real observation
            // .
            contributionCollector?.engineReported(
                stage: "wake",
                outcome: .init(
                    state: "completed", reason: nil,
                    // SERVER schema (record_schema.ts validateWake): the decision enum is
                    // {detected, rejected} and a COMPLETED wake stage must carry one — the
                    // server files a decision-less completed wake under request/ as if no
                    // wake decision was made (spec GO review, fixture refusal nov07). A
                    // completed stage carries no reason, so the verdict
                    // lives in decision under the schema's own values, detected included.
                    decision: detected ? "detected" : "rejected",
                    score: measuredWake?.score, threshold: measuredWake?.threshold),
                context: utteranceContext)
            // The utterance is routable. If it had no early result — a short utterance, which never
            // reaches the eligible span — this is where its positive verdict first becomes known,
            // and it is still before the backend wait, so opening here is the only point that can
            // still save the handshake. `earlyResult == nil` distinguishes exactly the case that
            // was not already opened at silence onset; an early-scored utterance opened there.
            if earlyResult == nil {
                FileLog.shared.addMessage("[VoicePipeline] short utterance routable — opening early connection before ASR")
                onAddressedTrailingSilenceBegan?()
            }
            if detected {
                onWakeWordDetected?()
                detectedConfidence = confidence(of: result)
                completionSample = self.completionSample(of: result)
                selection = .wakeWord
                FileLog.shared.addMessage("[VoicePipeline] wake \(wakeCmp) → ASR (hit, mode=\(listeningMode))")
            } else {
                detectedConfidence = nil
                completionSample = 0
                selection = .followUp
                FileLog.shared.addMessage("[VoicePipeline] wake \(wakeCmp) → ASR (grace/continuous)")
            }
        }

        guard !utterance.isEmpty else { return }
        // THIS turn is admitted: its window origin is settled (the wake decision above opened the
        // window for a wake-selected turn), and recognition has not begun. Recording it here is
        // what keeps it eligible if the deadline passes during the backend wait. A discarded
        // capture (bleed, no grace, wake error) has already returned, so it cannot gain
        // eligibility; an empty utterance is excluded by the guard above.
        let admittedOrigin = gracePeriodSignal.currentGeneration()
        onTurnAdmitted?(utteranceId, admittedOrigin)
        // The reservation is owned for exactly as long as this turn is in the engine. Every exit
        // below — backend failure, wake-only, empty/non-content transcript, translation failure,
        // cancellation — passes through this defer and releases it. The routing path sets the flag
        // to transfer ownership to the chain instead, which then releases on its own terminal
        // outcome. Without this, an early return leaves the reservation permanently in flight.
        var admissionHandedToRouting = false
        defer {
            if !admissionHandedToRouting { onTurnReleased?(utteranceId) }
        }
        let ready: Result<Void, Error>
        backendReadyLock.lock()
        let cachedReadyTask = backendReadyBox.task
        backendReadyLock.unlock()
        if let cachedReadyTask {
            let waitStarted = Date()
            ready = await cachedReadyTask.value
            let waitMs = Int(Date().timeIntervalSince(waitStarted) * 1000)
            if waitMs > 50 {
                FileLog.shared.addMessage("[VoicePipeline] asr waited \(waitMs)ms for backend")
            }
        } else {
            ready = await backend.ensureReady()
        }
        if case .failure(let error) = ready {
            FileLog.shared.addMessage("[VoicePipeline] → drop (backend not ready: \(error))")
            // ENGINE-PRODUCED observation: the recogniser could not be started, so this
            // capture's ASR genuinely failed — a real observed failure, not an unobserved stage.
            contributionCollector?.engineReported(
                stage: "asr",
                outcome: .init(state: "failed", reason: "provider_error"),
                context: utteranceContext)
            contributionCollector?.finalizeDeferredCompletion(context: utteranceContext)
            return
        }
        stageTimer.mark() // ASR start
        let asrStartedAt = Date()
        let asrResult = await backend.transcribe(samples: utterance, sampleRateHz: 16000) { [weak contributionCollector] identity, translates in
            contributionCollector?.engineUsedModel(slot: "asr", reference: identity, context: utteranceContext)
            if translates {
                contributionCollector?.engineUsedModel(slot: "translation", reference: identity, context: utteranceContext)
            }
        }
        let asrMs = Int(Date().timeIntervalSince(asrStartedAt) * 1000)
        stageTimer.mark() // ASR result
        emitStageTiming(detectedConfidence: detectedConfidence)

        let isWakePositive = detectedConfidence != nil
        let trimmedText = WakeTranscriptTrimmer.commandText(
            result: asrResult,
            wakePositive: isWakePositive,
            completionSample: completionSample,
            sampleRateHz: 16000,
            samples: utterance
        )
        let trimNote: String? = {
            guard isWakePositive, asrResult.text != trimmedText else { return nil }
            return "trim[ut=\(utteranceId)] '\(asrResult.text)' → '\(trimmedText)'"
        }()

        // ENGINE-PRODUCED observation: the ASR stage states the RECOGNISER'S OWN result,
        // and nothing else. A wake-only capture is a SUCCESSFUL recognition whose text happens to be just
        // the wake phrase — removing that phrase is the COMMAND input's job, downstream, not an ASR
        // failure and not a wake rejection. So the raw transcript is published as completed.
        let rawText = asrResult.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !rawText.isEmpty {
            // The language is the RECOGNISER'S OWN observation and router_input is the exact text
            // handed onward as the command input (: existing schema fields, stated by
            // the site that produced them). `empty_result` never carries either member.
            // NON-CONTENT: a transcript
            // with no letter or number is discarded below, before translation, the router, or any cloud
            // work — so NO command input was ever produced. Reporting `router_input` here claimed a
            // command that never proceeded; a reader of the record would see "?!" as the input to a
            // router that was never called. `text` still carries what the recogniser heard, which is the
            // ASR stage's own result; the command input is absent because there was none.
            let commandInput: String? = Self.isNonContent(trimmedText)
                ? nil
                : (trimmedText.isEmpty ? rawText : trimmedText)
            contributionCollector?.engineReported(
                stage: "asr",
                outcome: .init(state: "completed", reason: nil, text: rawText,
                               sourceLanguage: asrResult.detectedLanguage,
                               routerInput: commandInput),
                context: utteranceContext)
        } else {
            // A GENUINELY empty recogniser result is a SUCCESSFUL recognition with nothing usable in it
            // `completed` carrying `empty_result`, with no text and no router
            // input. It is not `not_run` — the recogniser did run — and not `provider_error` — nothing
            // failed. The binding enforces exactly this pairing on every path.
            //
            // The LANGUAGE survives an empty transcript. An empty result means "it
            // heard speech and recognised nothing", which is a different fact from "it could not tell
            // what language was spoken" — and cleanly distinguishes silence-shaped output in a language
            // that transcribes confidently empty from one whose recogniser never engaged. Dropping it
            // here would make an empty transcript indistinguishable from an unknown language.
            contributionCollector?.engineReported(
                stage: "asr",
                outcome: .init(state: "completed", reason: VoiceSharingContributionEncoder.emptyResultReason,
                               sourceLanguage: asrResult.detectedLanguage),
                context: utteranceContext)
        }

        if trimmedText.isEmpty {
            let reason = isWakePositive ? "wake-only" : "empty"
            FileLog.shared.addMessage(
                "[VoicePipeline] asr \(backend.requiredModel.id) \(asrMs)ms ut=\(utteranceId) lang=\(asrResult.detectedLanguage ?? "?") '\(asrResult.text)'\(trimNote.map { " \($0)" } ?? "") → drop (\(reason))"
            )
            if isWakePositive {
                onWakeOnly?()
            }
            contributionCollector?.finalizeDeferredCompletion(context: utteranceContext)
            return
        }

        // NON-CONTENT OUTPUT (task #78, spec 77eacc9b): a transcript with NO Unicode letter or
        // number carries no command — whitespace-only, punctuation-only, or any other non-content
        // the recogniser returns. It is discarded SILENTLY, before translation, the router, the
        // dialog, or any cloud work. No minimum length: a short MEANINGFUL utterance ("yes", "停",
        // "嗯", digits, text-with-punctuation) contains a letter or number and survives; only text
        // with neither is rejected. Silence is correct here — the user said nothing a machine can
        // act on, so it must not consume a dialog, speak an error, or extend grace.
        if Self.isNonContent(trimmedText) {
            FileLog.shared.addMessage(
                "[VoicePipeline] asr \(backend.requiredModel.id) \(asrMs)ms ut=\(utteranceId) lang=\(asrResult.detectedLanguage ?? "?") '\(trimmedText)'\(trimNote.map { " \($0)" } ?? "") → drop (non-content)"
            )
            return
        }

        // Translate to English when the ASR backend did not already translate and the
        // detected language is not English (the SenseVoice CJK path). Trim first so we
        // only translate the command remainder (matches Android).
        let trimmedResult = AsrResult(text: trimmedText, detectedLanguage: asrResult.detectedLanguage)
        let (finalized, translateNote) = await maybeTranslate(
            trimmedResult, backend: backend, context: utteranceContext)
        // Source-first: lang + first quote are ASR; translate note carries the English result.
        FileLog.shared.addMessage(
            "[VoicePipeline] asr \(backend.requiredModel.id) \(asrMs)ms ut=\(utteranceId) lang=\(trimmedResult.detectedLanguage ?? "?") '\(trimmedResult.text)'\(trimNote.map { " \($0)" } ?? "")\(translateNote.map { " \($0)" } ?? "")"
        )
        if Self.isNonEnglishTranslateFailure(translateNote) {
            // Don't feed untranslated CJK into the English-only intent model.
            FileLog.shared.addMessage("[VoicePipeline] → drop (\(translateNote ?? "translate"))")
            onUnroutable?()
            contributionCollector?.finalizeDeferredCompletion(context: utteranceContext)
            return
        }
        // OWNERSHIP transfer, CONDITIONAL on acceptance: only a router that actually took the
        // input will release the reservation on its terminal outcome. If it refuses — a late
        // completion after `stop`, say — nobody owns the turn, so the engine keeps ownership and
        // its `defer` releases. Transferring unconditionally would leak in exactly that case.
        let routingInput = Self.makeRoutingInput(
            source: trimmedResult,
            routerText: finalized.text,
            translateNote: translateNote,
            selection: selection,
            utteranceId: utteranceId
        )
        if onRoutingInputWithContext?(routingInput, utteranceContext) ?? false {
            admissionHandedToRouting = true
            captureHandedToRouting = true
        }
    }

    /// Builds the immutable envelope. Platform success keeps trimmed native source;
    /// backend translate omits source (Canary exposes English only).
    static func makeRoutingInput(
        source: AsrResult,
        routerText: String,
        translateNote: String?,
        selection: CloudConversationSelection? = nil,
        utteranceId: String
    ) -> IntentRoutingInput {
        if let translateNote, translateNote.hasPrefix("translate=skip(backend)") {
            return IntentRoutingInput(
                sourceTranscript: nil,
                sourceLanguage: source.detectedLanguage,
                routerTranscript: routerText,
                translationKind: .backend,
                selection: selection,
                utteranceId: utteranceId
            )
        }
        if let translateNote,
           translateNote.contains("→en"),
           translateNote.hasPrefix("translate=") {
            return IntentRoutingInput(
                sourceTranscript: source.text,
                sourceLanguage: source.detectedLanguage,
                routerTranscript: routerText,
                translationKind: .platform,
                selection: selection,
                utteranceId: utteranceId
            )
        }
        // NO FABRICATED language: an unknown LID stays nil on the input (and is omitted on the
        // wire) — defaulting to "en" mislabeled an undetected-language utterance as English.
        return IntentRoutingInput.english(
            transcript: routerText,
            language: source.detectedLanguage,
            selection: selection,
            utteranceId: utteranceId
        )
    }

    /// True when the text carries NO Unicode letter or number — i.e. no content a machine can
    /// act on (task #78, spec 77eacc9b). Uses Unicode character classes, so every script counts:
    /// CJK, Hangul, Arabic, digits in any script. Punctuation and whitespace alone do not qualify.
    /// Deliberately not a length rule: "yes", "停", "嗯" and "3" all pass.
    static func isNonContent(_ text: String) -> Bool {
        // Unicode general categories, not CharacterSet: the spec's rule is L (letters) and N
        // (numbers) — and `CharacterSet.decimalDigits` covers only Nd, which would silently
        // DISCARD other numbers such as "²" (No), "½" (No) and "Ⅻ" (Nl) though the shared rule
        // treats them as content (spec clarification + reviewer 68afef6f). Counting is over
        // CHARACTERS for letters (multi-scalar letters such as "Ǆ" carry one letter category).
        text.unicodeScalars.contains { scalar in
            let category = scalar.properties.generalCategory
            switch category {
            case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
                 .decimalNumber, .letterNumber, .otherNumber:
                return true
            default:
                return false
            }
        } == false
    }

    /// Android `isNonEnglishTranslateFailure` parity — fail / blank / noop / no-stage notes drop.
    static func isNonEnglishTranslateFailure(_ translateNote: String?) -> Bool {
        guard let translateNote else { return false }
        return translateNote.hasPrefix("translate=fail(")
            || translateNote.hasPrefix("translate=blank(")
            || translateNote.hasPrefix("translate=noop(")
            || translateNote.hasPrefix("translate=skip(no stage)")
    }

    private func wakeScore(of result: WakeWordResult) -> Float? {
        switch result {
        case .detected(let confidence, _): return confidence
        case .notDetected(let confidence): return confidence
        case .error: return nil
        }
    }

    private func confidence(of result: WakeWordResult) -> Float? {
        if case .detected(let confidence, _) = result { return confidence }
        return nil
    }

    private func completionSample(of result: WakeWordResult) -> Int {
        if case .detected(_, let completionSample) = result { return completionSample }
        return 0
    }

    /// Translates a non-English, non-self-translating ASR result to English before
    /// intent routing. Fail / blank / no-op notes are dropped by the caller (ERROR earcon).
    private func maybeTranslate(_ result: AsrResult, backend: AsrBackend, context: VoiceSharingCollector.CaptureContext?) async -> (AsrResult, String?) {
        func report(_ outcome: VoiceSharingContributionEncoder.StageOutcome) {
            contributionCollector?.engineReported(stage: "translation", outcome: outcome, context: context)
        }
        // BACKEND provenance first: a backend that translates to English has already produced the
        // English router text — including when it reported no language. Asking for a language id
        // before the backend capability mislabeled that translated-only output as original text.
        if backend.capabilities.canTranslateToEnglish {
            report(.init(state: "not_run", reason: "backend_handles_translation"))
            return (result, "translate=skip(backend)")
        }
        guard let detected = result.detectedLanguage?.lowercased() else {
            report(.init(state: "not_run", reason: "source_language_unavailable"))
            return (result, "translate=skip(no lang)")
        }
        if detected == "en" {
            // Nothing to translate: the source already is the target. This is the only true skip.
            report(.init(state: "not_run", reason: "source_language_target_language"))
            return (result, nil)
        }
        guard let translationStage else {
            // Missing platform translation is a hard failure for non-English SenseVoice text —
            // never relabel native text as english_v1.
            report(.init(state: "not_run", reason: "translator_unavailable"))
            return (result, "translate=skip(no stage)")
        }

        if case .failure = await translationStage.ensureReady(sourceLanguage: detected) {
            report(.init(state: "failed", reason: "provider_error"))
            return (result, "translate=fail(\(detected))")
        }
        let translated = await translationStage.translate(text: result.text, sourceLanguage: detected)
        guard !translated.isEmpty else {
            report(.init(state: "failed", reason: "provider_error"))
            return (result, "translate=blank(\(detected))")
        }
        // Reject no-op "translations" that would mislabel CJK as English.
        if translated == result.text {
            report(.init(state: "failed", reason: "provider_error"))
            return (result, "translate=noop(\(detected))")
        }
        // The owning schema already carries `translated_text` and `target_language`, so a successful
        // translation now states what it actually produced instead of only that it ran.
        report(.init(state: "completed", reason: nil,
                     translatedText: translated, targetLanguage: "en"))
        return (
            AsrResult(text: translated, detectedLanguage: "en"),
            "translate=\(detected)→en '\(translated)'"
        )
    }

    /// Computes and emits the per-utterance stage timings. `detectedConfidence`
    /// is the wake detector score for positive detections; nil otherwise.
    private func emitStageTiming(detectedConfidence: Float?) {
        let wakeResult = detectedConfidence.map { $0 >= wakeThreshold ? "detected" : "not_detected" }
        guard let timing = stageTimer.build(
            wakeResult: wakeResult ?? "not_detected",
            confidenceMargin: confidenceMargin(detectedConfidence),
            listeningMode: listeningMode == .continuous ? "continuous" : "wake_word",
            backend: backend.requiredModel.id
        ) else { return }
        onStageTiming?(timing)
        // The same measurements also go to the persisted log. Analytics needs a build to read back;
        // the log is what a person can inspect on a device after the fact, and a latency
        // investigation could not measure these stages at all when they existed only here.
        FileLog.shared.addMessage("[VoicePipeline] stages \(timing.logField)")
    }

    private func confidenceMargin(_ confidence: Float?) -> String? {
        guard let confidence, confidence >= wakeThreshold else { return nil }
        let margin = confidence - wakeThreshold
        if margin < 0.05 { return "near" }
        if margin < 0.20 { return "medium" }
        return "high"
    }

    /// Test seam: replaces the retained reference contents.
    ///
    /// Production code does not call this — producers append through the shared
    /// reference — so a test that relies on it is exercising the filter's logic, not
    /// the wiring. The wiring cases drive the real producers instead.
    func updatePlaybackBuffer(_ samples: [Float]) {
        guard let echoReference else { return }
        echoReference.invalidate()
        echoReference.append(samples)
        // Mirror the production rule that a reference without an observed render
        // position cannot be aligned: the seam supplies one so cases exercise the
        // aligned path rather than silently taking the unaligned branch.
        echoReference.recordRenderPosition(
            PlaybackRenderAnchor(
                renderedFrames: Double(samples.count),
                sourceSampleRate: PlaybackEchoReference.pipelineSampleRate,
                hostTime: 0
            )
        )
    }

    /// Sets the echo-filter scope for the current output route and retires the
    /// reference when the filter no longer applies, so stale state from a previous
    /// route cannot keep dropping audio after the route changes.
    func setEchoFilterRoute(_ route: EchoFilterRoute) {
        guard echoFilterRoute != route else { return }
        FileLog.shared.addMessage("[VoicePipeline] echoFilterRoute=\(route)")
        echoFilterRoute = route
        // Retire on every transition, in both directions. The retained audio belongs to
        // the outgoing route and is not an aligned reference for the incoming one —
        // including built-in → external *and* external → built-in, where audio captured
        // on the old path would otherwise be correlated against the new path's window.
        // The acoustic tail is kept rather than discarded, because audio already
        // submitted is still audible while the old path drains; clearing outright would
        // leave exactly that echo unfiltered during the handover.
        echoReference?.retire(retainingAcousticTail: Self.acousticTailSeconds)
    }
}
