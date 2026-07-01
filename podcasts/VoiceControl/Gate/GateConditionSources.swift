import CallKit
import UIKit
import AVFoundation
import Combine

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
            .publisher(for: .CXCallObserverCallChanged)
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
        NotificationCenter.default
            .publisher(for: AVAudioSession.silenceSecondaryAudioHintNotification)
            .debounce(for: .milliseconds(500), scheduler: RunLoop.main)
            .map { [weak self] _ in self?.current ?? .unknown(reason: "uninitialized") }
            .eraseToAnyPublisher()
    }
}

class ForegroundConditionSource: GateConditionSource {
    var current: GateCondition {
        UIApplication.shared.applicationState == .active ? .allowed : .blocked(reason: "backgrounded")
    }

    var publisher: AnyPublisher<GateCondition, Never> {
        NotificationCenter.default
            .publisher(for: UIApplication.didBecomeActiveNotification)
            .merge(with: NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification))
            .map { _ in self.current }
            .eraseToAnyPublisher()
    }
}

class LiveConditionMonitor: ObservableObject {
    @Published var setup: GateSetup = .init(
        enabledByUser: .unknown(reason: "initializing"),
        deviceSupported: .unknown(reason: "initializing"),
        modelsReady: .unknown(reason: "initializing")
    )
    @Published var conflicts: GateConflicts = .init(
        notOnCall: .unknown(reason: "initializing"),
        notCasting: .unknown(reason: "initializing"),
        batteryOk: .unknown(reason: "initializing"),
        otherAppPlaying: .unknown(reason: "initializing")
    )
    @Published var context: GateContext = .none

    private let callSource = CallConditionSource()
    private let batterySource = BatteryConditionSource()
    private let castingSource = CastingConditionSource()
    private let otherAppPlayingSource = OtherAppPlayingConditionSource()
    private let foregroundSource = ForegroundConditionSource()

    private var cancellables = Set<AnyCancellable>()

    init() { bind() }

    private func bind() {
        callSource.publisher
            .sink { [weak self] in
                guard let self else { return }
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
        .map { foregroundCondition, _ in
            foregroundCondition.isAllowed ? GateContext.appInForeground : GateContext.none
        }
        .sink { [weak self] in self?.context = $0 }
        .store(in: &cancellables)
    }

    func updateModelsReady(_ condition: GateCondition) {
        setup = GateSetup(
            enabledByUser: setup.enabledByUser,
            deviceSupported: setup.deviceSupported,
            modelsReady: condition
        )
    }

    func updateUserEnabled(_ enabled: Bool) {
        setup = GateSetup(
            enabledByUser: enabled ? .allowed : .blocked(reason: "user_disabled"),
            deviceSupported: setup.deviceSupported,
            modelsReady: setup.modelsReady
        )
    }
}
