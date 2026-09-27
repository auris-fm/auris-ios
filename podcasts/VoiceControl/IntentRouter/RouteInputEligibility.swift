import Foundation

/// What an incoming transcript is, before anything tries to route it.
enum RouteInputEligibility: Equatable {
    /// Worth classifying: it may be a command or a question.
    case route
    /// The user opened the session and said nothing else. Silence is the correct
    /// response — a wake-only capture is the start of a session, not a failed
    /// question, so it plays nothing and must not be counted as an unclassified
    /// turn either.
    case silentSessionStart
    /// Nothing to send: no utterance survived capture.
    case blank
}

/// The decision that runs before classification.
///
/// It exists as its own unit because it is the only thing standing between a
/// session-start capture and the "too many unclassified" path: a blank or
/// wake-only transcript that fell through to classification would increment the
/// null counter and eventually play the error earcon, which the silent rule
/// forbids. Extracting it makes that reachable in tests without a service seam.
enum RouteInputEligibilityPolicy {
    static func decide(transcript: String) -> RouteInputEligibility {
        if transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .blank }
        if WakeWordPhraseSet.isWakeOnly(transcript) { return .silentSessionStart }
        return .route
    }
}
