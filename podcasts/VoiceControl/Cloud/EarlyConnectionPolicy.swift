import Foundation

/// Whether an early-opened cloud connection may still carry this turn.
///
/// A connection opened before the request is ready is useful only while it is fresh. The server
/// gives a connection a fixed window from its upgrade to receive the first frame, and closes it
/// with nothing admitted or charged when that window expires; the client cannot distinguish that
/// close from any other, so the deadline is enforced on its own clock, measured from when the
/// upgrade request was sent. Waiting for a close handler would mean sending into a connection that
/// is already gone and losing the turn.
///
/// The two clocks measure the same silent period, so the client bound has to be the tighter one:
/// a connection older than this limit is refused and a fresh one opened instead. The limit tracks
/// the server's window rather than standing on its own — where the server's window is shorter than
/// this figure the age rule cannot keep a socket alive by itself, and what actually makes reuse
/// safe is the re-dial of a send that fails on one. The limit only decides how often that is needed.
enum EarlyConnectionPolicy {
    /// Age of an early connection at which it stops carrying its turn. One second inside the
    /// server window the endpoint is specced for; see the type's doc for why that pairing, and not
    /// the figure alone, is what this number means.
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
