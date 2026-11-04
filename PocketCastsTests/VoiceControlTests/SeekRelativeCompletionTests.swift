import XCTest
import AVFoundation
@testable import podcasts

/// Controls for the identified `playback.seek_relative` settlement (spec cloud-assistant.md
/// "Client seek completion and settlement" @ a3af56dd). The coordinator is the unit under
/// test: the engine outcome arrives through an injected awaitable, the observation and the
/// monotonic clock are injected, so every control observes the exact classification and the
/// exact immutable result — no mock of the journal itself (journal-level replay keeps its own
/// durable-record controls).
final class SeekRelativeCompletionTests: XCTestCase {

    private let token = UUID()
    private let playerID = ObjectIdentifier(NSObject())
    private let itemID = ObjectIdentifier(NSObject())

    private func identity(_ tok: UUID? = nil) -> SeekIdentity {
        SeekIdentity(invocationToken: tok ?? token, playerID: playerID, readTaskID: nil, itemID: itemID)
    }

    private func initiation(clock: ManualUptimeClock, budget: TimeInterval = 15) -> SeekRelativeCompletion.Initiation {
        SeekRelativeCompletion.Initiation(
            identity: identity(), episodeUUID: "ep-1",
            admittedAtUptimeNs: clock.now, budgetSeconds: budget)
    }

    private func observation(playing: Bool? = true, episode: String? = "ep-1",
                             liveEngine: SeekIdentity? = nil) -> SeekRelativeCompletion.Observation {
        .init(playing: playing, currentEpisodeUUID: episode,
              liveEngineIdentity: liveEngine ?? identity())
    }

    private func coordinator(clock: ManualUptimeClock,
                             observation: (() -> SeekRelativeCompletion.Observation)? = nil,
                             outcome: @escaping () async -> SeekExecutionOutcome?
    ) -> SeekRelativeCompletion {
        SeekRelativeCompletion(nowUptimeNs: { clock.now },
                               awaitOutcome: outcome,
                               observe: observation ?? { [weak self] in self?.observation() ?? .init(playing: true, currentEpisodeUUID: "ep-1", liveEngineIdentity: nil) })
    }

    // MARK: - success arms

    /// Correlated native completion + valid same-target observation → `succeeded` with the
    /// OBSERVED position (whole elapsed seconds), never the requested target.
    func test_correlatedCompletedSettlesSuccessWithObservedPosition() async throws {
        let clock = ManualUptimeClock()
        let initn = initiation(clock: clock)
        let c = coordinator(clock: clock) { .completed(identity: self.identity(),
                                                       effectiveRequest: 500, observedItemClock: 499.2) }
        let result = await c.settle(after: initn)
        guard result.outcome == .succeeded, let state = result.state else {
            return XCTFail("expected succeeded, got \(result)")
        }
        XCTAssertEqual(state["position_seconds"], .int(499) as CloudRouteJSONValue,
                       "the position is the completion's CAPTURED clock, not a later global read")
        XCTAssertEqual(state["playing"], .bool(true) as CloudRouteJSONValue)
    }

    /// An already-reached or clamped target still completes natively (finished == true with an
    /// unchanged clock): success requires correlated completion, not movement.
    func test_alreadyReachedTargetStillSucceeds() async throws {
        let clock = ManualUptimeClock()
        let initn = initiation(clock: clock)
        let c = coordinator(clock: clock) { .completed(identity: self.identity(),
                                                       effectiveRequest: 120, observedItemClock: 120) }
        let result = await c.settle(after: initn)
        guard result.outcome == .succeeded else {
            return XCTFail("clamped target must succeed on correlated completion, got \(result)")
        }
    }

    /// Cursor-reposition evidence (EffectsPlayer path) is valid completion evidence.
    func test_cursorRepositionSettlesSuccess() async throws {
        let clock = ManualUptimeClock()
        let initn = initiation(clock: clock)
        let c = coordinator(clock: clock) { .cursorRepositioned(identity: self.identity(),
                                                                requestedTime: 60, landedFrame: 2_640_000, landedSeconds: 60) }
        let result = await c.settle(after: initn)
        guard result.outcome == .succeeded, let state = result.state else {
            return XCTFail("expected succeeded, got \(result)")
        }
        XCTAssertEqual(state["position_seconds"], .int(60) as CloudRouteJSONValue,
                       "the frame→seconds conversion captured in the locked region")
    }

    /// Correlated EOF: the engine-confirmed endpoint supplies the position; playing is still
    /// observed.
    func test_endOfFileSettlesSuccessAtEndpointWithObservedPlaying() async throws {
        let clock = ManualUptimeClock()
        let initn = initiation(clock: clock)
        let c = coordinator(clock: clock) { .endOfFile(identity: self.identity(),
                                                       requestedTime: 10_000, engineTotalSeconds: 3_600) }
        let result = await c.settle(after: initn)
        guard result.outcome == .succeeded, let state = result.state else {
            return XCTFail("expected succeeded, got \(result)")
        }
        XCTAssertEqual(state["position_seconds"], .int(3600) as CloudRouteJSONValue)
        XCTAssertEqual(state["playing"], .bool(true) as CloudRouteJSONValue)
    }

    /// A playing engine observed at settlement: playing is the observation; the position is
    /// the CAPTURED landing evidence, immune to a clock advancing after completion.
    func test_advancingClockAfterCompletionStillSucceeds() async throws {
        let clock = ManualUptimeClock()
        let initn = initiation(clock: clock)
        let c = coordinator(clock: clock) { .completed(identity: self.identity(),
                                                       effectiveRequest: 120, observedItemClock: 130.9) }
        let result = await c.settle(after: initn)
        guard result.outcome == .succeeded, let state = result.state else {
            return XCTFail("expected succeeded, got \(result)")
        }
        XCTAssertEqual(state["position_seconds"], .int(130) as CloudRouteJSONValue,
                       "whole seconds from the CAPTURED clock")
        XCTAssertEqual(state["playing"], .bool(true) as CloudRouteJSONValue)
    }

    // MARK: - unknown arms

    /// Native cancellation: does not prove the seek did not occur → `unknown`
    /// `seek_completion_unavailable`, no state.
    func test_nativeCancellationIsUnknownNotFailure() async throws {
        let clock = ManualUptimeClock()
        let initn = initiation(clock: clock)
        let c = coordinator(clock: clock) { .cancelled(identity: self.identity()) }
        let result = await c.settle(after: initn)
        XCTAssertEqual(result.outcome, OperationOutcome.unknown)
        XCTAssertEqual(result.reason, SeekRelativeCompletion.Reason.completionUnavailable)
        XCTAssertNil(result.state)
    }

    /// Engine unavailable at initiation: no evidence, no success — unknown.
    func test_engineUnavailableIsUnknown() async throws {
        let clock = ManualUptimeClock()
        let initn = initiation(clock: clock)
        let c = coordinator(clock: clock) { .engineUnavailable(identity: self.identity()) }
        let result = await c.settle(after: initn)
        XCTAssertEqual(result.outcome, OperationOutcome.unknown)
    }

    /// A completion for a DIFFERENT invocation (different token, same engine objects) is NO
    /// evidence: the waiter is bounded by expiry, which classifies unknown.
    func test_uncorrelatedCallbackIsNotEvidence() async throws {
        let clock = ManualUptimeClock()
        let initn = initiation(clock: clock)
        let c = coordinator(clock: clock) { .completed(identity: self.identity(UUID()),
                                                       effectiveRequest: 500, observedItemClock: 500) }
        let result = await c.settle(after: initn)
        XCTAssertEqual(result.outcome, OperationOutcome.unknown)
    }

    /// Episode replacement (user moved to another episode by settlement time): the successor
    /// cannot supply this episode's result → unknown.
    func test_episodeReplacementCannotSupplyTheResult() async throws {
        let clock = ManualUptimeClock()
        let initn = initiation(clock: clock)
        let c = coordinator(clock: clock, observation: {
            .init(playing: true, currentEpisodeUUID: "ep-2", liveEngineIdentity: nil)
        }, outcome: { .completed(identity: self.identity(), effectiveRequest: 500, observedItemClock: 500) })
        let result = await c.settle(after: initn)
        XCTAssertEqual(result.outcome, OperationOutcome.unknown)
    }

    /// Missing playing state cannot settle success even with correlated completion.
    func test_missingPlayingStateCannotSettleSuccess() async throws {
        let clock = ManualUptimeClock()
        let initn = initiation(clock: clock)
        let c = coordinator(clock: clock, observation: {
            self.observation(playing: nil)
        }, outcome: { .completed(identity: self.identity(), effectiveRequest: 500, observedItemClock: 500) })
        let result = await c.settle(after: initn)
        XCTAssertEqual(result.outcome, OperationOutcome.unknown)
    }

    // MARK: - budget arms

    /// A callback that NEVER arrives: the waiter returns bounded at the monotonic deadline
    /// with `unknown` — the intentionally absent callback must not hang the test.
    func test_missingCallbackReturnsBoundedAtTheDeadline() async throws {
        let clock = ManualUptimeClock()
        clock.now = 1_000
        let initn = initiation(clock: clock, budget: 15)
        // Fake clock already at the boundary+1s: the expiry arm answers immediately.
        clock.now = 1_000 + UInt64(16 * 1_000_000_000)
        let c = coordinator(clock: clock) { () -> SeekExecutionOutcome? in
            // Blocks "forever" but is cancellable — the race's cancelAll must free it.
            try? await Task.sleep(nanoseconds: 600_000_000_000)
            return nil
        }
        let started = Date()
        let result = await c.settle(after: initn)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5,
                          "the waiter must be bounded, not hung on the missing callback")
        XCTAssertEqual(result.outcome, OperationOutcome.unknown)
        XCTAssertEqual(result.reason, SeekRelativeCompletion.Reason.completionUnavailable)
    }

    /// AT OR BEYOND the monotonic deadline, expiry wins: a completion that lands after the
    /// budget cannot settle success.
    func test_expiryWinsAtTheDeadlineEvenWhenACallbackExists() async throws {
        let clock = ManualUptimeClock()
        let initn = initiation(clock: clock, budget: 15)
        // The engine WILL deliver a valid completion — but the clock is already past the
        // deadline when settle runs.
        clock.now = clock.admission + UInt64(16 * 1_000_000_000)
        let c = coordinator(clock: clock) { .completed(identity: self.identity(),
                                                                   effectiveRequest: 500, observedItemClock: 500) }
        let result = await c.settle(after: initn)
        XCTAssertEqual(result.outcome, OperationOutcome.unknown)
    }

    /// The pre-release arm: budget expired before the effect was released → REFUSED
    /// `seek_deadline_expired`, no state, no effect.
    func test_preReleaseExpiryIsRefusedWithTheDeadlineReason() throws {
        let clock = ManualUptimeClock()
        let initn = initiation(clock: clock, budget: 15)
        let c = coordinator(clock: clock) { nil }
        clock.now = clock.admission + UInt64(16 * 1_000_000_000)
        let result = c.refuseBeforeReleaseExpired(since: initn)
        XCTAssertEqual(result.outcome, OperationOutcome.refused)
        XCTAssertEqual(result.reason, SeekRelativeCompletion.Reason.deadlineExpired)
        XCTAssertNil(result.state)
    }

    /// Remaining budget is measured from the ORIGINAL admission on the monotonic clock —
    /// duplicates and reconnection never restart it.
    func test_remainingBudgetIsMeasuredFromTheOriginalAdmission() {
        let clock = ManualUptimeClock()
        clock.now = 0
        let initn = initiation(clock: clock, budget: 15)
        clock.now = UInt64(10 * 1_000_000_000)
        let c = coordinator(clock: clock) { nil }
        XCTAssertEqual(c.remainingSeconds(since: initn), 5, accuracy: 0.001)
        clock.now = UInt64(16 * 1_000_000_000)
        XCTAssertLessThanOrEqual(c.remainingSeconds(since: initn), 0)
    }

    // MARK: - review-blocker controls (spec a3af56dd + review 885b244d)

    /// The engine's at-mutation deadline check PROVES no seek was issued: refused with the
    /// deadline reason (the before-release arm), never unknown/cancelled.
    func test_expiredBeforeMutationIsRefusedWithTheDeadlineReason() async throws {
        let clock = ManualUptimeClock()
        let initn = initiation(clock: clock)
        let c = coordinator(clock: clock) { .expiredBeforeMutation(identity: self.identity()) }
        let result = await c.settle(after: initn)
        XCTAssertEqual(result.outcome, OperationOutcome.refused)
        XCTAssertEqual(result.reason, SeekRelativeCompletion.Reason.deadlineExpired)
        XCTAssertNil(result.state)
    }

    /// SAME-EPISODE ENGINE REPLACEMENT (review blocker 2): the live probe reports a different
    /// engine object — the old engine's callback must not settle on the successor's state.
    func test_engineReplacementAtSettlementCannotSupplyTheResult() async throws {
        let clock = ManualUptimeClock()
        let initn = initiation(clock: clock)
        let c = coordinator(clock: clock, observation: {
            .init(playing: true, currentEpisodeUUID: "ep-1",
                  liveEngineIdentity: SeekIdentity(invocationToken: UUID(),
                                                   playerID: ObjectIdentifier(NSObject()),
                                                   readTaskID: nil, itemID: nil))
        }) { .completed(identity: self.identity(), effectiveRequest: 500, observedItemClock: 500) }
        let result = await c.settle(after: initn)
        XCTAssertEqual(result.outcome, OperationOutcome.unknown)
        XCTAssertNil(result.state)
    }

    /// POSITION IS THE CAPTURED LANDING EVIDENCE (review blocker 3): the state carries the
    /// clock captured INSIDE the completion handler, not any later global observation.
    func test_successCarriesTheCapturedLandingClock() async throws {
        let clock = ManualUptimeClock()
        let initn = initiation(clock: clock)
        let c = coordinator(clock: clock) { .completed(identity: self.identity(),
                                                       effectiveRequest: 135, observedItemClock: 249.7) }
        let result = await c.settle(after: initn)
        guard result.outcome == .succeeded, let state = result.state else {
            return XCTFail("expected succeeded, got \(result)")
        }
        XCTAssertEqual(state["position_seconds"], .int(249) as CloudRouteJSONValue,
                       "whole seconds from the CAPTURED clock, not a later global read")
    }

    /// Cursor reposition likewise carries the CAPTURED frame→seconds conversion.
    func test_cursorRepositionCarriesTheCapturedLandingSeconds() async throws {
        let clock = ManualUptimeClock()
        let initn = initiation(clock: clock)
        let c = coordinator(clock: clock) { .cursorRepositioned(identity: self.identity(),
                                                                requestedTime: 60, landedFrame: 2_640_000, landedSeconds: 59.9) }
        let result = await c.settle(after: initn)
        guard result.outcome == .succeeded, let state = result.state else {
            return XCTFail("expected succeeded, got \(result)")
        }
        XCTAssertEqual(state["position_seconds"], .int(59) as CloudRouteJSONValue)
    }

    /// A non-finite captured clock cannot settle success.
    func test_nonFiniteCapturedClockCannotSettleSuccess() async throws {
        let clock = ManualUptimeClock()
        let initn = initiation(clock: clock)
        let c = coordinator(clock: clock) { .completed(identity: self.identity(),
                                                       effectiveRequest: 500, observedItemClock: .nan) }
        let result = await c.settle(after: initn)
        XCTAssertEqual(result.outcome, OperationOutcome.unknown)
    }

    /// EXPIRY IS RECHECKED AFTER THE FINAL OBSERVATION (review blocker 1c): the observation
    /// itself consumed the last of the budget — the success must not settle.
    func test_postObservationExpiryIsUnknown() async throws {
        let clock = ManualUptimeClock()
        let initn = initiation(clock: clock, budget: 15)
        let deadline = initn.admittedAtUptimeNs + UInt64(15 * 1_000_000_000)
        let c = coordinator(clock: clock, observation: { [weak self] in
            // The observation lands exactly at the boundary; the post-observation re-check
            // must then refuse success.
            clock.now = deadline
            return self?.observation() ?? .init(playing: true, currentEpisodeUUID: "ep-1", liveEngineIdentity: nil)
        }) { .completed(identity: self.identity(), effectiveRequest: 500, observedItemClock: 500) }
        let result = await c.settle(after: initn)
        XCTAssertEqual(result.outcome, OperationOutcome.unknown)
    }

    /// NATIVE SEAM (DefaultPlayer): a past deadline delivered to the engine settles
    /// `expiredBeforeMutation` — the native call was not released. The identity proves the
    /// engine minted it at the mutation site.
    func test_nativeSeamExpiredDeadlineDoesNotReleaseTheSeek() async throws {
        let engine = DefaultPlayer()
        engine.player = AVPlayer()
        let token = UUID()
        let deadline = DispatchTime.now().uptimeNanoseconds &- UInt64(1_000_000_000) // already past
        var delivered: SeekExecutionOutcome?
        engine.seekTo(10, completion: nil, typedCompletion: { delivered = $0 },
                      invocationToken: token, deadlineNs: deadline)
        guard case .expiredBeforeMutation(let identity)? = delivered else {
            return XCTFail("expected expiredBeforeMutation, got \(String(describing: delivered))")
        }
        XCTAssertEqual(identity.invocationToken, token)
    }
}

/// Deterministic monotonic-clock fixture (uptimeNanoseconds semantics).
final class ManualUptimeClock {
    var now: UInt64
    /// The admission instant this fixture froze at construction.
    let admission: UInt64
    init(start: UInt64 = 0) {
        now = start
        admission = start
    }
}
