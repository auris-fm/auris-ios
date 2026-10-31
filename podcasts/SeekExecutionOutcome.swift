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
    case cursorRepositioned(identity: SeekIdentity, requestedTime: TimeInterval, landedFrame: Int64)
    case endOfFile(identity: SeekIdentity, requestedTime: TimeInterval, engineTotalSeconds: TimeInterval)
    case completed(identity: SeekIdentity, effectiveRequest: TimeInterval, observedItemClock: TimeInterval)
    case cancelled(identity: SeekIdentity)
    case engineUnavailable(identity: SeekIdentity)
}
