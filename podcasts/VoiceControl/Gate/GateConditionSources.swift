import CallKit
import UIKit
import AVFoundation
import Combine
import PocketCastsUtils

protocol GateConditionSource {
    var current: GateCondition { get }
    var publisher: AnyPublisher<GateCondition, Never> { get }
}

class CallConditionSource: GateConditionSource {
    private let observer: CXCallObserver

    init(observer: CXCallObserver = CXCallObserver()) {
        self.observer = observer
    }

    var current: GateCondition {
        observer.calls.isEmpty ? .allowed : .blocked(reason: "call_in_progress")
    }

    var publisher: AnyPublisher<GateCondition, Never> {
        NotificationCenter.default
            .publisher(for: NSNotification.Name("CXCallObserverCallChanged"))
            .map { [weak self] _ in self?.current ?? .unknown(reason: "uninitialized") }
            .eraseToAnyPublisher()
    }
}

class BatteryConditionSource: GateConditionSource {
    var current: GateCondition {
        ProcessInfo.processInfo.isLowPowerModeEnabled
            ? .blocked(reason: "low_power_mode")
            : .allowed
    }

    var publisher: AnyPublisher<GateCondition, Never> {
        NotificationCenter.default
            .publisher(for: .NSProcessInfoPowerStateDidChange)
            .map { _ in self.current }
            .eraseToAnyPublisher()
    }
}

class CastingConditionSource: GateConditionSource {
    var current: GateCondition {
        let isMirroring = AVAudioSession.sharedInstance().currentRoute.outputs
            .contains { $0.portType == .airPlay }
        return isMirroring ? .blocked(reason: "airplay_mirroring") : .allowed
    }

    var publisher: AnyPublisher<GateCondition, Never> {
        NotificationCenter.default
            .publisher(for: AVAudioSession.routeChangeNotification)
            .map { _ in self.current }
            .eraseToAnyPublisher()
    }
}

class OtherAppPlayingConditionSource: GateConditionSource {
    var current: GateCondition {
        AVAudioSession.sharedInstance().isOtherAudioPlaying
            ? .blocked(reason: "other_app_playing")
            : .allowed
    }

    var publisher: AnyPublisher<GateCondition, Never> {
        Publishers.Merge(
            NotificationCenter.default
                .publisher(for: AVAudioSession.silenceSecondaryAudioHintNotification),
            NotificationCenter.default
                .publisher(for: AVAudioSession.routeChangeNotification)
        )
        .debounce(for: .milliseconds(500), scheduler: RunLoop.main)
        .map { [weak self] _ in self?.current ?? .unknown(reason: "uninitialized") }
        .eraseToAnyPublisher()
    }
}

class ForegroundConditionSource: GateConditionSource {
    private let gracePeriodSignal: GracePeriodSignal

    init(gracePeriodSignal: GracePeriodSignal) {
        self.gracePeriodSignal = gracePeriodSignal
    }

    var current: GateCondition {
        UIApplication.shared.applicationState == .active ? .allowed : .blocked(reason: "backgrounded")
    }

    var publisher: AnyPublisher<GateCondition, Never> {
        NotificationCenter.default
            .publisher(for: UIApplication.didBecomeActiveNotification)
            .merge(with: NotificationCenter.default
                .publisher(for: UIApplication.willResignActiveNotification)
                .handleEvents(receiveOutput: { [weak self] _ in
                    self?.gracePeriodSignal.onAppBackgrounded()
                })
            )
            .map { _ in self.current }
            .eraseToAnyPublisher()
    }
}

class LiveConditionMonitor: ObservableObject {
    @Published var setup: GateSetup = .init(
        enabledByUser: .allowed,
        deviceSupported: .allowed,
        modelsReady: .allowed
    )
    @Published var conflicts: GateConflicts = .init(
        notOnCall: .allowed,
        notCasting: .allowed,
        batteryOk: .allowed,
        otherAppPlaying: .allowed
    )
    @Published var context: GateContext = .appInForeground

    private let callSource = CallConditionSource()
    private let batterySource = BatteryConditionSource()
    private let castingSource = CastingConditionSource()
    private let otherAppPlayingSource = OtherAppPlayingConditionSource()
    private let foregroundSource: ForegroundConditionSource
    private let gracePeriodSignal: GracePeriodSignal

    private var cancellables = Set<AnyCancellable>()

    /// Foreground loss collapses the context to `.none` — EXCEPT while an active cloud/answer
    /// hold keeps the window open (owner delta 8fe04cd/0aa4480): the answer must be able to finish
    /// in the background, so the app still has a listening context. Capture permission itself is
    /// the gate's `.isolated` decision, unchanged.
    static func resolveContext(foregroundAllowed: Bool, holdActive: Bool) -> GateContext {
        (foregroundAllowed || holdActive) ? .appInForeground : .none
    }

    init(gracePeriodSignal: GracePeriodSignal) {
        self.foregroundSource = ForegroundConditionSource(gracePeriodSignal: gracePeriodSignal)
        self.gracePeriodSignal = gracePeriodSignal
        bind()
    }

    private func bind() {
        callSource.publisher
            .sink { [weak self] in
                guard let self else { return }
                FileLog.shared.addMessage("[VoicePipeline] Call: \($0)")
                self.conflicts = GateConflicts(
                    notOnCall: $0,
                    notCasting: self.conflicts.notCasting,
                    batteryOk: self.conflicts.batteryOk,
                    otherAppPlaying: self.conflicts.otherAppPlaying
                )
            }
            .store(in: &cancellables)

        batterySource.publisher
            .sink { [weak self] in
                guard let self else { return }
                FileLog.shared.addMessage("[VoicePipeline] Battery: \($0)")
                self.conflicts = GateConflicts(
                    notOnCall: self.conflicts.notOnCall,
                    notCasting: self.conflicts.notCasting,
                    batteryOk: $0,
                    otherAppPlaying: self.conflicts.otherAppPlaying
                )
            }
            .store(in: &cancellables)

        castingSource.publisher
            .sink { [weak self] in
                guard let self else { return }
                FileLog.shared.addMessage("[VoicePipeline] Casting: \($0)")
                self.conflicts = GateConflicts(
                    notOnCall: self.conflicts.notOnCall,
                    notCasting: $0,
                    batteryOk: self.conflicts.batteryOk,
                    otherAppPlaying: self.conflicts.otherAppPlaying
                )
            }
            .store(in: &cancellables)

        otherAppPlayingSource.publisher
            .sink { [weak self] in
                guard let self else { return }
                FileLog.shared.addMessage("[VoicePipeline] OtherAppPlaying: \($0)")
                self.conflicts = GateConflicts(
                    notOnCall: self.conflicts.notOnCall,
                    notCasting: self.conflicts.notCasting,
                    batteryOk: self.conflicts.batteryOk,
                    otherAppPlaying: $0
                )
            }
            .store(in: &cancellables)

        Publishers.CombineLatest(
            foregroundSource.publisher,
            Just(GateContext.none) // playback context will be merged separately
        )
        .map { [weak self] foregroundCondition, _ in
            Self.resolveContext(foregroundAllowed: foregroundCondition.isAllowed,
                                holdActive: self?.gracePeriodSignal.hasActiveHold ?? false)
        }
        .sink { [weak self] in
            FileLog.shared.addMessage("[VoicePipeline] Context: \($0)")
            self?.context = $0
        }
        .store(in: &cancellables)
    }

    func updateModelsReady(_ condition: GateCondition) {
        FileLog.shared.addMessage("[VoicePipeline] ModelsReady: \(condition)")
        setup = GateSetup(
            enabledByUser: setup.enabledByUser,
            deviceSupported: setup.deviceSupported,
            modelsReady: condition
        )
    }

    func updateUserEnabled(_ enabled: Bool) {
        FileLog.shared.addMessage("[VoicePipeline] UserEnabled: \(enabled)")
        setup = GateSetup(
            enabledByUser: enabled ? .allowed : .blocked(reason: "user_disabled"),
            deviceSupported: setup.deviceSupported,
            modelsReady: setup.modelsReady
        )
    }
}
