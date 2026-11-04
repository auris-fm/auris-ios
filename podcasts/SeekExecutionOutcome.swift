import Foundation

/// ADDITIVE typed seek outcome (task67 seek-completion slice): identity-carrying evidence
/// captured at the engine. Purely additive — every legacy completion and EOF side effect is
/// unchanged; no await, journal classification or manifest surface ships in this slice.
///
/// The identity travels with the outcome so a consumer can attribute an outcome to the
/// initiating engine objects without inferring from mutable manager state. The
/// `invocationToken` distinguishes two seeks issued against the SAME player/read task
/// (identical `playerID`/`readTaskID`); the object identifiers tie an outcome to the engine
/// objects that were current when that seek was initiated, which is the replacement-detection
/// input for a later settlement layer.
struct SeekIdentity: Equatable {
    /// Per-invocation token, minted at seek initiation — unique per seek even when every
    /// engine identifier matches.
    let invocationToken: UUID
    /// The engine object the seek was handed to.
    let playerID: ObjectIdentifier
    /// The read task that will execute the seek (EffectsPlayer path); nil elsewhere.
    let readTaskID: ObjectIdentifier?
    /// The initiating media item identity (AVPlayerItem on the DefaultPlayer path); nil when
    /// the engine has no current item.
    let itemID: ObjectIdentifier?
}

/// Raw value captured INSIDE AudioReadTask's locked seek operation — immutable once
/// returned, so a later seek (or the EOF branch, which assigns no frame) cannot rewrite it.
struct LockedSeekCapture: Equatable {
    let seekedToEnd: Bool
    /// nil on the EOF branch: the engine assigns no frame there and none is fabricated.
    let landedFrame: Int64?
    /// The frame converted to seconds INSIDE the same locked region (frame / file sampleRate),
    /// nil wherever `landedFrame` is nil — captured landing evidence that does not depend on
    /// any later mutable clock read (review blocker 3).
    let landedSeconds: TimeInterval?
    let requestedTime: TimeInterval
    /// The engine's own total-duration measure in seconds (cachedFrameCount / sampleRate),
    /// captured in the same locked region — the EOF branch's target evidence.
    let engineTotalSeconds: TimeInterval
}

/// Typed outcomes. Naming is deliberate: `cursorRepositioned` claims the READ CURSOR moved,
/// not that audible rendering has crossed the position; `completed` carries the AVPlayer
/// item-clock observation taken inside the completion handler — an already-playing clock
/// keeps advancing, so it is an observation, not an audible-landing claim.
enum SeekExecutionOutcome: Equatable {
    /// `landedSeconds` is the frame→seconds conversion CAPTURED INSIDE AudioReadTask's locked
    /// region — the completion's own landing evidence, immune to later mutable clock reads
    /// (review blocker: a second pending seek could otherwise supply its target as "position").
    case cursorRepositioned(identity: SeekIdentity, requestedTime: TimeInterval, landedFrame: Int64, landedSeconds: TimeInterval)
    case endOfFile(identity: SeekIdentity, requestedTime: TimeInterval, engineTotalSeconds: TimeInterval)
    case completed(identity: SeekIdentity, effectiveRequest: TimeInterval, observedItemClock: TimeInterval)
    case cancelled(identity: SeekIdentity)
    case engineUnavailable(identity: SeekIdentity)
    /// The deadline check at the ACTUAL mutation site (native call / queued read-task call)
    /// found the budget already expired: no effect was issued. Distinct from `cancelled`
    /// (which does not prove no seek) — this PROVES no seek, so the coordinator settles the
    /// refused-before-release arm.
    case expiredBeforeMutation(identity: SeekIdentity)
}

extension SeekIdentity {
    /// Replacement detection compares the ENGINE OBJECTS only: the invocationToken is
    /// per-invocation and must NOT participate (a live probe carries a fresh token).
    func sameEngineObjects(as other: SeekIdentity) -> Bool {
        playerID == other.playerID && readTaskID == other.readTaskID && itemID == other.itemID
    }
}

/// Engines that can issue an identity-carrying seek with a CALLER-SUPPLIED invocation token
/// (task67 seek_relative client slice, spec a3af56dd): the identified path correlates the
/// completion to the initiating invocation by token, so the token must be minted by the
/// initiator, not by the engine.
protocol TypedSeekingPlayer: AnyObject {
    /// Issues the seek and returns the identity actually initiated (nil impossible today —
    /// engines mint an identity even on the unavailable path — the optional keeps room for
    /// engines that cannot initiate at all). `deadlineNs` is the ORIGINAL admission bound on a
    /// monotonic clock: engines MUST check it at the actual mutation site (DefaultPlayer before
    /// the native call; EffectsPlayer inside the serialSeekQueue block, so queue delay cannot
    /// push an expired effect through) and deliver `expiredBeforeMutation` instead of mutating.
    @discardableResult
    func seekTo(_ time: TimeInterval, completion: (() -> Void)?, typedCompletion: ((SeekExecutionOutcome) -> Void)?, invocationToken: UUID?, deadlineNs: UInt64?) -> SeekIdentity?
    /// The LIVE engine objects right now (fresh token) — the settlement-time replacement probe.
    func currentEngineIdentity() -> SeekIdentity?
}
