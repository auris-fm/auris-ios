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
    /// - Parameter acousticWakeOnly: the engine's audio verdict, when it could make one.
    ///   `true` is authoritative: the capture measurably ended with the wake word, so nothing was
    ///   said after it however ASR spelled the phrase. `false` adds nothing (the text rule still
    ///   applies). `nil` means no audio decision was possible.
    /// THE decision, taken from the whole input.
    ///
    /// The single entry point on purpose. Eligibility is a property of the capture — transcript
    /// AND the audio verdict — so a gate that asks the question from one field alone can reach the
    /// opposite answer from the gate before it. That is not hypothetical: the eager barge-in gate
    /// decided from `routerTranscript` alone, so a misspelled bare wake over a playing answer
    /// stopped playback and was then submitted as a command. Passing the input makes the fields
    /// travel together and leaves nothing for a new call site to forget.
    static func decide(_ input: IntentRoutingInput) -> RouteInputEligibility {
        decide(transcript: input.routerTranscript, acousticWakeOnly: input.acousticWakeOnly)
    }

    static func decide(transcript: String, acousticWakeOnly: Bool? = nil) -> RouteInputEligibility {
        // Checked before `.blank`: a capture that ended with the wake word is a session start even
        // if the recogniser returned an empty string, and `.blank` would otherwise claim it.
        if acousticWakeOnly == true { return .silentSessionStart }
        if transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .blank }
        if WakeWordPhraseSet.isWakeOnly(transcript) { return .silentSessionStart }
        return .route
    }
}
