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
    private let analytics: VoiceAnalytics

    private var latestStageTiming: PipelineStageTiming?
    private var latestRouterMetrics: RouterClassificationMetrics?

    private let log = Logger(subsystem: "com.pocketcasts", category: "VoiceControl")

    private var cancellables = Set<AnyCancellable>()
    private var consecutiveNulls = 0
    private let maxConsecutiveNulls = 3
    /// Serializes classify+generate; locked so overlapping ASR callbacks cannot
    /// race the task-chain pointer, and cancelled on `stop()`.
    private let transcriptLock = NSLock()
    private var transcriptSerialTask: Task<Void, Never>?

    // Command debounce: skip intents of the same type within 2 seconds
    private var lastIntentType: String?
    private var lastExecutionTime: Date?
    private let debounceInterval: TimeInterval = 2.0

    // Last blocking reason set logged for a blocked-never-acquired posture.
    // nil when the last lifecycle event was not a non-acquiring posture, so
    // `mic_acquisition_skipped` is emitted once on entry and again only when
    // the blocking reason set changes — never on every Combine publication.
    private var loggedSkippedReasons: [String]?

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
        analytics: VoiceAnalytics
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

        interruptionHandler.onInterruptionBegan = { [weak self] in
            guard let self else { return }
            let wasCapturing = self.isListening
            self.stop()  // stops capture, discards current pipeline state
            if wasCapturing {
                // Audio session reclaimed by the system — an active-capture stop
                // that the user did not request → ERROR per the mic lifecycle spec.
                self.loggedSkippedReasons = nil
                self.emitLifecycleEvent(
                    event: "mic_capture_stopped",
                    level: .error,
                    reasons: ["audio_session_reclaimed"],
                    posture: self.gatePosture,
                    priorCaptureActive: true
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
        Publishers.CombineLatest4(
            conditionMonitor.$setup,
            conditionMonitor.$conflicts,
            conditionMonitor.$context,
            routeMonitor.$micExposure
        )
        .map { [self] setup, conflicts, context, exposure in
            VoiceControlGate(
                setup: setup,
                conflicts: conflicts,
                context: context,
                micExposure: exposure,
                gracePeriodSignal: gracePeriodSignal
            )
        }
        .sink { [weak self] gate in
            guard let self else { return }
            let previous = self.gateState
            self.gateState = gate.state
            self.gatePosture = gate.posture

            if gateDescription(previous) != gateDescription(gate.state) {
                FileLog.shared.addMessage("[VoiceControl] Gate: \(gateDescription(previous)) → \(gateDescription(gate.state))")
            }

            let wasCapturing = self.isListening
            switch gate.state {
            case .off:
                self.stop()
            case .listening(let mode):
                self.start(in: mode)
            }
            self.logLifecycleTransition(posture: gate.posture, wasCapturing: wasCapturing)
        }
        .store(in: &cancellables)

        asrEngine.onTranscript = { [weak self] transcript in
            guard let self else { return }
            self.transcriptLock.lock()
            let previous = self.transcriptSerialTask
            let task = Task { [weak self] in
                await previous?.value
                guard !Task.isCancelled else { return }
                await self?.handleTranscript(transcript)
            }
            self.transcriptSerialTask = task
            self.transcriptLock.unlock()
        }

        asrEngine.onWakeWordDetected = { [weak self] in
            self?.gracePeriodSignal.onWakeWordDetected()
            self?.audioRenderer.playEarcon(.wakeWord)
        }
        asrEngine.onWakeOnly = { [weak self] in
            self?.audioRenderer.playEarcon(.error)
        }

        asrEngine.onStageTiming = { [weak self] timing in
            self?.latestStageTiming = timing
        }
        intentRouter.onMetrics = { [weak self] metrics in
            self?.latestRouterMetrics = metrics
        }

        // Preload the intent router model so it's ready when the first transcript arrives
        Task {
            let result = await intentRouter.ensureReady()
            switch result {
            case .success:
                FileLog.shared.addMessage("[VoiceControl] Intent router ready")
                conditionMonitor.updateModelsReady(.allowed)
            case .failure(let error):
                FileLog.shared.addMessage("[VoiceControl] Intent router FAILED: \(error)")
                // A router that cannot engage must block capture rather than
                // silently returning no intent for every transcript.
                conditionMonitor.updateModelsReady(.blocked(reason: "router_not_ready"))
            }
        }
    }

    private func start(in mode: ListeningMode) {
        guard !isListening else {
            if listeningMode != mode {
                FileLog.shared.addMessage("[VoiceControl] Mode switch: \(listeningMode) → \(mode)")
                listeningMode = mode
                asrEngine.listeningMode = mode
            }
            return
        }
        FileLog.shared.addMessage("[VoiceControl] Start listening (\(mode))")
        asrEngine.listeningMode = mode
        asrEngine.start()
        isListening = true
        listeningMode = mode
        if mode == .wakeWord {
            audioRenderer.playEarcon(.listeningStart)
        }
    }

    func stop() {
        guard isListening else { return }
        FileLog.shared.addMessage("[VoiceControl] Stop listening")
        asrEngine.stop()
        isListening = false
        audioRenderer.release()
        transcriptLock.lock()
        transcriptSerialTask?.cancel()
        transcriptSerialTask = nil
        transcriptLock.unlock()
    }

    func handleTranscript(_ transcript: String) async {
        let dialogContext = dialogManager.pendingDialog
        let result = intentRouter.classify(transcript: transcript, pendingDialog: dialogContext)
        recordPipelineLatency(transcript: transcript)

        switch result {
        case .intent(let intent):
            consecutiveNulls = 0

            // Debounce: skip if same intent type was executed within the debounce window
            let intentType = String(describing: type(of: intent))
            if let lastType = lastIntentType,
               let lastTime = lastExecutionTime,
               lastType == intentType,
               Date().timeIntervalSince(lastTime) < debounceInterval {
                FileLog.shared.addMessage("[VoiceControl] Debounced \(intentType) — within \(debounceInterval)s window")
                return
            }

            FileLog.shared.addMessage("[VoiceControl] Intent: \(intentType) — \"\(transcript)\"")
            let response = await executor.execute(intent)
            gracePeriodSignal.onCommandRecognized()
            lastIntentType = intentType
            lastExecutionTime = Date()
            audioRenderer.render(response)

        case .dialogControl(let action):
            consecutiveNulls = 0
            FileLog.shared.addMessage("[VoiceControl] Dialog: \(action) — \"\(transcript)\"")
            let dialogResult = dialogManager.handle(action)

            if let intent = dialogResult.intent {
                let response = await executor.execute(intent)
                gracePeriodSignal.onCommandRecognized()
                lastIntentType = String(describing: type(of: intent))
                lastExecutionTime = Date()
                audioRenderer.render(response)
            } else if let question = dialogResult.question {
                audioRenderer.render(.spoken(question))
            }
            // If dialogResult has no intent and no question (e.g., cancel), do nothing

        case .none:
            consecutiveNulls += 1
            FileLog.shared.addMessage("[VoiceControl] Unclassified transcript (\(consecutiveNulls)/\(maxConsecutiveNulls)): \"\(transcript)\"")
            if consecutiveNulls >= maxConsecutiveNulls {
                FileLog.shared.addMessage("[VoiceControl] Too many unclassified — error earcon")
                audioRenderer.playEarcon(.error)
                consecutiveNulls = 0
            }
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

    /// Deterministically ordered blocking reason set from the posture.
    /// Gate-owned reasons use their condition names, in gate evaluation order
    /// (setup → conflicts → context → mic exposure). Unknown conditions fail
    /// closed, so they count as blocking.
    private func blockers(for posture: GatePosture) -> [String] {
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
        return reasons
    }

    /// Emit mic lifecycle events on capture-state transitions only:
    /// - capture acquired → `mic_capture_started` (INFO)
    /// - active capture stopped → `mic_capture_stopped`; INFO only when the stop
    ///   is a direct, attributable user request (voice control disabled by the
    ///   user), ERROR for every other active-capture stop
    /// - blocked and never acquired → `mic_acquisition_skipped` (INFO) once on
    ///   entry, again only when the blocking reason set changes
    private func logLifecycleTransition(posture: GatePosture, wasCapturing: Bool) {
        let isCapturing = isListening
        let reasons = blockers(for: posture)

        if isCapturing && !wasCapturing {
            loggedSkippedReasons = nil
            emitLifecycleEvent(
                event: "mic_capture_started", level: .info,
                reasons: reasons, posture: posture, priorCaptureActive: wasCapturing
            )
        } else if wasCapturing && !isCapturing {
            // The stop event already records the entry into the blocked posture;
            // remember its reason set so `mic_acquisition_skipped` only fires if
            // the blockers change afterwards.
            loggedSkippedReasons = reasons
            let userRequested = !posture.setup.enabledByUser.isAllowed
            emitLifecycleEvent(
                event: "mic_capture_stopped", level: userRequested ? .info : .error,
                reasons: reasons, posture: posture, priorCaptureActive: wasCapturing
            )
        } else if !isCapturing && !posture.allowed && reasons != loggedSkippedReasons {
            loggedSkippedReasons = reasons
            emitLifecycleEvent(
                event: "mic_acquisition_skipped", level: .info,
                reasons: reasons, posture: posture, priorCaptureActive: wasCapturing
            )
        }
    }

    /// Write one structured lifecycle event with stable, ordered fields.
    /// No audio or transcript text is ever included. Route details are
    /// indirectly identifying metadata, so they are marked private.
    private func emitLifecycleEvent(
        event: String,
        level: OSLogType,
        reasons: [String],
        posture: GatePosture,
        priorCaptureActive: Bool
    ) {
        let route = routeMonitor.currentRoute
        let modeString = posture.listeningMode.map { "\($0)" } ?? "none"
        let reasonsString = reasons.joined(separator: ",")
        let routeString = "\(route.output):\(route.input.map { "\($0)" } ?? "nil")"

        log.log(
            level: level,
            """
            event=\(event, privacy: .public) \
            reasons=\(reasonsString, privacy: .public) \
            setup=\(posture.setup.isReady, privacy: .public) \
            conflicts=\(posture.conflicts.isClear, privacy: .public) \
            context=\(String(describing: posture.context), privacy: .public) \
            micExposure=\(String(describing: posture.micExposure), privacy: .public) \
            route=\(routeString, privacy: .private) \
            listeningMode=\(modeString, privacy: .public) \
            priorCapture=\(priorCaptureActive, privacy: .public)
            """
        )
    }
}

private func gateDescription(_ state: GateState) -> String {
    switch state {
    case .off(let reason): return "off(\(reason))"
    case .listening(let mode): return "listening(\(mode))"
    }
}
