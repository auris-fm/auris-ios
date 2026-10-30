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
            .handleEvents(receiveOutput: { [weak self] _ in
                self?.gracePeriodSignal.onAppForegrounded()
            })
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

/// Publishes whether an ELIGIBLE playback context exists (an episode loaded — playing or paused).
/// Not a hold, and not a grace window: the owning spec allows context only from real sources.
struct PlaybackContextConditionSource {
    let publisher: AnyPublisher<Bool, Never>

    /// The PRODUCTION publisher: re-samples the REAL provider on real playback events (track
    /// change = episode loaded/cleared; playback ended). Assembly and controls share this one
    /// construction so the tested path is the shipped path.
    static func production(provider: @escaping () -> Bool) -> PlaybackContextConditionSource {
        PlaybackContextConditionSource(
            publisher: Publishers.Merge(
                NotificationCenter.default.publisher(for: Constants.Notifications.playbackTrackChanged).map { _ in () },
                NotificationCenter.default.publisher(for: Constants.Notifications.playbackEnded).map { _ in () }
            )
            .map { _ in provider() }
            .prepend(provider())
            .removeDuplicates()
            .eraseToAnyPublisher()
        )
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
    /// Kept for the context-loss retirement path: the gate resolving to `.none` retires the
    /// grace window through the signal (no separate lifecycle notification exists for it).
    private let gracePeriodSignal: GracePeriodSignal
    private let playbackContextSource: PlaybackContextConditionSource?

    private var cancellables = Set<AnyCancellable>()

    /// The owning core spec: the gate context comes from ACTUAL foreground OR a current ELIGIBLE
    /// playback context (an episode loaded, playing or paused) — nothing else. A cloud/grace hold
    /// is NEITHER: it must not manufacture foreground, or capture would stay allowed after the
    /// last genuine context is gone (spec 3893cd55; the same grace-as-context defect Android
    /// removed). Foreground loss is therefore preserved only while an independent playback
    /// context still allows capture.
    static func resolveContext(foregroundAllowed: Bool, playbackContextAvailable: Bool) -> GateContext {
        if foregroundAllowed && playbackContextAvailable { return .both }
        if playbackContextAvailable { return .playbackActive }
        if foregroundAllowed { return .appInForeground }
        return .none
    }

    init(gracePeriodSignal: GracePeriodSignal, playbackContextPublisher: AnyPublisher<Bool, Never>? = nil) {
        self.foregroundSource = ForegroundConditionSource(gracePeriodSignal: gracePeriodSignal)
        self.gracePeriodSignal = gracePeriodSignal
        self.playbackContextSource = playbackContextPublisher.map { PlaybackContextConditionSource(publisher: $0) }
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

        // Context = actual foreground OR an eligible playback context. The playback publisher is
        // merged so a context change (episode loaded/cleared, paused or playing) refreshes the
        // gate — a hold must never be the source.
        let playbackPublisher = playbackContextSource?.publisher
            ?? Just(false).eraseToAnyPublisher()
        Publishers.CombineLatest(
            foregroundSource.publisher,
            playbackPublisher
        )
        .map { foregroundCondition, playbackAvailable in
            Self.resolveContext(foregroundAllowed: foregroundCondition.isAllowed,
                                playbackContextAvailable: playbackAvailable)
        }
        .removeDuplicates()
        .sink(receiveValue: { [weak self] newContext in
            FileLog.shared.addMessage("[VoicePipeline] Context: \(newContext)")
            self?.context = newContext
        })
        .store(in: &cancellables)

        // The LAST genuine context is gone while the foreground is already lost (reviewer
        // 0c546ce5 item 2): the playback publisher tells the signal directly, so backgrounding
        // that was preserved under a playback context retires when that context disappears —
        // no separate lifecycle notification exists for it. The signal judges the foreground
        // itself; a loss while foreground holds is not a retirement.
        playbackPublisher
            .sink { [weak self] available in
                self?.gracePeriodSignal.onPlaybackContextChanged(available)
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
