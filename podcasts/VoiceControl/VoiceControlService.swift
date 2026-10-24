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
    private let intentRouter: any IntentClassifying
    private let executor: any VoiceIntentExecuting
    private let dialogManager: VoiceDialogManager
    private let audioRenderer: AudioFeedbackRenderer
    private let gracePeriodSignal: GracePeriodSignal
    /// The collector that records this capture's observations. Optional so tests and any caller that
    /// does not run voice-sharing work unchanged; routing/execution are reported through it when present.
    private let contributionCollector: VoiceSharingCollector?
    /// Injected for the routing/execution provenance controls; production uses `contributionCollector`.
    var contributionCollectorForTesting: VoiceSharingCollector? { contributionCollector }
    private let analytics: VoiceAnalytics
    /// Whether the app is playing through the shared `AVAudioSession`. Used so a
    /// failed/cancelled acquisition never deactivates the session playback owns.
    /// `AVAudioSession` exposes no active-state query and the category is not an
    /// activity signal, so playback state is the reliable in-use signal.
    private let isPlaybackActive: () -> Bool

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
        intentRouter: any IntentClassifying,
        executor: any VoiceIntentExecuting,
        dialogManager: VoiceDialogManager,
        audioRenderer: AudioFeedbackRenderer,
        gracePeriodSignal: GracePeriodSignal,
        analytics: VoiceAnalytics,
        contributionCollector: VoiceSharingCollector? = nil,
        isPlaybackActive: @escaping () -> Bool = { PlaybackManager.shared.isAudioSessionInUse }
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
        self.analytics = analytics
        self.isPlaybackActive = isPlaybackActive
        self.contributionCollector = contributionCollector

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

        asrEngine.onRoutingInput = { [weak self] input, captureContext in
            guard let self else { return }
            self.transcriptLock.lock()
            // Drop late ASR callbacks that arrive after (or during) stop().
            guard self.isListening else {
                self.transcriptLock.unlock()
                return
            }
            let epoch = self.transcriptEpoch
            let previous = self.transcriptSerialTask
            // Captured OUTSIDE the task, so the collector outlives the service. A task that finds
            // `self` released can then still settle its capture: passing nil into the abandon path left
            // the record owned by nobody and it never published (review 59841fbc).
            let collectorForAbandonment = self.contributionCollector
            let task = Task { [weak self] in
                await previous?.value
                // This capture was handed to THIS task. If the task is abandoned while queued behind
                // its predecessor, it still owns the record and must release it, or the capture never
                // publishes (review a7dfe013 #3). Reported as cancelled, because that is what happened.
                func abandonCapture(_ collector: VoiceSharingCollector?) {
                    guard let captureContext, let collector else { return }
                    collector.engineReported(
                        stage: "execution",
                        outcome: .init(state: "cancelled", reason: "cancelled_by_user"),
                        context: captureContext)
                    collector.finalizeDeferredCompletion(context: captureContext)
                }
                guard !Task.isCancelled else {
                    abandonCapture(self?.contributionCollector ?? collectorForAbandonment)
                    return
                }
                guard let self else {
                    // The service itself was released. The collector captured above can still report and
                    // release the record on its behalf.
                    abandonCapture(collectorForAbandonment)
                    return
                }
                self.transcriptLock.lock()
                let stillCurrent = self.isListening && self.transcriptEpoch == epoch
                self.transcriptLock.unlock()
                guard stillCurrent else {
                    abandonCapture(self.contributionCollector)
                    return
                }
                // `handleRoutingInput` releases the record itself, on every exit path (its own
                // `defer`). Finalizing here as well would release it twice.
                await self.handleRoutingInput(input, captureContext: captureContext)
            }
            self.transcriptSerialTask = task
            self.transcriptLock.unlock()
        }

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
    func handleTranscript(_ transcript: String) async {
        await handleRoutingInput(.english(transcript: transcript))
    }

    /// What the executor's returned response actually establishes (review a7dfe013 #2, narrowed by spec
    /// 012b19dd). `VoiceResponse` says what to PRESENT, which is not the same as what execution did, so
    /// only the ONE value the executor itself treats as failure is allowed to conclude anything.
    ///
    /// `.earcon(.error)` is that value: the executor logs "Command failed" and withholds the grace period
    /// on exactly this case, so reporting it as failed/`action_failed` repeats the executor's own verdict.
    /// Everything else — including `.silent` and `.confirmRequired` — is a presentation choice that does
    /// not record whether the action ran, so it is reported as `observation_unavailable` with `unknown`
    /// state rather than inventing a refusal or an action failure.
    private static func executionOutcome(
        for response: VoiceResponse
    ) -> VoiceSharingContributionEncoder.StageOutcome {
        switch response {
        case .earcon(.error):
            return .init(state: "failed", reason: "action_failed")
        default:
            return .init(state: "unknown", reason: "observation_unavailable")
        }
    }

    /// The routing verdict once execution has finished: the disposition is no longer pending.
    private static func settledDisposition(
        for outcome: VoiceSharingContributionEncoder.StageOutcome
    ) -> String {
        switch outcome.state {
        case "failed": return "failed"
        // `unknown` cannot claim a disposition either: the turn finished, but what became of it was not
        // observed, so the routing verdict stays honest about that rather than guessing.
        case "unknown": return "pending"
        default: return "refused"
        }
    }

    #if DEBUG
    /// Test seam: put the service in the listening state the routing branches require, without starting
    /// audio. Only the flag moves — no route, no capture, no wake detector.
    func enterListeningStateForTesting() {
        isListening = true
    }
    #endif

    #if DEBUG
    /// Test seam: the PRODUCTION interpreter, so a control cannot restate the mapping and pass alone.
    static func executionOutcomeForTesting(_ response: VoiceResponse)
        -> VoiceSharingContributionEncoder.StageOutcome {
        executionOutcome(for: response)
    }

    static func settledDispositionForTesting(
        _ outcome: VoiceSharingContributionEncoder.StageOutcome) -> String {
        settledDisposition(for: outcome)
    }
    #endif

    /// Reports BOTH stages for a turn that reached the executor. Routing's disposition is corrected
    /// from `pending` to its terminal value, which is why it is reported a second time.
    private func reportExecution(
        _ response: VoiceResponse,
        captureContext: VoiceSharingCollector.CaptureContext?
    ) {
        let outcome = Self.executionOutcome(for: response)
        let verdict = Self.settledDisposition(for: outcome)
        contributionCollector?.engineReported(
            stage: "routing",
            outcome: .init(state: "completed", reason: nil,
                           routingDisposition: verdict),
            context: captureContext)
        // The executor's own verdict, from the same decision the disposition derives from — the
        // `outcome` member states what execution concluded, not what was presented.
        contributionCollector?.engineReported(
            stage: "execution",
            outcome: .init(state: outcome.state, reason: outcome.reason,
                           text: outcome.text, decision: outcome.decision,
                           translatedText: outcome.translatedText,
                           targetLanguage: outcome.targetLanguage,
                           routingDisposition: outcome.routingDisposition,
                           outcome: verdict),
            context: captureContext)
    }

    /// FINDING a7dfe013 #3: this method took ownership of the deferred record and could return
    /// without reporting. A capture left owned-but-unreported never publishes, so every early exit
    /// must SETTLE it — cancelled if the turn was abandoned, else with whatever is true of that exit.
    private func settleOwnedCapture(
        _ context: VoiceSharingCollector.CaptureContext?,
        cancelled: Bool,
        reason: String?
    ) {
        guard let context else { return }
        contributionCollector?.engineReported(
            stage: "execution",
            outcome: .init(state: cancelled ? "cancelled" : "not_run", reason: reason),
            context: context)
    }

    func handleRoutingInput(_ input: IntentRoutingInput,
                            captureContext: VoiceSharingCollector.CaptureContext? = nil) async {
        // The engine handed this method ownership of the deferred record, so the RELEASE is
        // structural: `defer` covers every return below, including ones added later. Reporting
        // still has to happen per path above; releasing cannot be forgotten.
        defer {
            if captureContext != nil {
                contributionCollector?.finalizeDeferredCompletion(context: captureContext)
            }
        }
        // Belt-and-suspenders with the epoch check in the serial chain: an
        // in-flight classify must not execute after capture has stopped.
        guard isListening else {
            settleOwnedCapture(captureContext, cancelled: true, reason: "cancelled_by_user")
            return
        }
        let dialogContext = dialogManager.pendingDialog
        let transcript = input.routerTranscript

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
            // ENGINE-PRODUCED OBSERVATION: routing was deliberately not entered because there was no
            // command text. `no_candidates` is the routing reason that states exactly that — there was
            // nothing to classify. (`no_text` belongs to the translation stage, not this one.)
            contributionCollector?.engineReported(
                stage: "routing", outcome: .init(state: "not_run", reason: "no_candidates"),
                context: captureContext)
            contributionCollector?.engineReported(
                stage: "execution", outcome: .init(state: "not_run", reason: "client_refused"),
                context: captureContext)
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
            // Stamp a model-chosen cloud route with the window it runs under, so
            // its completion can be judged against that window rather than against
            // whatever is current when the network call returns.
            var intent = rawIntent
            if let route = rawIntent as? CloudRouteIntent, route.generation == nil {
                intent = CloudRouteIntent(
                    request: route.request,
                    tier: route.tier,
                    origin: route.origin,
                    generation: gracePeriodSignal.currentGeneration()
                )
            }

            // Debounce: skip if same intent type was executed within the debounce window
            let intentType = String(describing: type(of: intent))
            if let lastType = lastIntentType,
               let lastTime = lastExecutionTime,
               lastType == intentType,
               Date().timeIntervalSince(lastTime) < debounceInterval {
                FileLog.shared.addMessage("[VoicePipeline] debounce \(intentType)")
                // Debounced: the turn ran, the repeated action was suppressed. No executor ran, so this
                // is the client declining to act — an ENUMERATED reason. (`nothing_to_do` was invented
                // and the payload validation refuses it, which would have dropped the record.)
                settleOwnedCapture(captureContext, cancelled: false, reason: "client_refused")
                return
            }

            FileLog.shared.addMessage("[VoicePipeline] intent \(intent) ← '\(transcript)'")
            // The router chose an intent: routing RAN and produced a decision. predicted_intent and
            // predicted_tool are the SAME canonical names analytics records, so the record and the
            // analytics event cannot disagree about what was classified.
            contributionCollector?.engineReported(
                stage: "routing",
                outcome: .init(state: "completed", reason: nil,
                               routingDisposition: "pending",
                               predictedIntent: "\(VoiceAnalytics.toolName(from: intent)).\(VoiceAnalytics.actionName(from: intent))",
                               predictedTool: VoiceAnalytics.toolName(from: intent)),
                context: captureContext)
            guard isListening else {
                settleOwnedCapture(captureContext, cancelled: true, reason: "cancelled_by_user")
                return
            }
            let response = await executor.execute(intent)
            // A RETURNED response is not a performed action: `.earcon(.error)` is a failure and
            // `.silent`/`.confirmRequired` are refusals. The report carries what the executor said.
            reportExecution(response, captureContext: captureContext)
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
            // The dialog manager decided: routing ran and produced a control action.
            contributionCollector?.engineReported(
                stage: "routing",
                outcome: .init(state: "completed", reason: nil,
                               routingDisposition: "pending"),
                context: captureContext)
            let dialogResult = dialogManager.handle(action)

            if let intent = dialogResult.intent {
                let response = await executor.execute(intent)
                reportExecution(response, captureContext: captureContext)
                gracePeriodSignal.onCommandRecognized()
                lastIntentType = String(describing: type(of: intent))
                lastExecutionTime = Date()
                audioRenderer.render(response)
            } else if let question = dialogResult.question {
                // A question means NOTHING was executed: execution did not run for this turn.
                contributionCollector?.engineReported(
                    stage: "execution",
                    outcome: .init(state: "not_run", reason: "client_refused"),
                    context: captureContext)
                audioRenderer.render(.spoken(question))
            }
            // If dialogResult has no intent and no question (e.g., cancel), nothing was executed —
            // but the record still needs releasing.
            if dialogResult.intent == nil && dialogResult.question == nil {
                settleOwnedCapture(captureContext, cancelled: false, reason: "client_refused")
            }

        case .none:
            let stage = turnMetrics?.failedStage ?? "?"
            let reason = turnMetrics?.reason
            // The router RAN and returned no intent. Classifying that as "no candidates" would be a
            // guess about WHY, so the observed fact — routing completed with a negative verdict —
            // goes in the decision field, exactly as the wake stage does.
            contributionCollector?.engineReported(
                stage: "routing",
                outcome: .init(state: "completed", reason: nil,
                               routingDisposition: "not_run"),
                context: captureContext)
            contributionCollector?.engineReported(
                stage: "execution",
                outcome: .init(state: "not_run", reason: "client_refused"),
                context: captureContext)

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
                dispatchGeneration = gracePeriodSignal.claimEscalationBudget()
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
                // Escalation was refused by policy: execution did not run.
                settleOwnedCapture(captureContext, cancelled: false, reason: "precondition_failed")
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
                        origin: .routingFailure,
                        generation: dispatchGeneration
                    )
                )
                // FINDING a7dfe013 #1: this branch really does dispatch a CloudRouteIntent, so the
                // earlier "no execution" report was wrong. Routing's disposition and execution are
                // corrected to what the dispatch actually produced.
                reportExecution(response, captureContext: captureContext)
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
            // Nothing was executed and no dispatch happened; release the record.
            settleOwnedCapture(captureContext, cancelled: false, reason: "client_refused")
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
