import Foundation

/// ONE identified `playback.seek_relative` settlement (task67 seek_relative client slice,
/// spec cloud-assistant.md "Client seek completion and settlement" @ a3af56dd).
///
/// The coordinator owns the bounded client completion budget for a single admitted operation:
/// the completion observer is registered BEFORE the effect is released, the budget is monotonic
/// and belongs to the original admission (never restarted by duplicates, callbacks or
/// reconnection), and the settlement classifies exactly per the contract table. The returned
/// result is immutable: a late callback can neither revise it nor read a successor's state.
///
/// Review-blocker revisions: (1) the deadline is enforced at the ENGINE MUTATION SITE via
/// `deadlineNs`, so queue delay cannot push an expired effect through; (2) success revalidates
/// the LIVE engine objects against the initiating identity, so a replacement engine cannot have
/// its predecessor's callback settle on its state; (3) position evidence is the COMPLETION'S
/// OWN captured clock/frame — never a later global observation that a second pending seek may
/// have rewritten; (4) expiry is re-checked after the final observation.
struct SeekRelativeCompletion {

    /// The client completion budget, measured with a MONOTONIC clock from the original
    /// admission (spec: 15 seconds; an earlier known local turn deadline may shorten it —
    /// the caller passes its own remaining bound as `budgetOverride` when one exists).
    static let defaultBudgetSeconds: TimeInterval = 15

    /// What the initiating side captured when the seek was issued: the engine identity that
    /// the completion must carry AND that the live engine must still present at settlement,
    /// and the episode the operation owned.
    struct Initiation {
        let identity: SeekIdentity
        let episodeUUID: String
        /// Monotonic admission instant (uptimeNanoseconds), captured BEFORE the durable claim
        /// and any suspension (effect gate, queue delay). Duplicates and reconnection never
        /// mint a new one.
        let admittedAtUptimeNs: UInt64
        /// The admission bound handed to the engine for the at-mutation deadline check.
        var deadlineNs: UInt64 { admittedAtUptimeNs &+ UInt64(budgetSeconds * 1_000_000_000) }
        let budgetSeconds: TimeInterval
        init(identity: SeekIdentity, episodeUUID: String, admittedAtUptimeNs: UInt64,
             budgetSeconds: TimeInterval = SeekRelativeCompletion.defaultBudgetSeconds) {
            self.identity = identity
            self.episodeUUID = episodeUUID
            self.admittedAtUptimeNs = admittedAtUptimeNs
            self.budgetSeconds = budgetSeconds
        }
    }

    /// Live-state probe used at settlement time (never initiation): the OBSERVED playing flag,
    /// the CURRENT episode identity, and the LIVE engine objects for replacement detection.
    /// Position deliberately is NOT taken here: the position comes from the completion's own
    /// captured evidence (blocker 3).
    struct Observation {
        let playing: Bool?
        let currentEpisodeUUID: String?
        /// The live engine's object identity right now (nil = probe unavailable).
        let liveEngineIdentity: SeekIdentity?
    }

    /// Reasons, mirroring the wire vocabulary.
    enum Reason {
        static let deadlineExpired = "seek_deadline_expired"
        static let completionUnavailable = "seek_completion_unavailable"
    }

    private let nowUptimeNs: () -> UInt64
    /// Awaits the engine's typed outcome for the initiated seek. Returning nil models a
    /// completion that never arrives (missing callback) WITHOUT hanging: the budget still
    /// bounds this wait, so the waiter is always returned bounded.
    private let awaitOutcome: () async -> SeekExecutionOutcome?
    /// Fresh observation at classification time.
    private let observe: () -> Observation

    init(nowUptimeNs: @escaping () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
         awaitOutcome: @escaping () async -> SeekExecutionOutcome?,
         observe: @escaping () -> Observation) {
        self.nowUptimeNs = nowUptimeNs
        self.awaitOutcome = awaitOutcome
        self.observe = observe
    }

    /// Remaining budget in seconds from the ORIGINAL admission, measured monotonically.
    func remainingSeconds(since initiation: Initiation) -> TimeInterval {
        let elapsed = Double(nowUptimeNs() &- initiation.admittedAtUptimeNs) / 1_000_000_000
        return initiation.budgetSeconds - elapsed
    }

    /// Settles ONE invocation. Called only after the pre-effect refusals passed and the effect
    /// was released (or refused before release — see `refuseBeforeReleaseExpired`).
    func settle(after initiation: Initiation) async -> OperationResult {
        let deadlineNs = initiation.deadlineNs
        // Bounded waiter: whichever comes first, the correlated outcome or the monotonic
        // deadline. The race is arbitrated by the deadline: at or beyond it, expiry wins
        // (a completion that lands after the budget is not success).
        let outcome: SeekExecutionOutcome? = await raceOutcomeAgainstDeadline(deadlineNs)
        switch outcome {
        case .some(.expiredBeforeMutation(let identity)) where Self.isCorrelated(identity, initiation.identity):
            // The engine itself verified at the MUTATION SITE that no effect was issued:
            // the honest settlement is the before-release refusal arm.
            return .nonSuccess(.refused, reason: Reason.deadlineExpired)
        case .some(.completed(let identity, _, let capturedClock)) where Self.isCorrelated(identity, initiation.identity):
            // Native completion: the item-clock captured INSIDE the completion handler is this
            // invocation's landing evidence — not any later mutable clock read.
            return succeededResult(for: initiation, capturedPosition: capturedClock)
        case .some(.cursorRepositioned(let identity, _, _, let landedSeconds)) where Self.isCorrelated(identity, initiation.identity):
            // Cursor reposition: the frame→seconds conversion captured in AudioReadTask's
            // locked region is this invocation's landing evidence.
            return succeededResult(for: initiation, capturedPosition: landedSeconds)
        case .some(.endOfFile(let identity, _, let engineTotal)) where Self.isCorrelated(identity, initiation.identity):
            // EOF: the engine-confirmed endpoint supplies position; playing must still be
            // observed. Nothing audible is fabricated — the position is the endpoint itself.
            return succeededResult(for: initiation, capturedPosition: engineTotal)
        case .some(.cancelled(let identity)) where Self.isCorrelated(identity, initiation.identity):
            // Native cancellation: does not prove the seek did not occur. Unknown, no state.
            return .nonSuccess(.unknown, reason: Reason.completionUnavailable)
        case .some(.engineUnavailable(let identity)) where Self.isCorrelated(identity, initiation.identity):
            return .nonSuccess(.unknown, reason: Reason.completionUnavailable)
        default:
            // Uncorrelated evidence counts as NO evidence: it belongs to another invocation.
            break
        }
        // No correlated completion within the live budget.
        return .nonSuccess(.unknown, reason: Reason.completionUnavailable)
    }

    /// The BEFORE-release arm of the table: the budget expired before the effect was released
    /// (an earlier local turn deadline or a held effect gate). Refused, no state, NO effect.
    func refuseBeforeReleaseExpired(since initiation: Initiation) -> OperationResult {
        return .nonSuccess(.refused, reason: Reason.deadlineExpired)
    }

    /// Success classification: correlated completion whose CAPTURED position is valid, a
    /// valid same-target and same-engine state observation, and expiry still not reached
    /// AFTER the observation (review blocker: the check must follow the final observation).
    private func succeededResult(for initiation: Initiation,
                                 capturedPosition: TimeInterval) -> OperationResult {
        let observation = observe()
        guard observation.currentEpisodeUUID == initiation.episodeUUID else {
            // Replacement or advancement to another episode cannot supply this episode's result.
            return .nonSuccess(.unknown, reason: Reason.completionUnavailable)
        }
        // SAME-ENGINE verification: the live engine objects must still be the initiating
        // engine's objects — the old engine's callback must not settle on a successor's state.
        guard let live = observation.liveEngineIdentity,
              live.sameEngineObjects(as: initiation.identity) else {
            return .nonSuccess(.unknown, reason: Reason.completionUnavailable)
        }
        guard let playing = observation.playing else {
            // Missing playing state cannot settle success.
            return .nonSuccess(.unknown, reason: Reason.completionUnavailable)
        }
        guard capturedPosition.isFinite, capturedPosition >= 0 else {
            return .nonSuccess(.unknown, reason: Reason.completionUnavailable)
        }
        // Post-observation deadline re-check: success requires the state observation to have
        // happened within the live budget.
        guard nowUptimeNs() < initiation.deadlineNs else {
            return .nonSuccess(.unknown, reason: Reason.completionUnavailable)
        }
        // Whole elapsed seconds from the CAPTURED landing evidence — never the requested
        // target, never a later mutable global clock.
        return .succeeded(state: [
            "position_seconds": .int(Int64(capturedPosition.rounded(.down))),
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
            // for SUCCESS-CAPABLE evidence. But a correlated `expiredBeforeMutation` is a
            // PROOF OF NO EFFECT that the engine produced at the mutation site — it survives
            // expiry (it can only arrive at/after the deadline in production) and classifies
            // as the before-release refusal. It never revises an earlier settlement: settle
            // runs once and returns once.
            if case .expiredBeforeMutation = firstSettled {
                return firstSettled
            }
            if nowUptimeNs() >= deadlineNs { return nil }
            return firstSettled
        }
    }
}
