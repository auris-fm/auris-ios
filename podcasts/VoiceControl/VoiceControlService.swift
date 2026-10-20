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
    enum InputTerminalOutcome: Sendable { case routed, barrierCancelled, barrierRefused, dropped }
    /// Reports how a queued input's task TERMINATED — on EVERY exit, including a refusal or a
    /// cancellation. This is the TERMINAL ACKNOWLEDGEMENT: the input returned, which is not the same
    /// as an action having run. Distinct from `onInputRoutingFinished`, which reports that routing was
    /// ATTEMPTED. Nil in production.
    private let onInputTerminal: (@Sendable (IntentRoutingInput, InputTerminalOutcome) -> Void)?

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
    private var latestRouterMetrics: RouterClassificationMetrics?

    private var cancellables = Set<AnyCancellable>()
    /// Serializes classify+generate; locked so overlapping ASR callbacks cannot
    /// race the task-chain pointer. Bumped on `stop()` so earlier chained tasks
    /// (which cancellation does not reach through `await previous?.value`) bail
    /// before `handleTranscript`.
    private let transcriptLock = NSLock()
    private var transcriptSerialTask: Task<Void, Never>?
    private var transcriptEpoch: UInt64 = 0

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
    /// The physical route an acquisition was last attempted for, so a failed
    /// acquisition is not retried on every gate re-evaluation but *is* retried
    /// when a different device presents the same route types (port UIDs differ).
    private var acquisitionAttemptedRoute: AudioRouteIdentity?
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
        parsedIntentObserverFactory: (@Sendable (IntentRoutingInput) -> ParsedIntentObserver?)? = nil
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
        // The ASR/router callbacks, including the serial capture path a dialog `new_command`
        // re-processes through (spec 0443b70).
        wireAsrCallbacks()
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
        .map { tuple, graceActive in
            let (setup, conflicts, context, exposure) = tuple
            return VoiceControlGate(
                setup: setup,
                conflicts: conflicts,
                context: context,
                micExposure: exposure,
                gracePeriodActive: graceActive
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

            let wasCapturing = self.isListening
            switch gate.state {
            case .off:
                self.stop()
                self.considerAcquisition(for: gate.posture)
            case .listening(let mode):
                // The acquisition's own exposure flip publishes synchronously
                // from inside `acquireExternalInput`. Cancelling here would
                // abort the very task committing the route, and its later
                // cancellation check would clear the selection and drop capture.
                if !self.isAcquiring {
                    self.cancelAcquisition()
                }
                self.start(in: mode)
            }
            self.logLifecycleTransition(posture: gate.posture, wasCapturing: wasCapturing)
        }
        .store(in: &cancellables)

        asrEngine.onRoutingInput = { [weak self] input in
            self?.enqueueRoutingInput(input, origin: nil)
        }
    }

    /// Enqueues one utterance onto the serial routing chain — the single capture path for ASR
    /// callbacks AND for a dialog `new_command` value queued by a completing turn (spec 0443b70).
    /// `origin: nil` means "capture the live window at enqueue time"; a caller that already holds
    /// the dispatch origin (the draining turn) passes it so the re-processed command belongs to the
    /// same window it was spoken in.
    private func enqueueRoutingInput(_ input: IntentRoutingInput, origin: Int? = nil) {
            self.transcriptLock.lock()
            // Drop late ASR callbacks that arrive after (or during) stop().
            guard self.isListening else {
                self.transcriptLock.unlock()
                return
            }
            let epoch = self.transcriptEpoch
            let previous = self.transcriptSerialTask
            // Capture the turn's origin and selection HERE, at the callback, BEFORE the Task is
            // created — not inside `handleRoutingInput`, which runs only after this Task has
            // awaited all previous work. A capture taken there is a capture taken AFTER the queue
            // wait, which is the attribution error this exists to prevent: a turn that queued
            // behind earlier work would be stamped with whatever window is current by the time it
            // runs, and classified by the window state then rather than by what selected it.
            let capturedOrigin = origin ?? self.gracePeriodSignal.currentGeneration()
            // The INPUT's own provenance, not a live read. `isActive` cannot tell a wake that
            // fired during grace from a follow-up inside the same grace — both arrive with grace
            // active — so the answer has to come from the gate decision that produced this input.
            let capturedSelection = input.selection
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
                    if let notifyTerminal { Task { @MainActor in notifyTerminal(input, terminal) } }
                    if terminal == .routed, let notifyFinished {
                        Task { @MainActor in notifyFinished(input) }
                    }
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
                terminal = .routed
                // The observer for THIS input, resolved here so no shared slot is involved.
                let parsedObserver = self.parsedIntentObserverFactory?(input)
                await self.handleRoutingInput(
                    input,
                    origin: capturedOrigin,
                    selection: capturedSelection,
                    parsedIntentObserver: parsedObserver
                )
            }
            self.transcriptSerialTask = task
            self.transcriptLock.unlock()
    }

    /// Wires the ASR/router callbacks (the pre-existing registration block, now a named step).
    private func wireAsrCallbacks() {
        asrEngine.onWakeWordDetected = { [weak self] in
            self?.gracePeriodSignal.onWakeWordDetected()
            self?.audioRenderer.playEarcon(.wakeWord)
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

    /// Reports the intent the ROUTER PARSED for a dispatch, BEFORE the executor runs it. Invocation
    /// local and carried on the call, like `preparedObserver`: a sink- or service-wide slot would let
    /// an overlapping dispatch overwrite another's observed intent, so the assertion could be made
    /// against the wrong turn.
    typealias ParsedIntentObserver = @MainActor (any VoiceIntent) -> Void

    func handleRoutingInput(
        _ input: IntentRoutingInput,
        origin: Int? = nil,
        selection: CloudConversationSelection? = nil,
        preparedObserver: CloudRouteSink.PreparedObserver? = nil,
        parsedIntentObserver: ParsedIntentObserver? = nil
    ) async {
        // Belt-and-suspenders with the epoch check in the serial chain: an
        // in-flight classify must not execute after capture has stopped.
        guard isListening else { return }
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
            return
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
                return
            }

            FileLog.shared.addMessage("[VoicePipeline] intent \(intent) ← '\(transcript)'")
            guard isListening else { return }
            let response = await executor.execute(intent, preparedObserver: preparedObserver)
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
                let response = await executor.execute(intent, preparedObserver: preparedObserver)
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
                enqueueRoutingInput(
                    .english(transcript: reprocessValue, selection: nil, utteranceId: input.utteranceId),
                    origin: capturedOrigin
                )
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
            guard isListening else { return }
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
                    capturedOrigin: capturedOrigin
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
                return
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
                audioRenderer.render(response)
                return
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
        let route = routeMonitor.currentRouteIdentity
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

    private func cancelAcquisition() {
        acquisitionGeneration &+= 1
        acquisitionTask?.cancel()
        acquisitionTask = nil
        // Clear the one-shot dedup: a transient blocker (call, casting, other
        // app, context loss) cancels a scheduled attempt, and the same route
        // must be retried once the blocker clears. Failure completions do not
        // call this, so a genuinely failed route is still not retried in a loop.
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
