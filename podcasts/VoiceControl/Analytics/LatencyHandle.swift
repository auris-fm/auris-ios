import Foundation

/// A `TurnLatencyContext` that takes no part in its owner's equality.
///
/// The latency context describes the same dispatch whether or not two values happen to share it,
/// so it must not affect `==`. Excluding it by writing a hand-maintained `==` on the owning type
/// would work exactly until the next field is added there, which then silently drops out of
/// equality too. Wrapping it keeps the compiler-generated `==` for the owner and confines the
/// exception to one documented place.
///
/// Owners hold it NON-optionally, defaulting to `LatencyHandle()`. An optional field would put the
/// exception straight back: Swift compares optionals by case first, so a value carrying a handle
/// and one carrying `nil` are unequal before `==` is ever consulted. A turn without a context says
/// so with a `nil` *context* inside a present handle, which is what carries the exemption.
struct LatencyHandle: Equatable {
    let context: TurnLatencyContext?

    init(_ context: TurnLatencyContext? = nil) {
        self.context = context
    }

    /// ALWAYS equal: the wrapped context takes no part in the owner's identity, so two handles
    /// compare equal however their contexts differ — including one being absent.
    static func == (_: LatencyHandle, _: LatencyHandle) -> Bool { true }
}
