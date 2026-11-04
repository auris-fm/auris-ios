import Foundation

/// ONE identified `playback.seek_relative` settlement (task67 seek_relative client slice,
/// spec cloud-assistant.md "Client seek completion and settlement" @ a3af56dd).
///
/// The coordinator owns the bounded client completion budget for a single admitted operation:
/// the completion observer is registered BEFORE the effect is released, the budget is monotonic
/// and belongs to the original admission (never restarted by duplicates, callbacks or
/// reconnection), and the settlement classifies exactly per the contract table. The returned
/// result is immutable: a late callback can neither revise it nor read a successor's state.
struct SeekRelativeCompletion {

    /// The client completion budget, measured with a MONOTONIC clock from the original
    /// admission (spec: 15 seconds; an earlier known local turn deadline may shorten it —
    /// the caller passes its own remaining bound as `budgetOverride` when one exists).
    static let defaultBudgetSeconds: TimeInterval = 15

    /// What the initiating side captured when the seek was issued: the engine identity that
    /// the completion must carry, and the episode the operation owned.
    struct Initiation {
        let identity: SeekIdentity
        let episodeUUID: String
        /// Monotonic admission instant (uptimeNanoseconds). Duplicates and reconnection never
        /// mint a new one.
        let admittedAtUptimeNs: UInt64
    }

    /// Live-state probe used at settlement time (never initiation): the observed position and
    /// playing flag, plus the CURRENT episode identity for same-target verification.
    struct Observation {
        let positionSeconds: TimeInterval?
        let playing: Bool?
        let currentEpisodeUUID: String?
    }

    /// Reasons, mirroring the wire vocabulary.
    enum Reason {
        static let deadlineExpired = "seek_deadline_expired"
        static let completionUnavailable = "seek_completion_unavailable"
    }

    private let budgetSeconds: TimeInterval
    private let nowUptimeNs: () -> UInt64
    /// Awaits the engine's typed outcome for the initiated seek. Returning nil models a
    /// completion that never arrives (missing callback) WITHOUT hanging: the budget still
    /// bounds this wait, so the waiter is always returned bounded.
    private let awaitOutcome: () async -> SeekExecutionOutcome?
    /// Fresh observation at classification time.
    private let observe: () -> Observation

    init(budgetSeconds: TimeInterval = SeekRelativeCompletion.defaultBudgetSeconds,
         nowUptimeNs: @escaping () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
         awaitOutcome: @escaping () async -> SeekExecutionOutcome?,
         observe: @escaping () -> Observation) {
        self.budgetSeconds = budgetSeconds
        self.nowUptimeNs = nowUptimeNs
        self.awaitOutcome = awaitOutcome
        self.observe = observe
    }

    /// Remaining budget in seconds from the ORIGINAL admission, measured monotonically.
    func remainingSeconds(since initiation: Initiation) -> TimeInterval {
        let elapsed = Double(nowUptimeNs() &- initiation.admittedAtUptimeNs) / 1_000_000_000
        return budgetSeconds - elapsed
    }

    /// Settles ONE invocation. Called only after the pre-effect refusals passed and the effect
    /// was released (or refused before release — see `refuseBeforeRelease`).
    func settle(after initiation: Initiation) async -> OperationResult {
        let deadlineNs = initiation.admittedAtUptimeNs &+ UInt64(budgetSeconds * 1_000_000_000)
        // Bounded waiter: whichever comes first, the correlated outcome or the monotonic
        // deadline. The race is arbitrated by the deadline: at or beyond it, expiry wins
        // (a completion that lands after the budget is not success).
        let outcome: SeekExecutionOutcome? = await raceOutcomeAgainstDeadline(deadlineNs)
        switch outcome {
        case .some(.completed(let identity, _, _)) where Self.isCorrelated(identity, initiation.identity):
            return succeededResult(for: initiation)
        case .some(.cursorRepositioned(let identity, _, let landedFrame)) where Self.isCorrelated(identity, initiation.identity):
            // Cursor reposition claims the READ CURSOR moved (EffectsPlayer path): valid
            // completion evidence. State observation still decides success.
            _ = landedFrame
            return succeededResult(for: initiation)
        case .some(.endOfFile(let identity, _, let engineTotal)) where Self.isCorrelated(identity, initiation.identity):
            // EOF: the engine-confirmed endpoint supplies position; playing must still be
            // observed. Nothing audible is fabricated — the position is the endpoint itself.
            let observation = observe()
            guard let playing = observation.playing else {
                return .nonSuccess(.unknown, reason: Reason.completionUnavailable)
            }
            let position = Int(engineTotal.rounded(.down))
            guard position >= 0 else {
                return .nonSuccess(.unknown, reason: Reason.completionUnavailable)
            }
            _ = initiation // episode sameness verified below via observation
            guard observation.currentEpisodeUUID == initiation.episodeUUID else {
                return .nonSuccess(.unknown, reason: Reason.completionUnavailable)
            }
            return .succeeded(state: ["position_seconds": .int(Int64(position)), "playing": .bool(playing)])
        case .some(.cancelled(let identity)) where Self.isCorrelated(identity, initiation.identity):
            // Native cancellation: does not prove the seek did not occur. Unknown, no state.
            return .nonSuccess(.unknown, reason: Reason.completionUnavailable)
        case .some(.engineUnavailable(let identity)) where Self.isCorrelated(identity, initiation.identity):
            return .nonSuccess(.unknown, reason: Reason.completionUnavailable)
        default:
            // Uncorrelated evidence counts as NO evidence: it belongs to another invocation.
            // Fall through to the expiry classification.
            break
        }
        // No correlated completion within the live budget.
        return .nonSuccess(.unknown, reason: Reason.completionUnavailable)
    }

    /// The BEFORE-release arm of the table: the budget expired before the effect was released
    /// (an earlier local turn deadline or a held effect gate). Refused, no state, NO effect.
    func refuseBeforeReleaseExpired(since initiation: Initiation) -> OperationResult {
        _ = initiation
        return .nonSuccess(.refused, reason: Reason.deadlineExpired)
    }

    /// Success classification: correlated completion AND a valid same-target state observation.
    private func succeededResult(for initiation: Initiation) -> OperationResult {
        let observation = observe()
        guard observation.currentEpisodeUUID == initiation.episodeUUID else {
            // Replacement or advancement to another episode cannot supply this episode's result.
            return .nonSuccess(.unknown, reason: Reason.completionUnavailable)
        }
        guard let playing = observation.playing else {
            // Missing playing state cannot settle success.
            return .nonSuccess(.unknown, reason: Reason.completionUnavailable)
        }
        guard let position = observation.positionSeconds, position.isFinite, position >= 0 else {
            return .nonSuccess(.unknown, reason: Reason.completionUnavailable)
        }
        // Whole elapsed seconds from the OBSERVED position — never the requested target.
        return .succeeded(state: [
            "position_seconds": .int(Int64(position.rounded(.down))),
            "playing": .bool(playing),
        ])
    }

    private static func isCorrelated(_ observed: SeekIdentity, _ initiated: SeekIdentity) -> Bool {
        observed == initiated
    }

    /// Awaits the outcome but returns nil once the monotonic deadline passes. The deadline is
    /// computed from the SAME clock the budget is measured with. The engine await runs in a
    /// child task so a callback that never arrives cannot hang the waiter beyond the budget;
    /// once settled (by either arm) the child is cancelled and the group returns bounded.
    private func raceOutcomeAgainstDeadline(_ deadlineNs: UInt64) async -> SeekExecutionOutcome? {
        return await withTaskGroup(of: SeekExecutionOutcome?.self) { group in
            group.addTask { await self.awaitOutcome() }
            group.addTask {
                let clock = self.nowUptimeNs
                while clock() < deadlineNs {
                    let remainingNs = deadlineNs &- clock()
                    try? await Task.sleep(nanoseconds: min(50_000_000, remainingNs))
                    if Task.isCancelled { return nil }
                }
                return nil // expiry arm: nil, deadline wins at or beyond the boundary
            }
            let firstSettled = await group.next() ?? nil
            group.cancelAll()
            // Drain so no child is left dangling; the cancel makes the drain immediate.
            _ = await group.next()
            // Deadline arbitration on the SAME clock: at or beyond the boundary, expiry wins
            // even if a correlated completion raced it.
            if nowUptimeNs() >= deadlineNs { return nil }
            return firstSettled
        }
    }
}
