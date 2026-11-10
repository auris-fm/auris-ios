import Foundation

/// Decides, from elapsed speech, when a streaming wake result is final.
///
/// The detector scores a set of classifier windows that end within 2 seconds of speech onset. When
/// it scores a finished segment it sees all of them at once; when it scores while the user is still
/// speaking it sees only those whose audio already exists. The result is final exactly when no
/// window that could still arrive is able to beat the score already found — otherwise a positive
/// answer could be reported before the window that contradicts it has been scored.
///
/// This type holds that decision on its own so it can be controlled without audio. It makes no
/// claim about scores: it says when there is nothing left to wait for, and the detector decides
/// what the answer is.
enum StreamingWakePolicy {
    /// Last eligible window ends this far after onset. Derived from the detector's own geometry:
    /// the final embedding of window 25 ends 31360 samples after onset, just inside the 2 second
    /// eligible span. Matching this constant to the detector is the point of
    /// `StreamingWakeWindowTests`, because a mismatch would silently change which windows count.
    static let finalWindowEndSeconds: Double = 1.96

    /// A segment can only be scored definitively once the audio for its final eligible window
    /// exists. Before then any result is provisional.
    static func isFinal(speechSeconds: Double) -> Bool {
        speechSeconds >= finalWindowEndSeconds
    }

    /// True when the end-of-speech decision arrives before the final window could be scored — the
    /// only case where the pipeline waits for the detector rather than the other way round. The
    /// spec calls out segments shorter than 2 seconds specifically, and calls the wait "brief"
    /// because it is bounded by the final window's own position.
    static func mustWaitAtEndOfSpeech(speechSeconds: Double) -> Bool {
        !isFinal(speechSeconds: speechSeconds)
    }

    /// How long the pipeline would wait at end of speech. Zero when the result is already final.
    static func endOfSpeechWaitSeconds(speechSeconds: Double) -> Double {
        max(0, finalWindowEndSeconds - speechSeconds)
    }
}