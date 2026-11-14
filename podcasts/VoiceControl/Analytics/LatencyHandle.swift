import Foundation

/// A `TurnLatencyContext` that takes no part in its owner's equality.
///
/// The latency context describes the same dispatch whether or not two values happen to share it,
/// so it must not affect `==`. Excluding it by writing a hand-maintained `==` on the owning type
/// would work exactly until the next field is added there, which then silently drops out of
/// equality too. Wrapping it keeps the compiler-generated `==` for the owner and confines the
/// exception to one documented place.
struct LatencyHandle: Equatable {
    let context: TurnLatencyContext?

    init(_ context: TurnLatencyContext? = nil) {
        self.context = context
    }

    /// Never equal: the wrapped context is identity-free for comparison purposes.
    static func == (_: LatencyHandle, _: LatencyHandle) -> Bool { true }
}
