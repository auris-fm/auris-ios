import Foundation

/// Whether an early-opened cloud connection may still carry this turn.
///
/// A connection opened before the request is ready is useful only while it is fresh, so the client
/// bounds how long it will hold one. That bound is on its own clock, measured from when the upgrade
/// request was sent, because the server's close is not observable as a reason: the client cannot
/// distinguish one from any other close, and waiting for a close handler would mean sending into a
/// connection that is already gone.
///
/// The client does not send on a connection older than nine seconds, counted from when it sent the
/// upgrade request (cloud-assistant.md, Unused connections).
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
