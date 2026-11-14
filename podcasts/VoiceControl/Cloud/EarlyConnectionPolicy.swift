import Foundation

/// Whether an early-opened cloud connection may still carry this turn.
///
/// A connection opened before the request is ready is useful only while it is fresh: the server
/// closes a connection that receives no first frame within 10 seconds, admitting and charging
/// nothing. That close is not observable as a reason — the client cannot distinguish an idle
/// timeout from any other close — so the deadline is enforced on the client's own clock, measured
/// from when the upgrade request was sent. Waiting for a close handler would mean sending into a
/// connection that is already gone and losing the turn.
///
/// The 9 second limit leaves a margin under the server's 10 seconds for the send to arrive and be
/// admitted. A connection at exactly the limit is not reused: the margin is what makes the reuse
/// safe, so erring toward a fresh connection is the conservative choice.
enum EarlyConnectionPolicy {
    /// Age of an early connection at which it stops carrying its turn.
    static let maximumAgeSeconds: TimeInterval = 9

    /// Decides reuse from the connection's age. `age` is measured on the client clock from the
    /// upgrade request, never from a server-reported figure.
    static func canSend(connectionAge: TimeInterval) -> Bool {
        connectionAge < maximumAgeSeconds
    }

    /// Says so in words a log reader can act on. Only two outcomes exist, so the caller never has
    /// to infer which one it took.
    static func describe(connectionAge: TimeInterval) -> String {
        canSend(connectionAge: connectionAge)
            ? "reusing early connection age=\(formatted(connectionAge))s"
            : "early connection too old age=\(formatted(connectionAge))s limit=\(Int(maximumAgeSeconds))s"
    }

    private static func formatted(_ seconds: TimeInterval) -> String {
        String(format: "%.1f", seconds)
    }
}
