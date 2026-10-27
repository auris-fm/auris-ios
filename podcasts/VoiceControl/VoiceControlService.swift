import AVFoundation
import Combine
import Foundation
import OSLog
import PocketCastsUtils

class VoiceControlService: ObservableObject {
    static weak var shared: VoiceControlService?

    @Published private(set) var isListening = false
    @Published private(set) var listeningMode: ListeningMode = .wakeWord
    @Published private(set) var gateState: GateState = .off(reason: .noContext)
    @Published private(set) var gatePosture = GatePosture(
        allowed: false, listeningMode: nil,
        setup: .allAllowed, conflicts: .noneBlocked,
        context: .none, micExposure: .noMic,
        gracePeriodActive: false, offReason: .noContext
    )

    private let conditionMonitor: LiveConditionMonitor
    private let routeMonitor: IOSAudioRouteMonitor
    private let interruptionHandler: AudioSessionInterruptionHandler
    private let asrEngine: VoiceAsrEngine
    private let wakeWordDetector: WakeWordDetectorProtocol
    private let intentRouter: LfmIntentRouter
    private let executor: VoiceIntentExecutor
    private let dialogManager: VoiceDialogManager
    private let audioRenderer: AudioFeedbackRenderer
    private let gracePeriodSignal: GracePeriodSignal

    /// The manager whose live origin follows the grace window. An EXPLICIT dependency rather than a
    /// reach-through to a test accessor: production must not depend on `…ForTesting` or a force-cast.
    private let liveOriginManager: CloudConversationManager

    /// The grace signal this service drives, so a test can observe a route change's effect
    /// through the service rather than through the assembly that built it.
    var gracePeriodSignalForTesting: GracePeriodSignal { gracePeriodSignal }

    /// The manager the service binds, for cases that assert the wake reaches its live origin.
    var liveOriginManagerForTesting: CloudConversationManager { liveOriginManager }

    /// The engine whose echo-filter route the assembly is responsible for keeping current.
    var asrEngineForTesting: VoiceAsrEngine { asrEngine }

    /// The monitor the assembly subscribes to in order to drive that route.
    var routeMonitorForTesting: IOSAudioRouteMonitor { routeMonitor }

    /// Drives the echo filter's scope from the observed output route.
    ///
    /// The monitor republishes on route changes, so invalidation is driven from the same
    /// signal that reports them. This is wired on the service, not in `VoiceControlAssembly`:
    /// `AppDelegate` constructs the assembly inline and keeps only the service, so a
    /// subscription stored in the assembly's `cancellables` is cancelled as soon as the build
    /// call returns and the engine keeps the classification it was built with for the life of
    /// the app. `@Published` delivers the current value at subscribe time, so construction
    /// alone is enough to establish the initial classification.
    /// Binds the manager's live origin to the grace window, owned by the SERVICE for the same
    /// reason `wireEchoFilterRoute` is: `AppDelegate` constructs the assembly inline and keeps only
    /// the service, so a subscription stored in the assembly's `cancellables` is cancelled as soon
    /// as the build call returns — the manager would then never learn a window opened, and every
    /// routed turn would be refused at the origin gate.
    private func wireLiveOriginBinding() {
        // The sink is main-actor-isolated, so reach its manager on the main actor.
        CloudConversationManager.bindLiveOrigin(to: gracePeriodSignal, on: liveOriginManager)
            .store(in: &cancellables)
        // The manager's prepare fence must admit a claimed-but-expired origin too, or the granted
        // claim is refused one step later at prepare.
        liveOriginManager.admittedWorkAuthority = { [weak gracePeriodSignal] in
            gracePeriodSignal?.admittedWorkAuthority
        }
        // Delayed state dies with its OWNER: when the last admitted turn of an origin releases,
        // that origin's conversation handle is dropped rather than waiting for a future wake.
        // The release reaches BOTH holders of delayed state, at the actual admitted-work release:
        // the manager drops the origin's conversation, and the sink drops the turn's nameable
        // record (tokens/waiters keep resolving; only nameability ends).
        // The release fires on the main thread (the signal's release is main-synchronized), so the
        // main-actor hop below runs synchronously there.
        gracePeriodSignal.onInFlightTurnReleased = { [weak liveOriginManager, weak self] utteranceId, origin in
            liveOriginManager?.releaseDelayedState(forOrigin: origin)
            if Thread.isMainThread {
                MainActor.assumeIsolated {
                    self?.executor.releaseRetainedAdmittedDispatch(utteranceId: utteranceId, origin: origin)
                }
            } else {
                DispatchQueue.main.sync {
                    self?.executor.releaseRetainedAdmittedDispatch(utteranceId: utteranceId, origin: origin)
                }
            }
        }
        // ONE coherent retention/retirement rule across preparation, dispatch and effects: the
        // sink's retained dispatch results (and effect claims) retire on the SAME window boundary
        // the manager's prepared requests do. Driven by the real window state, not a counter.
        // Retire atomically with the authoritative origin: the manager path is synchronous, so
        // the sink clear must be too — a queued MainActor Task would let a new-window
        // preparation/effect claim land before the clear and then be erased (reviewer a2723c92).
        // The signal publishes on the main thread, so the sink transition runs inline.
        // Retire atomically with the authoritative origin: the manager path is synchronous, so
        // the sink clear must be too. The signal publishes on the main thread, so the transition
        // runs inline — no queued hop that could let a new-window claim land first (a2723c92).
        // The sink retirement itself is nonisolated (lock-guarded), so it needs no actor hop.
        gracePeriodSignal.$isActive
            .sink { [weak self] active in
                guard let self else { return }
                let origin: Int? = active ? self.gracePeriodSignal.currentGeneration() : nil
                MainActor.assumeIsolated {
                    self.executor.retireRetainedDispatchesIfWindowChanged(to: origin)
                }
            }
            .store(in: &cancellables)
    }

    private func wireEchoFilterRoute() {
        routeMonitor.$currentRoute
            .map { VoiceAsrEngine.EchoFilterRoute.forOutput($0.output) }
            .removeDuplicates()
            .sink { [weak asrEngine] route in asrEngine?.setEchoFilterRoute(route) }
            .store(in: &cancellables)
    }

    /// The executor this service routes validated intents through.
    var executorForTesting: VoiceIntentExecutor { executor }

    /// The dialog manager, so a control can BEGIN a dialog through the production `handle` path
    /// and prove a dialog-pending turn keeps its OWN admitted identity on the wire (spec 0443b70).
    var dialogManagerForTesting: VoiceDialogManager { dialogManager }

    /// Whether the intent router has its model, so a test can wait for the real sequencing rather
    /// than dispatching into a router that is not ready and asserting about a dropped turn.
    var intentRouterIsReadyForTesting: Bool { intentRouter.isReady }
    private let analytics: VoiceAnalytics
    /// Whether the app is playing through the shared `AVAudioSession`. Used so a
    /// failed/cancelled acquisition never deactivates the session playback owns.
    /// `AVAudioSession` exposes no active-state query and the category is not an
    /// activity signal, so playback state is the reliable in-use signal.
    private let isPlaybackActive: () -> Bool

    /// Acknowledges that a queued input's routing attempt has FINISHED. See the initializer.
    private let onInputRoutingFinished: (@MainActor (IntentRoutingInput) -> Void)?

    /// What a test input barrier decided, reported before classification. `.arrived` is emitted when
    /// the barrier is REACHED; `.cancelled`/`.refused` when it stops the chain.
    enum InputBarrierOutcome: Sendable { case arrived, cancelled, refused }

    /// How a queued input's task TERMINATED. Reported on EVERY exit from the serial task, so a test
    /// can await settlement instead of polling for an absence: `.routed` when routing was attempted,
    /// `.cancelled`/`.refused` when the barrier stopped the chain, `.dropped` when the staleness guard
    /// (or a cancelled task) discarded it before reaching the barrier.
    enum InputTerminalOutcome: Sendable {
        case routed, barrierCancelled, barrierRefused, dropped
        /// This link handed its utterance to interruption settlement, which owns any subsequent
        /// submission or discard. The queued link ended before classification.
        case handedOffToFollowUpSubmission
        /// The predecessor's interruption could not be SETTLED (refused, or undeliverable), so this
        /// utterance was suppressed and nothing was submitted for it. Distinct from `.routed`,
        /// which claims the turn reached routing.
        case suppressedByInterruption
    }
    /// Reports how a queued input's task TERMINATED — on EVERY exit, including a refusal or a
    /// cancellation. This is the TERMINAL ACKNOWLEDGEMENT: the input returned, which is not the same
    /// as an action having run. Distinct from `onInputRoutingFinished`, which reports that routing was
    /// ATTEMPTED. Nil in production.
    private let onInputTerminal: (@Sendable (IntentRoutingInput, InputTerminalOutcome) -> Void)?

    /// Turns whose capture enqueued a CONTINUATION under its own identity (dialog `new_command`).
    /// The continuation carries the same admitted identity, so the reservation must survive this
    /// link's exit and be released by the continuation's own terminal outcome instead.
    private let continuationLock = NSLock()
    private var continuationEnqueuedForTurn: Set<String> = []

    /// Marks whether a capture enqueued a continuation under its own identity. Locked because the
    /// routing chain's `defer` is nonisolated and the chain itself is MainActor.
    private func markContinuationEnqueued(_ utteranceId: String) {
        continuationLock.lock(); continuationEnqueuedForTurn.insert(utteranceId); continuationLock.unlock()
    }

    /// Consumes the marker: true exactly once, for the link that handed ownership on.
    private func consumeContinuationEnqueued(_ utteranceId: String) -> Bool {
        continuationLock.lock()
        defer { continuationLock.unlock() }
        return continuationEnqueuedForTurn.remove(utteranceId) != nil
    }

    /// Awaited by the serial chain BEFORE an input is classified or executed, so a test can hold a
    /// specific input while the window state changes around it and then release it. Nil in
    /// production, where it is never set, so the chain is unmodified.
    private let testInputBarrier: (@Sendable (IntentRoutingInput) async throws -> Void)?
    /// Reports what the BARRIER decided for an input, before any classification: `.arrived`,
    /// `.cancelled`, or `.refused`. A test needs these as events distinct from routing completion —
    /// otherwise a cancelled or refused input is indistinguishable from one that simply routed and
    /// did nothing. Nil in production.
    private let onInputBarrierSettled: (@Sendable (IntentRoutingInput, InputBarrierOutcome) -> Void)?

    /// Live microphone exposure from the route monitor, for diagnostics and tests.
    var micExposure: MicExposure { routeMonitor.micExposure }

    private var latestStageTiming: PipelineStageTiming?

    /// The most recent segmentation fault, for diagnostics and any listener that renders the
    /// interruption. Nil while the pipeline is healthy.
    private(set) var latestSegmentationFault: VoiceAsrEngine.SegmentationFault?
    private var latestRouterMetrics: RouterClassificationMetrics?

    private var cancellables = Set<AnyCancellable>()
    /// Serializes classify+generate; locked so overlapping ASR callbacks cannot
    /// race the task-chain pointer. Bumped on `stop()` so earlier chained tasks
    /// (which cancellation does not reach through `await previous?.value`) bail
    /// before `handleTranscript`.
    private let transcriptLock = NSLock()
    private var transcriptSerialTask: Task<Void, Never>?
    private var transcriptEpoch: UInt64 = 0
    private var isStopping = false

    // Command debounce: skip intents of the same type within 2 seconds
    private var lastIntentType: String?
    private var lastExecutionTime: Date?
    private let debounceInterval: TimeInterval = 2.0

    /// `startIfAllowed` is invoked on every `applicationDidBecomeActive`. Arm
    /// gate subscriptions + LFM/ASR preload exactly once so we don't stack
    /// Combine sinks or race overlapping `ensureLfmModel` downloads.
    private var didArmLifecycle = false
    private var intentRouterReadyTask: Task<Void, Never>?

    /// Owns the mic lifecycle logging rules (event choice, severity, dedup).
    private let lifecycleLogger = MicLifecycleLogger(sink: OSLogMicLifecycleSink())

    /// Route-acquisition attempt. Cancelled when the gate stops requiring it;
    /// a late completion is discarded rather than starting capture.
    private var acquisitionTask: Task<Void, Never>?
    /// True while an acquisition is executing synchronously (including its
    /// exposure flip). The flip publishes synchronously through the gate sink,
    /// so the `.listening` branch must not cancel the task that produced it.
    private var isAcquiring = false
    /// Bumped on cancellation so a stale acquisition cannot apply its result.
    private var acquisitionGeneration: UInt64 = 0
    /// The route an acquisition was last attempted for. A failed acquisition must
    /// not be retried on every gate re-evaluation, but *is* retried when a
    /// different device presents the same route types (port UIDs differ) or when
    /// a later physical route-change notification re-presents the same device (a
    /// reconnect). See `IOSAudioRouteMonitor.acquisitionKey` for the retry
    /// contract and the epoch that carries it.
    private var acquisitionAttemptedRoute: AcquisitionRouteKey?
    /// External device whose capture start failed. Acquisition must not re-arm
    /// for this device until a genuine change (it disappears or a different
    /// candidate appears): releasing the preferred input reverts the live route
    /// to the built-in mic, which is not a device change and must not re-arm.
    private var captureStartFailedInputUID: String?
    /// Physical-device-change epoch recorded with [captureStartFailedInputUID]. The
    /// suppression is kept until a later physical change advances the epoch — a missing
    /// `availableInputs` on its own is ambiguous, because the `.playback` restore after a
    /// failed capture exposes no inputs even while the headset stays connected.
    private var captureStartFailedEpoch: UInt = 0

    init(
        conditionMonitor: LiveConditionMonitor,
        routeMonitor: IOSAudioRouteMonitor,
        interruptionHandler: AudioSessionInterruptionHandler,
        asrEngine: VoiceAsrEngine,
        wakeWordDetector: WakeWordDetectorProtocol,
        intentRouter: LfmIntentRouter,
        executor: VoiceIntentExecutor,
        dialogManager: VoiceDialogManager,
        audioRenderer: AudioFeedbackRenderer,
        gracePeriodSignal: GracePeriodSignal,
        liveOriginManager: CloudConversationManager,
        analytics: VoiceAnalytics,
        isPlaybackActive: @escaping () -> Bool = { PlaybackManager.shared.isAudioSessionInUse },
        /// Invoked when a queued input's routing attempt FINISHES — after it returns or is refused,
        /// and after its `defer` runs. An acknowledgement of COMPLETION, not of preparation: a
        /// preparation observer fires before routing completes and so cannot say whether the turn
        /// acted. Nil in production, where nothing needs to be told.
        onInputRoutingFinished: (@MainActor (IntentRoutingInput) -> Void)? = nil,
        testInputBarrier: (@Sendable (IntentRoutingInput) async throws -> Void)? = nil,
        onInputBarrierSettled: (@Sendable (IntentRoutingInput, InputBarrierOutcome) -> Void)? = nil,
        onInputTerminal: (@Sendable (IntentRoutingInput, InputTerminalOutcome) -> Void)? = nil,
        parsedIntentObserverFactory: (@Sendable (IntentRoutingInput) -> ParsedIntentObserver?)? = nil,
        /// Reports the conversation identity PREPARED for a dispatch. Invocation local and carried
        /// on the call, like `parsedIntentObserverFactory`: a sink-wide slot would let an
        /// overlapping dispatch overwrite another's observation, so the assertion could be made
        /// against the wrong turn.
        preparedObserverFactory: (@Sendable (IntentRoutingInput) -> CloudRouteSink.PreparedObserver?)? = nil
    ) {
        self.conditionMonitor = conditionMonitor
        self.routeMonitor = routeMonitor
        self.interruptionHandler = interruptionHandler
        self.asrEngine = asrEngine
        self.wakeWordDetector = wakeWordDetector
        self.intentRouter = intentRouter
        self.executor = executor
        self.dialogManager = dialogManager
        self.audioRenderer = audioRenderer
        self.gracePeriodSignal = gracePeriodSignal
        self.liveOriginManager = liveOriginManager
        self.analytics = analytics
        self.isPlaybackActive = isPlaybackActive
        self.onInputRoutingFinished = onInputRoutingFinished
        self.onInputBarrierSettled = onInputBarrierSettled
        self.onInputTerminal = onInputTerminal
        self.parsedIntentObserverFactory = parsedIntentObserverFactory
        self.preparedObserverFactory = preparedObserverFactory
        self.testInputBarrier = testInputBarrier

        interruptionHandler.onInterruptionBegan = { [weak self] in
            guard let self else { return }
            let wasCapturing = self.isListening
            self.stop()  // stops capture, discards current pipeline state
            if wasCapturing {
                // Audio session reclaimed by the system — an active-capture stop
                // that the user did not request → ERROR per the mic lifecycle spec.
                self.lifecycleLogger.runtimeCaptureStopped(
                    reason: "audio_session_reclaimed",
                    posture: self.gatePosture,
                    route: self.routeDescription()
                )
            }
        }

        interruptionHandler.onInterruptionEnded = { [weak self] in
            // Reactivate audio session
            try? AVAudioSession.sharedInstance().setActive(true)
            // Gate will recompute the mode via CombineLatest4 — no explicit restart needed
        }

        // Wired at construction, not at start: a route change before the first
        // `startIfAllowed()` is still a route change, and the filter must not keep classifying
        // against the route it was built with. See the lifetime note on the helper.
        wireEchoFilterRoute()
        // Same lifetime reasoning: the manager must learn about windows for as long as the service
        // lives, not only until the assembly's build call returns.
        wireLiveOriginBinding()
    }

    func startIfAllowed() {
        // Invoked on every `applicationDidBecomeActive` — arm once only.
        guard !didArmLifecycle else { return }
        didArmLifecycle = true

        // Kick SenseVoice/Canary download+init here (not at assembly) so we only
        // pay cellular/memory once voice control is actually being armed.
        // start() reuses the same task via preloadBackend()'s nil guard.
        asrEngine.preloadBackend()

        // Include grace `$isActive` so mode flips wakeWord ↔ continuous when the
        // 30s timer starts or expires (CombineLatest4 alone never saw that change).
        Publishers.CombineLatest(
            Publishers.CombineLatest4(
                conditionMonitor.$setup,
                conditionMonitor.$conflicts,
                conditionMonitor.$context,
                routeMonitor.$micExposure
            ),
            gracePeriodSignal.$isActive
        )
        // Pass the published Bool through — do not re-read the signal inside the
        // gate (that raced with log-before-assign and inverted wakeWord/continuous).
        .map { [weak routeMonitor] tuple, graceActive in
            let (setup, conflicts, context, exposure) = tuple
            return VoiceControlGate(
                setup: setup,
                conflicts: conflicts,
                context: context,
                micExposure: exposure,
                gracePeriodActive: graceActive,
                // Debug simulator only; `false` everywhere else by construction.
                admitsBuiltInMicForSimulatorDiagnostic: DiagnosticMicOverride.isActive,
                // Only ever consulted when the diagnostic is active; a real external microphone
                // always keeps the original requirement.
                // READ AT DECISION TIME, not cached at arm time (regression caught by
                // testBargeInReachesTheWireWhileThePredecessorIsStillLive): the session's available
                // inputs change as the route settles, so a value captured when the pipeline is
                // built is stale — it reported "no external mic" while one was available and let
                // the diagnostic admit the built-in mic in tests that must stay blocked.
                hasExternalMicrophoneCandidate: routeMonitor?.hasExternalMicrophoneCandidate ?? true
            )
        }
        .sink { [weak self] gate in
            guard let self else { return }
            let previous = self.gateState
            self.gateState = gate.state
            self.gatePosture = gate.posture

            if gateDescription(previous) != gateDescription(gate.state) {
                FileLog.shared.addMessage("[VoicePipeline] Gate: \(gateDescription(previous)) → \(gateDescription(gate.state))")
            }
            // LABEL THE DIAGNOSTIC PATH (owner requirement): a simulator session that only reached
            // listening because the built-in microphone was admitted must never be mistaken for a
            // real isolated-microphone capture when reading logs.
            if DiagnosticMicOverride.isActive, gate.state.isListening,
               gate.posture.micExposure == .exposed || gate.posture.micExposure == .noMic {
                FileLog.shared.addMessage(
                    "[VoicePipeline] \(DiagnosticMicOverride.logLabel): listening on the BUILT-IN "
                    + "microphone. The route is genuinely Exposed; this exception exists so the "
                    + "simulator can exercise capture. Device and Release are unaffected."
                )
            }

            guard !self.isStopping else { return }
            let wasCapturing = self.isListening
            switch gate.state {
            case .off:
                self.stopCapture()
                self.considerAcquisition(for: gate.posture)
            case .listening(let mode):
                // The acquisition's own exposure flip publishes synchronously
                // from inside `acquireExternalInput`. Cancelling here would
                // abort the very task committing the route, and its later
                // cancellation check would clear the selection and drop capture.
                if !self.isAcquiring {
                    self.cancelAcquisition()
                }
                // DIAGNOSTIC (Debug simulator only): the gate admits the built-in microphone
                // BEFORE any acquisition can run, so the session would never be made
                // input-capable and the built-in mic would have no usable route. Arm the
                // diagnostic acquisition on the same path the `.off` case uses. `isAcquiring`
                // marks the task so the resulting exposure flip cannot cancel it.
                if DiagnosticMicOverride.isActive,
                   gate.posture.micExposure == .exposed || gate.posture.micExposure == .noMic {
                    self.considerAcquisition(for: gate.posture)
                }
                self.start(in: mode)
            }
            self.logLifecycleTransition(posture: gate.posture, wasCapturing: wasCapturing)
        }
        .store(in: &cancellables)

        // The ASR/router callbacks, including the serial capture path a dialog `new_command`
        // re-processes through (spec 0443b70) — armed at FIRST ARM, exactly as before the
        // extraction: same lifecycle, only the function boundary moved.
        wireAsrCallbacks()
    }

    /// Enqueues one utterance onto the serial routing chain — the single capture path for ASR
    /// callbacks AND for a dialog `new_command` value queued by a completing turn (spec 0443b70).
    /// `origin: nil` means "capture the live window at enqueue time"; a caller that already holds
    /// the dispatch origin (the draining turn) passes it so the re-processed command belongs to the
    /// same window it was spoken in.
    /// THE SHARED CAPTURE OPERATION (review 5fa6e007): the grace reads + `transcriptLock`
    /// listening check that `enqueueRoutingInput`'s capture phase performs. Production and the
    /// test control call THIS operation, so the control cannot drift from the structure it
    /// exercises. The grace reads happen BEFORE the lock (lock-order safety, review 4d474d80).
    func captureRoutingOrigin(utteranceId: String) -> (admitted: Int?, retired: Bool, generation: Int, listening: Bool)? {
        let admittedOrigin = gracePeriodSignal.admittedOriginForTurn(utteranceId: utteranceId)
        let retiredTurn = gracePeriodSignal.isRetiredTurn(utteranceId)
        let liveGeneration = gracePeriodSignal.currentGeneration()
        // TEST HOOK (review 92de14ea/47328768): fires AFTER the grace reads and BEFORE lock
        // acquisition — the exact window the fix owns. The hook may BLOCK: a control parks the
        // capture here while main runs stop(), then releases. Nil in production.
        captureBeforeAcquisitionBarrierForTesting?()
        transcriptLock.lock()
        defer { transcriptLock.unlock() }
        guard isListening else { return nil }
        return (admittedOrigin, retiredTurn, liveGeneration, true)
    }

    /// TEST-ONLY: barrier between the grace reads and lock acquisition. Nil in production.
    var captureBeforeAcquisitionBarrierForTesting: (() -> Void)?

    /// TEST-ONLY: barrier between the capture's return and the nil-capture guard. Nil in production.
    var enqueueAfterCaptureForTesting: (() -> Void)?

    private func enqueueRoutingInput(
        _ input: IntentRoutingInput,
        origin: Int? = nil,
        selection: CloudConversationSelection? = nil
    ) -> Bool {
            // LOCK-ORDER SAFETY (review 4d474d80): the grace-signal reads hop to main
            // synchronously when called off-main, while `stop()` takes `transcriptLock` ON main.
            // Holding `transcriptLock` across those reads is a lock-order cycle (off-main:
            // transcriptLock → main queue; on-main stop(): main queue → transcriptLock). The
            // shared capture operation performs the reads BEFORE the lock — still at the
            // callback, never after the queue wait — and the lock then guards only the
            // listening check, epoch and chain.
            let capture = self.captureRoutingOrigin(utteranceId: input.utteranceId)
            // TEST-ONLY (review ece440bc): fires AFTER the capture returns and BEFORE the
            // nil-capture guard — the exact stop/restart window the guard owns. A control parks
            // the enqueue here and restarts the service, so the guard's refusal is exercised
            // against a lock-time listening check the restart has made true. Nil in production.
            enqueueAfterCaptureForTesting?()
            // REVIEW 47328768: a nil capture means the turn was ALREADY not listening at capture
            // time. Refuse immediately: falling through to the lock-time `isListening` check lets
            // a stop/restart between the two checks pass a callback whose origin reads never ran,
            // admitting a late turn with no origin at all.
            guard let capture else {
                return false
            }
            let admittedOrigin = capture.admitted
            let retiredTurn = capture.retired
            let liveGeneration = capture.generation
            self.transcriptLock.lock()
            // Drop late ASR callbacks that arrive after (or during) stop(). (A stop AFTER the
            // capture is still caught here: the capture only snapshots origin state, it does not
            // decide admission.)
            guard self.isListening else {
                self.transcriptLock.unlock()
                return false
            }
            let epoch = self.transcriptEpoch
            let previous = self.transcriptSerialTask
            // Capture the turn's origin and selection HERE, at the callback, BEFORE the Task is
            // created — not inside `handleRoutingInput`, which runs only after this Task has
            // awaited all previous work. A capture taken there is a capture taken AFTER the queue
            // wait, which is the attribution error this exists to prevent: a turn that queued
            // behind earlier work would be stamped with whatever window is current by the time it
            // runs, and classified by the window state then rather than by what selected it.
            // The turn's OWN admitted origin when it has one — it was admitted before recognition,
            // so that is the window it belongs to even if an inactivity expiry has since advanced
            // the generation. Falling back to the live read keeps every other caller unchanged.
            // A turn whose admission was RETIRED (privacy/route) is refused outright: it must not
            // fall back to the live window, or a late completion could adopt a window that opened
            // after the retirement — the opposite of what retirement means.
            let capturedOrigin: Int?
            if let origin {
                capturedOrigin = origin
            } else if let admittedOrigin {
                capturedOrigin = admittedOrigin
            } else if retiredTurn {
                capturedOrigin = self.gracePeriodSignal.policyRefusedOrigin
            } else {
                capturedOrigin = liveGeneration
            }
            // The INPUT's own provenance, not a live read. `isActive` cannot tell a wake that
            // fired during grace from a follow-up inside the same grace — both arrive with grace
            // active — so the answer has to come from the gate decision that produced this input.
            let capturedSelection = selection ?? input.selection
            let task = Task { [weak self] in
                // THE TERMINAL ACKNOWLEDGEMENT IS UNCONDITIONAL: on EVERY exit the input's task
                // reports HOW it ended, because "the queued input returned" is not the same claim as
                // "an action ran". A test can therefore await settlement instead of polling for an
                // absence. `onInputRoutingFinished` remains the separate, narrower signal that routing
                // was actually ATTEMPTED.
                // CAPTURED INTO THIS TASK'S OWN STATE BEFORE THE FIRST `await`: reading `self?.hook`
                // from the `defer` would let weak service lifetime silently lose the acknowledgement
                // on an exit that precedes the strong `self` binding — the exits taken when the chain
                // is cancelled or `self` is already gone. The hooks belong to the INVOCATION, so they
                // are bound to it here rather than re-read later.
                let notifyTerminal = self?.onInputTerminal
                let notifyFinished = self?.onInputRoutingFinished
                var terminal: InputTerminalOutcome = .dropped
                defer {
                    // Every terminal outcome for this turn passes through here — routed, refused,
                    // cancelled or dropped — so this is where its eligibility reservation is
                    // released. Releasing exactly once, on the turn's own identity, is what stops a
                    // claim being honoured twice and keeps the reservation from outliving the work.
                    //
                    // A turn that ENQUEUED A CONTINUATION under its own identity (dialog
                    // `new_command`) is the exception: the continuation is a later link in this same
                    // serial chain and carries the same admitted capture, so ownership transfers to
                    // it rather than ending here. Releasing now would retire eligibility before the
                    // queued continuation claims it.
                    if self?.consumeContinuationEnqueued(input.utteranceId) == true {
                        // This link handed ownership on; the continuation released it when IT
                        // reached its own terminal outcome.
                    } else {
                        self?.gracePeriodSignal.releaseInFlightTurn(utteranceId: input.utteranceId)
                    }
                    if let notifyTerminal { Task { @MainActor in notifyTerminal(input, terminal) } }
                    if terminal == .routed, let notifyFinished {
                        Task { @MainActor in notifyFinished(input) }
                    }
                }
                // EAGER BARGE-IN, AHEAD OF THE SERIAL QUEUE (spec e38a790a, reviewer bea7a291).
                //
                // The contract requires the `interrupt` frame "while the prior socket remains
                // open" (`9e309cc1` → Interruption). This turn's DISPATCH cannot run until
                // `previous` finishes, and by then the predecessor's socket is closed — so routing
                // this turn first makes barge-in unreachable in production. The interruption steps
                // therefore run HERE, at admission, while the predecessor is still live: stop local
                // output, send at most one interrupt, retain the complete utterance. Only the
                // INTERRUPTION moves ahead of the queue; classification and execution below stay
                // serial, and the retained follow-up is submitted only after the acknowledgement.
                //
                // Fired from the chain's own task so the capture/ordering guarantees above are
                // unchanged. Echo rejection and gate ownership were already applied at admission.
                // REVALIDATE BEFORE ANY EAGER EFFECT (reviewer b36c8ab1 item 3). The eager
                // interruption stops playback and sends on the live predecessor's socket — real,
                // externally visible effects. The staleness guard below only runs AFTER the queue
                // wait, so a service that stopped, restarted, or retired this capture in between
                // would have already stopped the user's audio and interrupted a turn for an input
                // that is then rejected. The same check that gates the dispatch therefore gates
                // the eager step, using the SAME window identity captured at admission.
                let stillOwnedForEagerEffect = self?.isCaptureStillCurrent(epoch: epoch) ?? false
                var retainedByInterruption = false
                if stillOwnedForEagerEffect {
                    retainedByInterruption = await self?.emitEagerBargeInIfNeeded(
                        for: input,
                        origin: capturedOrigin,
                        selection: capturedSelection,
                        epoch: epoch
                    ) ?? false
                }
                // EXPLICIT OWNERSHIP TRANSFER (reviewer ca629c34). If the eager step retained this
                // utterance for an interruption, the FOLLOW-UP SUBMITTER is the one execution path
                // for it: it submits the same complete admitted input, with its provenance, once
                // the predecessor settles. This queued link must therefore end HERE — before
                // classification, not merely lose a race at dispatch time.
                //
                // Leaving it to run and be refused downstream is what the previous revision did:
                // the executor's admission dedup caught the second owner, so the wire saw one
                // submission, but two executions were still attempted and single submission was a
                // property of dedup rather than of ownership. Retiring the link here makes the
                // transfer explicit and removes the duplicate attempt entirely.
                if retainedByInterruption {
                    terminal = .handedOffToFollowUpSubmission
                    return
                }

                await previous?.value
                guard !Task.isCancelled else { return }
                guard let self else { return }
                self.transcriptLock.lock()
                let stillCurrent = self.isListening && self.transcriptEpoch == epoch
                self.transcriptLock.unlock()
                guard stillCurrent else { return }
                // Held here — after the staleness guard, before classification/execution — so a test
                // can retire this input's window while it waits. Nil in production.
                //
                // THROWING: a barrier that refuses must STOP this chain. A non-throwing barrier could
                // only return from the closure, and routing would resume immediately below, so a
                // cancelled input would still be routed.
                if let barrier = self.testInputBarrier {
                    self.onInputBarrierSettled?(input, .arrived)
                    do {
                        try await barrier(input)
                    } catch is CancellationError {
                        self.onInputBarrierSettled?(input, .cancelled)
                        terminal = .barrierCancelled
                        return
                    } catch {
                        self.onInputBarrierSettled?(input, .refused)
                        terminal = .barrierRefused
                        return
                    }
                }
                // The observer for THIS input, resolved here so no shared slot is involved.
                let parsedObserver = self.parsedIntentObserverFactory?(input)
                // The dispatch seam for THIS input, resolved here so no shared slot is involved.
                let preparedObserver = self.preparedObserverFactory?(input)
                terminal = await self.handleRoutingInput(
                    input,
                    origin: capturedOrigin,
                    selection: capturedSelection,
                    preparedObserver: preparedObserver,
                    parsedIntentObserver: parsedObserver
                )
            }
            self.transcriptSerialTask = task
            self.transcriptLock.unlock()
            return true
    }

    /// Trigger the sink's eager barge-in for this input, unless it is not a barge-in.
    ///
    /// Deliberately narrow: it only asks the sink to interrupt the live predecessor and retain this
    /// utterance. It does not classify, execute, or submit anything — those stay on the serial
    /// chain. An input that is not interrupting a live turn costs one state check.
    /// Whether the capture that admitted this turn is still current.
    ///
    /// Deliberately the SAME test the dispatch uses after the queue wait, factored out so the eager
    /// step cannot drift from it. A turn whose window has ended must produce no effects at all.
    private func isCaptureStillCurrent(epoch: UInt64) -> Bool {
        transcriptLock.lock()
        defer { transcriptLock.unlock() }
        return isListening && transcriptEpoch == epoch
    }

    /// Trigger the sink's eager barge-in for this input.
    ///
    /// Carries the admitted provenance (reviewer b36c8ab1 item 3): the interruption belongs to the
    /// window that accepted the capture, not to whichever window is live when the step runs.
    /// Run the interruption steps for an input that may barge in. Returns whether the input was
    /// RETAINED for follow-up submission, which transfers its execution to the bridge.
    private func emitEagerBargeInIfNeeded(
        for input: IntentRoutingInput,
        origin: Int?,
        selection: CloudConversationSelection?,
        epoch: UInt64
    ) async -> Bool {
        guard input.utteranceId != nil else { return false }
        // Only an input that will actually be routed can barge in; a blank or wake-only capture is
        // a session start, not speech over an answer.
        guard case .route = RouteInputEligibilityPolicy.decide(transcript: input.routerTranscript)
        else { return false }
        // The retained record carries the COMPLETE admitted input — including the selection this
        // capture was admitted under — because the follow-up submitter reconstructs its submission
        // from it, not from whatever is live later (reviewer ca629c34: preserve provenance).
        let interrupted = await executorForTesting.cloudRouteSinkForTesting.emitBargeIn(
            request: input.routerTranscript,
            utteranceId: input.utteranceId,
            origin: origin,
            selection: selection ?? input.selection,
            sourceTranscript: input.sourceTranscript,
            sourceLanguage: input.sourceLanguage,
            translationKind: input.translationKind,
            // The window this capture was ADMITTED under, carried to the effect boundary
            // (reviewer c38ff4ba item 3). A service stop/restart between the caller's check and
            // the main-actor hop is otherwise invisible: the sink would interrupt on behalf of a
            // capture whose window has already ended.
            validatingEpoch: epoch,
            isEpochStillCurrent: { [weak self] epoch in self?.isCaptureStillCurrent(epoch: epoch) ?? false }
        )
        return interrupted != nil
    }

    /// Wires the ASR/router callbacks (the pre-existing registration block, now a named step).
    private func wireAsrCallbacks() {
        // ONE operation: the enqueue itself reports whether it ACCEPTED the input. A separate
        // precheck would be a different operation from the one that takes ownership, so a stop
        // landing between them would reject the enqueue with nobody left to release the turn.
        asrEngine.onRoutingInput = { [weak self] input in
            self?.enqueueRoutingInput(input, origin: nil) ?? false
        }

        asrEngine.onWakeWordDetected = { [weak self] in
            self?.gracePeriodSignal.onWakeWordDetected()
            self?.audioRenderer.playEarcon(.wakeWord)
        }
        // A turn is ADMITTED the moment the engine has settled its window origin and before the
        // backend wait, so a slow (cold-start) recognition cannot let the deadline retire it
        // (spec voice-control-core.md:270). Recorded against the turn's own id, and released on
        // its terminal outcome below, so eligibility lasts exactly as long as the work is live.
        asrEngine.onTurnAdmitted = { [weak self] utteranceId, origin in
            self?.gracePeriodSignal.admitInFlightTurn(utteranceId: utteranceId, origin: origin)
        }
        // A turn that leaves the engine without reaching routing (backend failure, wake-only,
        // empty/non-content transcript, translation failure, cancellation) releases its own
        // reservation here, so it cannot leak for the life of the process.
        asrEngine.onTurnReleased = { [weak self] utteranceId in
            self?.gracePeriodSignal.releaseInFlightTurn(utteranceId: utteranceId)
        }
        // Silent by contract: a wake-only capture is the user opening a session,
        // not a failed question, so it plays nothing. The "command not understood"
        // earcon covers what we could not understand — it is not the opening.
        // (`onWakeOnly` takes no arguments; a listener is registered rather than
        // left nil so the intent is visible at the call site.)
        asrEngine.onWakeOnly = {}
        asrEngine.onUnroutable = { [weak self] in
            self?.audioRenderer.playEarcon(.error)
        }

        asrEngine.onStageTiming = { [weak self] timing in
            self?.latestStageTiming = timing
        }
        // The segmentation fault must reach something outside the audio component. Recording it
        // here makes the interruption inspectable (a listener such as the UI can read
        // `latestSegmentationFault`) and logs it alongside the other pipeline state, rather than
        // leaving it as a flag private to the segmenter with no observer.
        asrEngine.onSegmentationFault = { [weak self] fault in
            self?.latestSegmentationFault = fault
            FileLog.shared.addMessage(
                "[VoicePipeline] segmentation fault kind=\(fault.kind) elapsedMs=\(fault.elapsedMs) "
                    + "discarded=\(fault.discardedSamples) reason=\(fault.reason ?? "none")"
            )
        }
        intentRouter.onMetrics = { [weak self] metrics in
            self?.latestRouterMetrics = metrics
        }

        // Single-flight LFM load — one task even if startIfAllowed were re-entered.
        intentRouterReadyTask = Task { [weak self] in
            guard let self else { return }
            let result = await self.intentRouter.ensureReady()
            switch result {
            case .success:
                FileLog.shared.addMessage("[VoicePipeline] Intent router ready")
                self.conditionMonitor.updateModelsReady(.allowed)
            case .failure(let error):
                FileLog.shared.addMessage("[VoicePipeline] Intent router FAILED: \(error)")
                // A router that cannot engage must block capture rather than
                // silently returning no intent for every transcript.
                self.conditionMonitor.updateModelsReady(.blocked(reason: "router_not_ready"))
            }
        }
    }

    private func start(in mode: ListeningMode) {
        guard !isListening else {
            if listeningMode != mode {
                FileLog.shared.addMessage("[VoicePipeline] mode updated to \(mode)")
                listeningMode = mode
                asrEngine.listeningMode = mode
            }
            return
        }
        FileLog.shared.addMessage("[VoicePipeline] start listening (\(mode))")
        asrEngine.listeningMode = mode
        guard asrEngine.start() else {
            // Capture failed to start (configure/engine error). Reporting
            // listening would retain the acquired external route with no
            // capture running, so release it and stay off. Remember which
            // external device failed: its release reverts the live route to the
            // built-in mic, which must not be mistaken for a device change that
            // re-arms acquisition for the same device.
            FileLog.shared.addMessage("[VoicePipeline] capture start failed — releasing acquired route")
            captureStartFailedInputUID = routeMonitor.currentExternalInputUID
                ?? routeMonitor.lastAcquisitionTargetUID
            captureStartFailedEpoch = routeMonitor.physicalDeviceChangeEpoch
            routeMonitor.releaseAcquiredExternalInput(sessionInUseByPlayback: isPlaybackActive())
            return
        }
        isListening = true
        listeningMode = mode
        if mode == .wakeWord {
            audioRenderer.playEarcon(.listeningStart)
        }
    }

    func stop() {
        guard !isStopping else { return }
        isStopping = true
        defer { isStopping = false }
        cancelAcquisition()
        stopCapture()
    }

    private func stopCapture() {
        guard isListening else { return }
        FileLog.shared.addMessage("[VoicePipeline] stop listening")
        asrEngine.stop()
        isListening = false
        audioRenderer.release()
        transcriptLock.lock()
        transcriptEpoch &+= 1
        transcriptSerialTask?.cancel()
        transcriptSerialTask = nil
        transcriptLock.unlock()
        // An active capture stop ends the acquired external-input route. Release
        // the preferred input acquisition selected and deactivate only a session
        // acquisition itself activated, re-checking live playback ownership so a
        // session playback holds is never stopped.
        routeMonitor.releaseAcquiredExternalInput(sessionInUseByPlayback: isPlaybackActive())
    }

    /// Compatibility wrapper for tests that still pass a bare English transcript.
    func handleTranscript(_ transcript: String, utteranceId: String) async {
        await handleRoutingInput(.english(transcript: transcript, utteranceId: utteranceId))
    }

    /// - Parameters:
    ///   - origin: the grace-window generation captured at the CALLBACK, before this turn queued.
    ///     Not read here: by the time this runs, earlier work has completed and the window may
    ///     have moved on.
    ///   - selection: what selected the turn, captured at the same moment and for the same
    ///     reason.
    /// Produces a PARSED-INTENT observer FOR A SPECIFIC INPUT, so the observation is invocation-local:
    /// the callback returns a fresh observer per input rather than every dispatch writing into one
    /// shared slot, which would let an overlapping turn overwrite another's observed intent.
    /// Nil in production.
    private let parsedIntentObserverFactory: (@Sendable (IntentRoutingInput) -> ParsedIntentObserver?)?
    private let preparedObserverFactory: (@Sendable (IntentRoutingInput) -> CloudRouteSink.PreparedObserver?)?

    /// Reports the intent the ROUTER PARSED for a dispatch, BEFORE the executor runs it. Invocation
    /// local and carried on the call, like `preparedObserver`: a sink- or service-wide slot would let
    /// an overlapping dispatch overwrite another's observed intent, so the assertion could be made
    /// against the wrong turn.
    typealias ParsedIntentObserver = @MainActor (any VoiceIntent) -> Void

    /// Submit the follow-up an interruption acknowledgement released
    /// (`cloud-assistant.md` → Interruption, spec c5fe3416).
    ///
    /// The contract's rule is precise and this follows it literally: after the prior turn's
    /// terminal acknowledgment the retained utterance is submitted ONCE, on its OWN socket, as a
    /// new turn. It is not submitted inline from inside the settling turn (that would ride the old
    /// socket, which the contract forbids), and it is never retried — the acknowledgement is the
    /// only trigger, and `takeReleasedInterruptionFollowUp` hands it out exactly once.
    ///
    /// The utterance keeps its own admitted identity and origin from when the user spoke it, so
    /// admission, conversation continuation and rendering all treat it as the user's real
    /// utterance rather than a synthetic one.
    private func submitRetainedFollowUpIfAny() async {
        // The sink's read-and-clear is main-actor isolated (its state is the sink's), so the take
        // hops there rather than reading across the actor.
        let released = await MainActor.run { executor.takeReleasedInterruptionFollowUp() }
        if let released {
            VoiceControlTestObservers.followUpTaken?(
                "\(released.utteranceId)@origin\(released.origin.map(String.init) ?? "n")"
            )
        }
        guard let released else { return }
        FileLog.shared.addMessage(
            "[VoicePipeline] submitting retained follow-up \(released.utteranceId) on its own socket"
        )
        // THE COMPLETE ADMITTED INPUT, with the provenance it was admitted under — not a
        // reconstructed turn with a live default selection (reviewer ca629c34).
        await handleRoutingInput(
            IntentRoutingInput(
                sourceTranscript: released.sourceTranscript,
                sourceLanguage: released.sourceLanguage,
                routerTranscript: released.request,
                translationKind: released.translationKind ?? .none,
                selection: released.selection,
                utteranceId: released.utteranceId
            ),
            origin: released.origin,
            selection: released.selection
        )
    }

    /// Returns the actual routing disposition, distinguishing capture loss from interruption suppression.
    @discardableResult
    func handleRoutingInput(
        _ input: IntentRoutingInput,
        origin: Int? = nil,
        selection: CloudConversationSelection? = nil,
        preparedObserver: CloudRouteSink.PreparedObserver? = nil,
        parsedIntentObserver: ParsedIntentObserver? = nil
    ) async -> InputTerminalOutcome {
        // Belt-and-suspenders with the epoch check in the serial chain: an
        // in-flight classify must not execute after capture has stopped.
        guard isListening else { return .dropped }
        // A REFUSED INTERRUPTION SUPPRESSES ITS UTTERANCE (cloud-assistant.md → Interruption).
        // The barge-in was emitted eagerly at admission, so its turn is already queued here.
        // After a refusal the contract forbids submitting it, so this turn must not reach the
        // wire: check the suppression the refusal recorded before doing any work.
        let utteranceId = input.utteranceId
        // Checked at entry AND again immediately before dispatch: the refusal terminal can land
        // while this turn is still queued or classifying, which is exactly the ordering measured
        // here (B entered, A's refusal arrived 110ms later).
        if await MainActor.run(body: {
            executorForTesting.cloudRouteSinkForTesting.isSuppressedForTesting(utteranceId)
        }) {
            FileLog.shared.addMessage(
                "[VoicePipeline] suppressed utterance \(utteranceId) — its interruption was refused"
            )
            return .suppressedByInterruption
        }
        let dialogContext = dialogManager.pendingDialog
        let transcript = input.routerTranscript

        let capturedOrigin = origin
        // The INPUT's own provenance, falling back to the parameter. The parameter exists for the
        // serial-callback path, which captures before queuing; but a caller that stamps the input
        // — which is where the gate decision actually lands — had its provenance SILENTLY
        // DISCARDED here, so the turn fell through to the sink's live-state provider.
        let capturedSelection = selection ?? input.selection

        // A bare wake is not a question: neither routed nor escalated, and it must
        // not spend the window's one dispatch. Without per-token timestamps ASR
        // keeps the wake phrase in the transcript, so this is where that case is
        // caught rather than by the trimmer, which cannot recover the tokens it
        // never had.
        switch RouteInputEligibilityPolicy.decide(transcript: transcript) {
        case .blank, .silentSessionStart:
            // Silent by contract and *before* classification: a wake-only or blank
            // capture is the start of a session (or nothing at all), not a failed
            // question. Letting it reach `.none` would count it as an unclassified
            // turn and eventually play the error earcon — the outcome the silent
            // rule forbids.
            FileLog.shared.addMessage(
                "[VoicePipeline] session-start capture ← '\(transcript)' — not routed, silent"
            )
            return .routed
        case .route:
            break
        }
        let result = intentRouter.classify(input: input, pendingDialog: dialogContext)
        // Snapshot before recording: `recordPipelineLatency` consumes and clears
        // `latestRouterMetrics`, and the escalation policy must read *this* turn's
        // reason rather than nil — a cleared reason escalates even the reasons that
        // must stay local (PR #23 review).
        let turnMetrics = latestRouterMetrics
        recordPipelineLatency(transcript: transcript)

        switch result {
        case .intent(let rawIntent):
            // THE RAW CLASSIFIER RESULT, observed BEFORE the stamping below reconstructs the intent.
            // Firing this after the stamp would assert the reconstructed dispatch intent instead of
            // what the router actually classified, which is the point of the observation.
            await MainActor.run { parsedIntentObserver?(rawIntent) }
            // Stamp a model-chosen cloud route with the window it runs under, so
            // its completion can be judged against that window rather than against
            // whatever is current when the network call returns.
            var intent = rawIntent
            if let route = rawIntent as? CloudRouteIntent, route.generation == nil {
                intent = CloudRouteIntent(
                    request: route.request,
                    tier: route.tier,
                    // The INPUT's preserved source utterance and actual detected language — not
                    // reconstructed from the route: the English routing translation must never
                    // replace the original on the wire (core b6eafe25).
                    sourceTranscript: input.sourceTranscript,
                    sourceLanguage: input.sourceLanguage,
                    // REQUEST OWNERSHIP: the captured utterance's identity travels with the turn.
                    utteranceId: input.utteranceId,
                    origin: route.origin,
                    // The origin captured with the INPUT, not read here: this point is after the
                    // routing work, so a live read would attribute the turn to whichever window
                    // happens to be current now.
                    generation: capturedOrigin,
                    selection: capturedSelection
                )
            }

            // Debounce: skip if same intent type was executed within the debounce window
            let intentType = String(describing: type(of: intent))
            if let lastType = lastIntentType,
               let lastTime = lastExecutionTime,
               lastType == intentType,
               Date().timeIntervalSince(lastTime) < debounceInterval {
                FileLog.shared.addMessage("[VoicePipeline] debounce \(intentType)")
                return .routed
            }

            FileLog.shared.addMessage("[VoicePipeline] intent \(intent) ← '\(transcript)'")
            guard isListening else { return .dropped }
            // A turn whose admission was RETIRED (privacy/route) must not execute, even when the
            // router chose an intent locally: retirement means the user's speech may no longer be
            // safe to act on, and the model-chosen path would otherwise run it directly without
            // ever consulting the reservation.
            guard !gracePeriodSignal.isRetiredTurn(input.utteranceId) else {
                FileLog.shared.addMessage("[VoicePipeline] intent refused (admission retired) ← '\(transcript)'")
                return .routed
            }
            // RE-CHECK SUPPRESSION IMMEDIATELY BEFORE DISPATCH: a refusal that landed while this
            // turn was queued or classifying must still stop it from reaching the wire.
            if await MainActor.run(body: {
                executorForTesting.cloudRouteSinkForTesting.isSuppressedForTesting(input.utteranceId)
            }) {
                FileLog.shared.addMessage(
                    "[VoicePipeline] suppressed at dispatch \(input.utteranceId ?? "-") — "
                    + "its interruption was refused"
                )
                return .suppressedByInterruption
            }
            let response = await executor.execute(intent, preparedObserver: preparedObserver)
            // SUBMIT THE RETAINED FOLLOW-UP (cloud-assistant.md → Interruption, spec c5fe3416).
            // When the turn that just settled was interrupted, the interrupting utterance was held
            // until its acknowledgement — a `done` for the prior turn, even `completed`, is that
            // acknowledgement. It is submitted here ONCE on its own socket, through the ordinary
            // capture path so it is admitted, routed and rendered like any other utterance. It is
            // never submitted inline from inside this turn, and never retried.
            await submitRetainedFollowUpIfAny()
            // Do not reset the window unconditionally here. A cloud route's
            // completion is the executor's to attribute — it already does so
            // against the generation the route was issued under
            // (`recognizeCommandIfCurrentWindow`), and resetting again from here
            // re-opened windows that had ended, undoing that guard: a model-chosen
            // cloud route landing after a privacy close would re-arm a session it
            // never belonged to, and the gate maps an active window to continuous
            // capture. Local intents have no window identity of their own, so the
            // generic reset is right for them.
            if !(intent is CloudRouteIntent) {
                gracePeriodSignal.onCommandRecognized()
            }
            lastIntentType = intentType
            lastExecutionTime = Date()
            audioRenderer.render(response)

        case .dialogControl(let action):
            FileLog.shared.addMessage("[VoicePipeline] dialog \(action) ← '\(transcript)'")
            let dialogResult = dialogManager.handle(action)

            if let intent = dialogResult.intent {
                guard !gracePeriodSignal.isRetiredTurn(input.utteranceId) else {
                    FileLog.shared.addMessage("[VoicePipeline] dialog intent refused (admission retired)")
                    return .routed
                }
                let response = await executor.execute(intent, preparedObserver: preparedObserver)
                // Same bridge on every executor path: an interruption resolved by THIS turn must
                // reach its follow-up whichever intent produced it.
                await submitRetainedFollowUpIfAny()
                gracePeriodSignal.onCommandRecognized()
                lastIntentType = String(describing: type(of: intent))
                lastExecutionTime = Date()
                audioRenderer.render(response)
            } else if let reprocessValue = dialogResult.reprocessValue {
                // REPROCESS vs SPEAK (spec 0443b70): a `new_command` control cancels the dialog
                // and re-processes its value as a FRESH transcript — the value is a command the
                // user gave ("what they said, taken back"), not an answer to speak. Merely
                // rendering it as prose answered nothing and executed nothing. The value is
                // ENQUEUED as its own chain link — never routed inline from this turn, which
                // would re-enter `handleRoutingInput` from inside the serial chain — under THIS
                // capture's admitted identity (the value is not a new utterance: no new admission
                // happened) and the window it was spoken in.
                // The SAME admitted capture continues: preserve B's captured selection
                // (wakeWord vs followUp) along with its origin and identity — a fresh wake B
                // during an existing conversation must not silently fall back to live-state
                // continuation just because its value was re-processed.
                // Accepted-then-transfer from the ACTUAL enqueue result: only a continuation that
                // was really enqueued takes ownership. A refused enqueue leaves this link owning the
                // reservation, so its own `defer` releases it rather than leaking it to a
                // continuation that never ran. The marker is set AFTER the enqueue returns, and the
                // enqueue releases it again if it refused — so the two can never disagree.
                let enqueued = enqueueRoutingInput(
                    .english(transcript: reprocessValue, selection: capturedSelection, utteranceId: input.utteranceId),
                    origin: capturedOrigin,
                    selection: capturedSelection
                )
                if enqueued {
                    self.markContinuationEnqueued(input.utteranceId)
                }
            } else if let question = dialogResult.question {
                audioRenderer.render(.spoken(question))
            }
            // If dialogResult has no intent and no question (e.g., cancel), do nothing

        case .none:
            let stage = turnMetrics?.failedStage ?? "?"
            let reason = turnMetrics?.reason

            // A routing failure or a deliberate `no_match` escalates through the
            // same path a chosen `cloud_route` uses — same intent, same executor —
            // so the superseded-turn cancellation and the auto-pause obligation
            // apply to it by construction rather than by a second implementation.
            // The transcript goes verbatim, the tier is unknown, and no route hint
            // is sent (hints accompany validated arguments only).
            // Re-checked here as the `.intent` branch does before executing: the
            // check at the top of this method happens before the synchronous
            // classification, and capture can stop while that runs. Without this a
            // stopped session could still send the transcript. Checked before the
            // claim so a stopped session does not consume the allowance either.
            guard isListening else { return .dropped }
            let escalation = RouteFailureEscalationPolicy.outcome(for: reason)
            // Claimed as a statement, not a multi-line ternary: a continuation
            // line starting with "?" parses as optional chaining, not as the
            // ternary operator.
            var dispatchGeneration: Int?
            if escalation == .escalate {
                // Claimed AGAINST THIS INPUT'S CAPTURED ORIGIN, in one operation with the
                // comparison (see the signal): checking liveness separately and then claiming
                // would leave a gap in which a wake or a privacy close could land. A turn whose
                // captured window has ended must consume NOTHING and dispatch NOTHING, rather than
                // borrowing the allowance of the window that replaced it.
                dispatchGeneration = gracePeriodSignal.claimDispatchOwnership(
                    capturedOrigin: capturedOrigin,
                    utteranceId: input.utteranceId
                )
            }
            if escalation == .escalate, dispatchGeneration == nil {
                // Eligible, but this window's allowance is spent. A refused
                // budget is a local failure and speaks on the *first* refusal:
                // leaving it to the debounce gave the user silence for their next
                // attempt, which is the outcome this change exists to remove.
                // Two different causes reach here: an allowance already spent in
                // this window, and no open window at all (never woke, expired, or
                // closed for privacy). Naming them together would report a closed
                // session as a repeat question, so the log reads the actual state.
                let cause = gracePeriodSignal.isActive
                    ? "allowance already spent this window"
                    : "no open session window"
                FileLog.shared.addMessage(
                    "[VoicePipeline] cloud escalation refused (\(cause)) ← '\(transcript)' (reason=\(reason ?? "?"))"
                )
                if gracePeriodSignal.claimRefusalTone() {
                    audioRenderer.playEarcon(.error)
                }
                return .routed
            }
            if let dispatchGeneration {
                let reasonText = reason ?? "?"
                FileLog.shared.addMessage("[VoicePipeline] cloud escalation ← '\(transcript)' (reason=\(reasonText))")
                // No error earcon here: the user is getting an answer. A dispatch
                // that itself fails carries its own earcon from the sink.
                // Marked as a fallback so the executor extends the window without
                // restoring the allowance that permitted it.
                let response = await executor.execute(
                    CloudRouteIntent(
                        request: transcript,
                        tier: .unknown,
                        // The same preservation on the fallback path: the escalated turn carries
                        // the original utterance and its actual language when the input has them.
                        sourceTranscript: input.sourceTranscript,
                        sourceLanguage: input.sourceLanguage,
                        // REQUEST OWNERSHIP: the fallback carries the same utterance identity.
                        utteranceId: input.utteranceId,
                        origin: .routingFailure,
                        generation: dispatchGeneration,
                        // The turn's own provenance, carried as it is on the model-chosen path.
                        // Omitting it dropped the turn to the sink's provider fallback, so an
                        // escalated turn was classified by live window state rather than by what
                        // selected it — the exact defect the caller-level control exists to catch.
                        selection: capturedSelection
                    ),
                    preparedObserver: preparedObserver
                )
                // The escalation path resolves interruptions too: a barge-in that itself
                // escalates must still submit its follow-up once acknowledged.
                await submitRetainedFollowUpIfAny()
                audioRenderer.render(response)
                return .routed
            }

            FileLog.shared.addMessage(
                "[VoicePipeline] intent none ← '\(transcript)' stage=\(stage) reason=\(reason ?? "?")"
            )
            // Every turn reaching here is `.stayLocal`: escalation was refused
            // and already handled above (tone on the window's first refusal),
            // and a blank transcript never survives classification
            // (`RouteInputEligibilityPolicy` returns on the same emptiness
            // test). What is left are the capability failures — reasons where
            // the router could not do its job — and each speaks: the user asked
            // a real question and got nothing.
            audioRenderer.playEarcon(.error)
        }
        return .routed
    }

    /// Emits the pipeline latency event from the latest ASR-stage timing and
    /// router metrics. No transcript text is included.
    private func recordPipelineLatency(transcript: String) {
        guard let stageTiming = latestStageTiming, let routerMetrics = latestRouterMetrics else { return }
        let metric = PerformanceMetrics(
            totalTranscriptToIntentMs: routerMetrics.totalMs,
            prefillMs: 0,
            timeToFirstTokenMs: 0,
            decodeMs: 0,
            parseResolveMs: 0,
            backend: stageTiming.backend,
            isFallback: false,
            modelRelease: routerMetrics.modelRelease ?? "unknown",
            inputTokens: 0,
            outputTokens: 0,
            pipeline: stageTiming,
            classificationOutcome: routerMetrics.outcome,
            routerModelRelease: routerMetrics.modelRelease,
            transcriptTokenCount: transcript.utf8.count / 4
        )
        analytics.recordPipelineLatency(metric: metric)
        latestStageTiming = nil
        latestRouterMetrics = nil
    }

    // MARK: - Lifecycle logging

    private func logLifecycleTransition(posture: GatePosture, wasCapturing: Bool) {
        lifecycleLogger.transition(
            posture: posture,
            route: routeDescription(),
            wasCapturing: wasCapturing,
            isCapturing: isListening
        )
    }

    private func routeDescription() -> String {
        let route = routeMonitor.currentRoute
        return "\(route.output):\(route.input.map { "\($0)" } ?? "nil")"
    }

    // MARK: - Route acquisition

    /// Attempt to acquire an external microphone only when every non-exposure
    /// gate question passes. The attempt is once per route signature; a late or
    /// cancelled completion is discarded rather than starting capture.
    private func considerAcquisition(for posture: GatePosture) {
        guard posture.setup.isReady,
              posture.conflicts.isClear,
              posture.context != .none,
              posture.micExposure == .exposed || posture.micExposure == .noMic
        else {
            cancelAcquisition()
            return
        }
        guard acquisitionTask == nil else { return }
        // A capture start that failed for an external device must not re-arm
        // acquisition for that same device. Release restores `.playback`, which
        // exposes no `availableInputs` even while the headset stays connected, so
        // a missing candidate UID is not evidence of removal — treating it as one
        // cleared the suppression and re-armed the acquire→fail→release loop. Keep
        // the key until a physical device change (a real connect or disconnect).
        if captureStartFailedInputUID != nil {
            guard routeMonitor.physicalDeviceChangeEpoch != captureStartFailedEpoch else { return }
            captureStartFailedInputUID = nil
            captureStartFailedEpoch = 0
        }
        let route = routeMonitor.acquisitionKey
        guard acquisitionAttemptedRoute != route else { return }
        acquisitionAttemptedRoute = route
        let generation = acquisitionGeneration

        acquisitionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            // Cancelled before it starts: never touch the audio session, so a
            // blocked/`Off` posture cannot retain an input route.
            guard !Task.isCancelled else { return }
            // Playback belongs to the same shared session; the gate context may
            // also already say playback is active. Either is enough to forbid
            // deactivation on failure. Passed as a live provider, not a sampled
            // value: playback can start during the async confirmation wait, and
            // every cleanup path must re-check who owns the session then.
            let contextPlaybackActive = posture.context == .playbackActive || posture.context == .both
            let isPlaybackActive: () -> Bool = { [weak self] in
                contextPlaybackActive || (self?.isPlaybackActive() ?? true)
            }
            // From here until the function returns, the exposure flip emits
            // synchronously into the gate sink; mark the task so `.listening`
            // does not cancel it.
            self.isAcquiring = true
            // TEST-ONLY: park the acquisition here so a control can observe teardown joining a
            // task that is genuinely STILL IN FLIGHT. Without a parked acquisition the task has
            // always completed before teardown, so a join control could never observe the thing
            // it exists to check (reviewer `33d3a531`). Nil in production.
            if let barrier = self.acquisitionInFlightBarrierForTesting {
                await barrier()
            }
            guard !Task.isCancelled else {
                if self.acquisitionGeneration == generation || self.acquisitionTask == nil {
                    self.isAcquiring = false
                }
                return
            }
            let result = await self.routeMonitor.acquireExternalInput(isPlaybackActive: isPlaybackActive)
            self.isAcquiring = false
            let isCurrent = !Task.isCancelled && self.acquisitionGeneration == generation
            if isCurrent {
                self.acquisitionTask = nil
            }
            switch result {
            case .acquired:
                // Capture starts from the gate sink the moment exposure flips
                // to isolated. If the gate never reached `.listening` (a
                // conflict landed first), the acquired route has no owner:
                // release it so no external input is retained without capture.
                // Also covers a success that a later cancel superseded before
                // this task resumed, as long as no newer acquisition owns the
                // route now.
                if !self.isListening, self.acquisitionTask == nil {
                    self.routeMonitor.releaseAcquiredExternalInput(sessionInUseByPlayback: self.isPlaybackActive())
                }
            case .cancelled, .notApplicable:
                break
            default:
                guard isCurrent, let reason = result.failureReason else { break }
                // Acquisition left the route Exposed/NoMic: report it as a
                // non-acquisition with the route-acquisition failure reason. A
                // later gate re-evaluation with the same posture will not
                // duplicate it.
                self.lifecycleLogger.transition(
                    posture: self.gatePosture,
                    route: self.routeDescription(),
                    wasCapturing: false,
                    isCapturing: false,
                    acquisitionFailureReason: reason
                )
            }
        }
    }

    /// TEST-ONLY: an awaitable barrier entered at the head of an acquisition attempt, so a
    /// control can hold a task in flight across teardown. Nil in production.
    var acquisitionInFlightBarrierForTesting: (@Sendable () async -> Void)?

    /// Captures the exact queued owner so cancellation controls cannot cancel a successor instead.
    func captureRoutingTaskForTesting() -> Task<Void, Never>? {
        transcriptLock.lock(); defer { transcriptLock.unlock() }
        return transcriptSerialTask
    }

    /// TEST-ONLY: CAPTURE the in-flight acquisition task, before anything can clear it.
    ///
    /// `stop()` cannot be called first: it ends capture, which releases the acquired route, which
    /// flips the gate and runs `cancelAcquisition()` — nilling `acquisitionTask`. A helper that
    /// looked the task up afterwards would therefore find nothing and return without joining the
    /// very task that was in flight (reviewer `33d3a531`). Teardown captures first, then stops,
    /// then awaits the captured task's real completion.
    func captureAcquisitionTaskForTesting() -> Task<Void, Never>? {
        acquisitionTask
    }

    /// TEST-ONLY: await a task captured earlier, with a BOUND THAT ACTUALLY BINDS.
    ///
    /// The previous version used `withTaskGroup` and `group.cancelAll()` when the timer won. That
    /// does NOT unblock the sibling child that is awaiting `task.value` on an independent task:
    /// leaving the task-group scope still waits for every child, so the "timeout" never returned —
    /// measured as a scripted task that never completes hanging indefinitely on a 0.3s bound.
    ///
    /// This version uses an INDEPENDENT completion signal. The task records its own completion into
    /// a lock-guarded flag and signals a semaphore; the waiter races that semaphore against the
    /// timeout. Nothing is awaited on an independent task inside a scope that must drain, so a task
    /// that never completes cannot block the caller past the bound.
    static func awaitCompletion(
        of task: Task<Void, Never>,
        timeout: TimeInterval
    ) async -> Bool {
        let done = CompletionSignal()
        // The observer task records completion. It is deliberately NOT awaited or cancelled here:
        // if the task never completes, this observer may take until the end of the process. It
        // holds no resources the bound depends on, which is the whole point of the rewrite.
        Task.detached(priority: .utility) {
            await task.value
            done.signal()
        }
        // Wait OFF the main actor: this is called from a main-actor test, and blocking main would
        // deadlock the main-actor-bound acquisition task it is waiting for.
        return await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: done.wait(timeout: timeout))
            }
        }
    }

    /// A one-shot completion flag with a blocking bounded wait.
    private final class CompletionSignal: @unchecked Sendable {
        private let semaphore = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var completed = false
        func signal() {
            lock.lock()
            if completed { lock.unlock(); return }
            completed = true
            lock.unlock()
            semaphore.signal()
        }
        func wait(timeout: TimeInterval) -> Bool {
            lock.lock()
            if completed { lock.unlock(); return true }
            lock.unlock()
            return semaphore.wait(timeout: .now() + timeout) == .success
        }
    }

    private func cancelAcquisition() {
        acquisitionGeneration &+= 1
        acquisitionTask?.cancel()
        acquisitionTask = nil
        // Clear the one-shot dedup: a transient blocker (call, casting, other
        // app, context loss) cancels a scheduled attempt, and the same route
        // must be retried once the blocker clears. Failure completions do not
        // call this, so a genuinely failed route is still not retried in a loop
        // — a later physical notification is what grants the next attempt, via
        // the epoch in the dedup key rather than by clearing it here.
        acquisitionAttemptedRoute = nil
    }
}

// MARK: - Mic lifecycle logging

/// One mic lifecycle event in structured form. Kept separate from OSLog so the
/// transition, severity and dedup rules are unit-testable.
struct MicLifecycleLogRecord: Equatable {
    let event: String
    let level: OSLogType
    /// Deterministically ordered (gate evaluation order, then runtime reasons).
    let reasons: [String]
    let setupReady: Bool
    let conflictsClear: Bool
    let context: String
    let micExposure: String
    let route: String
    let listeningMode: String
    let priorCapture: Bool
}

protocol MicLifecycleLogSink: AnyObject {
    func write(_ record: MicLifecycleLogRecord)
}

/// Production sink. Route details are indirectly identifying metadata, so they
/// are marked private; audio and transcript text are never passed in.
final class OSLogMicLifecycleSink: MicLifecycleLogSink {
    private let log = Logger(subsystem: "com.pocketcasts", category: "VoicePipeline")

    func write(_ record: MicLifecycleLogRecord) {
        let reasons = record.reasons.joined(separator: ",")
        log.log(
            level: record.level,
            """
            event=\(record.event, privacy: .public) \
            reasons=\(reasons, privacy: .public) \
            setup=\(record.setupReady, privacy: .public) \
            conflicts=\(record.conflictsClear, privacy: .public) \
            context=\(record.context, privacy: .public) \
            micExposure=\(record.micExposure, privacy: .public) \
            route=\(record.route, privacy: .private) \
            listeningMode=\(record.listeningMode, privacy: .public) \
            priorCapture=\(record.priorCapture, privacy: .public)
            """
        )
    }
}

/// Owns the mic lifecycle logging rules:
/// - capture acquired → `mic_capture_started` (INFO)
/// - active capture stopped → `mic_capture_stopped`; INFO only for a direct,
///   attributable user request (voice control disabled), ERROR otherwise
/// - blocked and never acquired → `mic_acquisition_skipped` (INFO) once on
///   entry, again only when the blocking reason set changes
final class MicLifecycleLogger {
    private let sink: MicLifecycleLogSink
    /// Last blocking reason set logged for a blocked-never-acquired posture.
    private var loggedSkippedReasons: [String]?

    init(sink: MicLifecycleLogSink) {
        self.sink = sink
    }

    func transition(
        posture: GatePosture,
        route: String,
        wasCapturing: Bool,
        isCapturing: Bool,
        acquisitionFailureReason: String? = nil
    ) {
        var reasons = Self.blockers(for: posture)
        if let acquisitionFailureReason {
            reasons.append(acquisitionFailureReason)
        }

        if isCapturing && !wasCapturing {
            loggedSkippedReasons = nil
            emit(event: "mic_capture_started", level: .info, reasons: reasons,
                 posture: posture, route: route, priorCapture: wasCapturing)
        } else if wasCapturing && !isCapturing {
            // The stop event already records the entry into the blocked posture;
            // remember its reason set so `mic_acquisition_skipped` only fires if
            // the blockers change afterwards.
            loggedSkippedReasons = reasons
            let userRequested = !posture.setup.enabledByUser.isAllowed
            emit(event: "mic_capture_stopped", level: userRequested ? .info : .error,
                 reasons: reasons, posture: posture, route: route, priorCapture: wasCapturing)
        } else if !isCapturing && !posture.allowed && reasons != loggedSkippedReasons {
            loggedSkippedReasons = reasons
            emit(event: "mic_acquisition_skipped", level: .info, reasons: reasons,
                 posture: posture, route: route, priorCapture: wasCapturing)
        }
    }

    /// Active-capture stop caused at runtime (e.g. the audio session was
    /// reclaimed). Always ERROR: never a direct user request. Resets the skip
    /// dedup so a subsequent blocked posture logs its own reason set.
    func runtimeCaptureStopped(reason: String, posture: GatePosture, route: String) {
        loggedSkippedReasons = nil
        emit(event: "mic_capture_stopped", level: .error, reasons: [reason],
             posture: posture, route: route, priorCapture: true)
    }

    /// Deterministically ordered blocking reason set from the posture.
    /// Gate-owned reasons use their condition names, in gate evaluation order
    /// (setup → conflicts → context → mic exposure). Unknown conditions fail
    /// closed, so they count as blocking.
    static func blockers(for posture: GatePosture) -> [String] {
        var reasons: [String] = []
        if !posture.setup.enabledByUser.isAllowed { reasons.append("EnabledByUser") }
        if !posture.setup.deviceSupported.isAllowed { reasons.append("DeviceSupported") }
        if !posture.setup.modelsReady.isAllowed { reasons.append("ModelsReady") }
        if !posture.conflicts.notOnCall.isAllowed { reasons.append("NotOnCall") }
        if !posture.conflicts.notCasting.isAllowed { reasons.append("NotCasting") }
        if !posture.conflicts.batteryOk.isAllowed { reasons.append("BatteryOk") }
        if !posture.conflicts.otherAppPlaying.isAllowed { reasons.append("OtherAppPlaying") }
        if posture.context == .none { reasons.append("ListeningContext") }
        if posture.micExposure == .noMic { reasons.append("NoMic") }
        if posture.micExposure == .exposed { reasons.append("ExposedMic") }
        return reasons
    }

    private func emit(
        event: String,
        level: OSLogType,
        reasons: [String],
        posture: GatePosture,
        route: String,
        priorCapture: Bool
    ) {
        sink.write(
            MicLifecycleLogRecord(
                event: event,
                level: level,
                reasons: reasons,
                setupReady: posture.setup.isReady,
                conflictsClear: posture.conflicts.isClear,
                context: String(describing: posture.context),
                micExposure: String(describing: posture.micExposure),
                route: route,
                listeningMode: posture.listeningMode.map { "\($0)" } ?? "none",
                priorCapture: priorCapture
            )
        )
    }
}

private func gateDescription(_ state: GateState) -> String {
    switch state {
    case .off(let reason): return "off(\(reason))"
    case .listening(let mode): return "listening(\(mode))"
    }
}
