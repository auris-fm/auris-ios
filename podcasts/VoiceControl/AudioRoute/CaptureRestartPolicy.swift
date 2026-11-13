import Foundation

/// The decision for the next gate-driven capture start after a capture ended.
enum CaptureRestartDecision: Equatable {
    /// The end grants (or leaves standing) an automatic restart.
    case restart
    /// Automatic restarts stop: log `mic_restart_withheld` and wait for a new
    /// trigger before capture may start again.
    case withhold(ranMs: Int)
}

/// Owns the bounded automatic capture restart rule (core spec
/// "Automatic capture restarts"): capture that ends on its own while listening
/// is still allowed gets one automatic restart through the same start path.
/// If that restart fails to start or the restarted capture ends again within
/// 60 seconds, no further automatic restart is made until a new trigger
/// re-arms. A run of 60 seconds or more is healthy.
///
/// The policy is intentionally time-free: the service measures each run's
/// duration and feeds it in, so unit tests need no clocks.
final class CaptureRestartPolicy {
    /// A restart that ends after at least this long is a healthy run.
    private let healthyRunMs: Int
    /// Restarts are currently allowed. Cleared by a withhold, set by `reArm()`.
    private(set) var isArmed = true
    /// The run that just started was itself an automatic restart, so its own
    /// early death triggers the withhold.
    private(set) var restartIsRunning = false
    /// The previous capture ended on its own (not a user stop, not an
    /// interruption), so the next start through the start path is that
    /// automatic restart.
    private(set) var lastEndWasAutonomous = false

    init(healthyRunMs: Int = 60_000) {
        self.healthyRunMs = healthyRunMs
    }

    /// Whether a gate-driven start may run right now. While disarmed, every
    /// start would be an automatic restart (a genuine trigger re-arms first),
    /// so none may run.
    var mayStart: Bool { isArmed }

    /// Capture started. Marks the run as a restart when the previous capture
    /// ended on its own — that is the one automatic restart the end granted.
    func captureStarted() {
        restartIsRunning = lastEndWasAutonomous
        lastEndWasAutonomous = false
    }

    /// Capture ended on its own (a route change, a capture fault, a stream
    /// that stopped) — never a direct user request, never an interruption.
    func captureEndedAutonomously(ranMs: Int) -> CaptureRestartDecision {
        defer { lastEndWasAutonomous = true }
        if restartIsRunning, ranMs < healthyRunMs {
            isArmed = false
            restartIsRunning = false
            return .withhold(ranMs: ranMs)
        }
        restartIsRunning = false
        return .restart
    }

    /// The granted automatic restart failed to start (configure/engine error
    /// in the start path). `ran_ms` is 0: it never ran.
    func restartStartFailed() -> CaptureRestartDecision? {
        guard lastEndWasAutonomous || restartIsRunning else { return nil }
        isArmed = false
        restartIsRunning = false
        lastEndWasAutonomous = false
        return .withhold(ranMs: 0)
    }

    /// A direct user stop or an interruption. Never counted against the
    /// budget, and the next start is not a restart run (an interruption
    /// ending is never blocked by this rule).
    func stopWasUserOrInterruption() {
        lastEndWasAutonomous = false
        restartIsRunning = false
    }

    /// A new trigger (the user's device set changed, a blocker cleared, the
    /// user turned voice control on) re-arms automatic restarts. A pending
    /// restart identity survives: the trigger is often what lets the granted
    /// restart run (e.g. the reconnect that re-acquired the route), and that
    /// run must still count as the restart. Coming OUT of a withhold is
    /// different — the budget there is fully spent, so the next run is fresh.
    func reArm() {
        if !isArmed {
            lastEndWasAutonomous = false
        }
        isArmed = true
        restartIsRunning = false
    }
}
