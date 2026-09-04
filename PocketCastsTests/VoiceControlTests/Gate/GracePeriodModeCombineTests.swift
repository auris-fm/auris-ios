import Combine
import XCTest
@testable import podcasts

/// Reproduces the production CombineLatest pattern: conditions + `$isActive`.
/// Merlinran's logs showed grace going true with no mode flip, then timeout
/// flipping wakeWord → continuous (inverted). Root cause: logging while
/// `isActive` still held the old value let a conditions refresh resolve the
/// wrong mode. These tests lock the expected polarity.
final class GracePeriodModeCombineTests: XCTestCase {

    func test_graceActivating_emitsContinuous() {
        let signal = GracePeriodSignal()
        let condition = CurrentValueSubject<GateContext, Never>(.appInForeground)
        var modes: [ListeningMode] = []

        let cancellable = Publishers.CombineLatest(condition, signal.$isActive)
            .map { context, graceActive in
                VoiceControlGate(
                    setup: .allAllowed,
                    conflicts: .noneBlocked,
                    context: context,
                    micExposure: .exposed,
                    gracePeriodActive: graceActive
                ).state
            }
            .sink { state in
                if case .listening(let mode) = state {
                    modes.append(mode)
                }
            }

        signal.onWakeWordDetected()

        XCTAssertEqual(modes.last, .continuous)
        cancellable.cancel()
    }

    func test_graceExpiring_emitsWakeWord() {
        let signal = GracePeriodSignal(timeout: 0.05)
        let condition = CurrentValueSubject<GateContext, Never>(.appInForeground)
        let expired = expectation(description: "expired to wakeWord")
        var lastMode: ListeningMode?
        var sawContinuous = false

        let cancellable = Publishers.CombineLatest(condition, signal.$isActive)
            .map { context, graceActive in
                VoiceControlGate(
                    setup: .allAllowed,
                    conflicts: .noneBlocked,
                    context: context,
                    micExposure: .exposed,
                    gracePeriodActive: graceActive
                ).state
            }
            .sink { state in
                guard case .listening(let mode) = state else { return }
                lastMode = mode
                if mode == .continuous {
                    sawContinuous = true
                } else if mode == .wakeWord, sawContinuous {
                    expired.fulfill()
                }
            }

        signal.onWakeWordDetected()
        wait(for: [expired], timeout: 2.0)
        XCTAssertTrue(sawContinuous)
        XCTAssertEqual(lastMode, .wakeWord)
        cancellable.cancel()
    }

    func test_conditionRefreshWhileGraceActive_staysContinuous() {
        let signal = GracePeriodSignal()
        let condition = CurrentValueSubject<GateContext, Never>(.appInForeground)
        var modes: [ListeningMode] = []

        let cancellable = Publishers.CombineLatest(condition, signal.$isActive)
            .map { context, graceActive in
                VoiceControlGate(
                    setup: .allAllowed,
                    conflicts: .noneBlocked,
                    context: context,
                    micExposure: .exposed,
                    gracePeriodActive: graceActive
                ).state
            }
            .sink { state in
                if case .listening(let mode) = state {
                    modes.append(mode)
                }
            }

        signal.onWakeWordDetected()
        condition.send(.both) // conditions-only refresh while grace is active

        XCTAssertEqual(modes.last, .continuous)
        cancellable.cancel()
    }
}
