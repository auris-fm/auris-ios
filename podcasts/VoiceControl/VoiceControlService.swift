import Combine
import Foundation

class VoiceControlService: ObservableObject {
    @Published private(set) var isListening = false
    @Published private(set) var listeningMode: ListeningMode = .wakeWord
    @Published private(set) var gateState: GateState = .off(reason: .noContext)

    private let conditionMonitor: LiveConditionMonitor
    private let routeMonitor: IOSAudioRouteMonitor
    private let asrEngine: VoiceAsrEngine
    private let wakeWordDetector: WakeWordDetectorProtocol
    private let intentRouter: FunctionGemmaIntentRouter
    private let executor: VoiceIntentExecutor
    private let dialogManager: VoiceDialogManager
    private let audioRenderer: AudioFeedbackRenderer
    private let attendedSignal: AttendedSignal
    private let gracePeriodSignal: GracePeriodSignal
    private let playbackRecencySignal: PlaybackRecencySignal

    private var cancellables = Set<AnyCancellable>()
    private var consecutiveNulls = 0
    private let maxConsecutiveNulls = 3

    init(
        conditionMonitor: LiveConditionMonitor,
        routeMonitor: IOSAudioRouteMonitor,
        asrEngine: VoiceAsrEngine,
        wakeWordDetector: WakeWordDetectorProtocol,
        intentRouter: FunctionGemmaIntentRouter,
        executor: VoiceIntentExecutor,
        dialogManager: VoiceDialogManager,
        audioRenderer: AudioFeedbackRenderer,
        attendedSignal: AttendedSignal,
        gracePeriodSignal: GracePeriodSignal,
        playbackRecencySignal: PlaybackRecencySignal
    ) {
        self.conditionMonitor = conditionMonitor
        self.routeMonitor = routeMonitor
        self.asrEngine = asrEngine
        self.wakeWordDetector = wakeWordDetector
        self.intentRouter = intentRouter
        self.executor = executor
        self.dialogManager = dialogManager
        self.audioRenderer = audioRenderer
        self.attendedSignal = attendedSignal
        self.gracePeriodSignal = gracePeriodSignal
        self.playbackRecencySignal = playbackRecencySignal

        TouchEventMonitor.shared.touchEvent
            .sink { [weak self] in self?.attendedSignal.onUserInteraction() }
            .store(in: &cancellables)

        NotificationCenter.default
            .publisher(for: Constants.Notifications.playbackStarted)
            .map { _ in true }
            .merge(with: NotificationCenter.default
                .publisher(for: Constants.Notifications.playbackPaused)
                .map { _ in false }
            )
            .sink { [weak self] isPlaying in
                self?.playbackRecencySignal.update(isPlaying: isPlaying)
            }
            .store(in: &cancellables)
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
                attendedSignal: attendedSignal,
                gracePeriodSignal: gracePeriodSignal,
                playbackRecencySignal: playbackRecencySignal
            ).state
        }
        .sink { [weak self] state in
            self?.gateState = state
            switch state {
            case .off:
                self?.stop()
            case .listening(let mode):
                self?.start(in: mode)
            }
        }
        .store(in: &cancellables)

        asrEngine.onTranscript = { [weak self] transcript in
            Task { await self?.handleTranscript(transcript) }
        }
    }

    private func start(in mode: ListeningMode) {
        guard !isListening else {
            listeningMode = mode
            return
        }
        asrEngine.start()
        isListening = true
        listeningMode = mode
        if mode == .wakeWord {
            audioRenderer.playEarcon(.listeningStart)
        }
    }

    func stop() {
        asrEngine.stop()
        isListening = false
    }

    func handleTranscript(_ transcript: String) async {
        let dialogContext = dialogManager.pendingDialog
        guard let intent = intentRouter.classify(transcript: transcript, pendingDialog: dialogContext) else {
            consecutiveNulls += 1
            if consecutiveNulls >= maxConsecutiveNulls {
                audioRenderer.playEarcon(.error)
                consecutiveNulls = 0
            }
            return
        }
        consecutiveNulls = 0
        let response = await executor.execute(intent)
        audioRenderer.render(response)
    }
}
