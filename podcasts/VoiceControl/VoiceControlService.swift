import AVFoundation
import Combine
import Foundation
import PocketCastsUtils

class VoiceControlService: ObservableObject {
    @Published private(set) var isListening = false
    @Published private(set) var listeningMode: ListeningMode = .wakeWord
    @Published private(set) var gateState: GateState = .off(reason: .noContext)
    @Published private(set) var gatePosture: GatePosture = GatePosture(
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
    private let intentRouter: FunctionGemmaIntentRouter
    private let executor: VoiceIntentExecutor
    private let dialogManager: VoiceDialogManager
    private let audioRenderer: AudioFeedbackRenderer
    private let gracePeriodSignal: GracePeriodSignal

    private let log = Logger(subsystem: "com.pocketcasts", category: "VoiceControl")

    private var cancellables = Set<AnyCancellable>()
    private var consecutiveNulls = 0
    private let maxConsecutiveNulls = 3

    // Command debounce: skip intents of the same type within 2 seconds
    private var lastIntentType: String?
    private var lastExecutionTime: Date?
    private let debounceInterval: TimeInterval = 2.0

    // Track prior capture state for lifecycle logging
    private var priorCaptureActive = false
    private var priorListingMode: ListeningMode? = nil
    private var priorPostureBlockers: [String] = []
    private var priorMicExposure: MicExposure = .noMic
    private var priorRoute: AudioRoute = .unknown

    init(
        conditionMonitor: LiveConditionMonitor,
        routeMonitor: IOSAudioRouteMonitor,
        interruptionHandler: AudioSessionInterruptionHandler,
        asrEngine: VoiceAsrEngine,
        wakeWordDetector: WakeWordDetectorProtocol,
        intentRouter: FunctionGemmaIntentRouter,
        executor: VoiceIntentExecutor,
        dialogManager: VoiceDialogManager,
        audioRenderer: AudioFeedbackRenderer,
        gracePeriodSignal: GracePeriodSignal
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

        interruptionHandler.onInterruptionBegan = { [weak self] in
            self?.stop()  // stops capture, discards current pipeline state
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

            // Log posture transitions (blocker changes only, not every Combine publish)
            let posture = gate.posture
            let currentBlockers = self.blockers(for: posture)
            let isActiveCapture = gate.state.isListening && self.isListening
            let currentRoute = self.routeMonitor.currentRoute
            if currentBlockers != self.priorPostureBlockers ||
               posture.micExposure != self.priorMicExposure ||
               isActiveCapture != self.priorCaptureActive ||
               gate.state.listeningMode != self.priorListingMode ||
               currentRoute != self.priorRoute {
                self.logLifecycleEvent(
                    posture: posture,
                    priorCaptureActive: self.priorCaptureActive,
                    newCaptureActive: isActiveCapture,
                    currentBlockers: currentBlockers,
                    priorBlockers: self.priorPostureBlockers,
                    route: currentRoute
                )
                self.priorCaptureActive = isActiveCapture
                self.priorPostureBlockers = currentBlockers
                self.priorMicExposure = posture.micExposure
                self.priorListingMode = gate.state.listeningMode
                self.priorRoute = currentRoute
            }

            if gateDescription(previous) != gateDescription(gate.state) {
                FileLog.shared.addMessage("[VoiceControl] Gate: \(gateDescription(previous)) → \(gateDescription(gate.state))")
            }
            switch gate.state {
            case .off:
                self.stop()
            case .listening(let mode):
                self.start(in: mode)
            }
        }
        .store(in: &cancellables)

        asrEngine.onTranscript = { [weak self] transcript in
            Task { await self?.handleTranscript(transcript) }
        }

        asrEngine.onWakeWordDetected = { [weak self] in
            self?.gracePeriodSignal.onWakeWordDetected()
            self?.audioRenderer.playEarcon(.wakeWord)
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
    }

    func handleTranscript(_ transcript: String) async {
        let dialogContext = dialogManager.pendingDialog
        let result = intentRouter.classify(transcript: transcript, pendingDialog: dialogContext)

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
            lastIntentType = intentType
            lastExecutionTime = Date()
            audioRenderer.render(response)

        case .dialogControl(let action):
            consecutiveNulls = 0
            FileLog.shared.addMessage("[VoiceControl] Dialog: \(action) — \"\(transcript)\"")
            let dialogResult = dialogManager.handle(action)

            if let intent = dialogResult.intent {
                let response = await executor.execute(intent)
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

    // MARK: - Lifecycle logging

    /// Returns the ordered list of blocking reasons from the posture.
    private func blockers(for posture: GatePosture) -> [String] {
        var reasons: [String] = []
        if posture.offReason == .setupNotReady { reasons.append("setupNotReady") }
        if posture.offReason == .conflictBlocking { reasons.append("conflictBlocking") }
        if posture.offReason == .noContext { reasons.append("noContext") }
        if posture.offReason == .noMicrophone { reasons.append("noMicrophone") }
        return reasons
    }

    /// Log a lifecycle event when posture or blocker state changes.
    /// Blocked posture with no prior capture, or user-requested active stop → info.
    /// Every other active-capture stop → error.
    private func logLifecycleEvent(
        posture: GatePosture,
        priorCaptureActive: Bool,
        newCaptureActive: Bool,
        currentBlockers: [String],
        priorBlockers: [String],
        route: AudioRoute
    ) {
        let event: String
        if newCaptureActive {
            event = "capture_started"
        } else if !posture.allowed && priorCaptureActive {
            // Active capture stopping because of a blocker
            event = "capture_blocked"
        } else if !posture.allowed && !priorCaptureActive {
            // Already blocked, just posture change
            event = "posture_blocked"
        } else if posture.allowed && !newCaptureActive {
            // Gate allowed but not capturing yet (initial state or mode switch)
            event = "posture_allowed"
        } else if priorBlockers.isEmpty && !currentBlockers.isEmpty {
            event = "blocker_appeared"
        } else if !priorBlockers.isEmpty && currentBlockers.isEmpty {
            event = "blocker_cleared"
        } else {
            event = "posture_changed"
        }

        let level: OSLogType
        if event == "capture_blocked" {
            // Blocked posture with prior capture active
            if currentBlockers.contains("setupNotReady") || currentBlockers.contains("noContext") {
                // User-requested or expected stop → info
                level = .info
            } else {
                // Unexpected stop (conflict, no mic) → error
                level = .error
            }
        } else if event == "capture_started" || event == "posture_allowed" || event == "blocker_cleared" {
            level = .info
        } else {
            level = .info
        }

        // Build log message with stable ordered fields.
        // No audio or transcript text is ever included.
        // Indirectly identifying metadata (route details) is marked private.
        let modeString = posture.listeningMode.map { "\($0)" } ?? "none"
        let blockersString = currentBlockers.joined(separator: ",")
        let routeString = "\(route.output):\(route.input.map { "\($0)" } ?? "nil")"

        log.log(
            level: level,
            """
            event=\(event, privacy: .public) \
            reasons=\(blockersString, privacy: .public) \
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
