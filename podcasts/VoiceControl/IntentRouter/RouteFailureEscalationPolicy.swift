import Foundation

/// What a routing outcome that produced no intent should do.
enum RouteFailureEscalation: Equatable {
    /// Dispatch to the service: the pipeline produced no answer, so asking is
    /// not overriding a decision.
    case escalate
    /// Keep the turn local, with the reason recorded at the decision site.
    case stayLocal
}

/// Who escalates when the local router returns no intent.
///
/// Mirrors the Android policy unit so both clients share one rule:
///
/// - **Escalate on a routing failure and on a deliberate `no_match`.** After a
///   wake the user has spoken to us, so if it isn't a local command the service
///   gets the chance to answer or decline. Escalating `no_match` gives up the
///   label's role of keeping ambient audio local — an accepted trade, bounded to
///   one dispatch per grace window (`GracePeriodSignal`).
/// - **Stay local for an empty transcript** (there is nothing to send) and for
///   **local capability failures** (`model_not_loaded`, `unsupported_input_format`).
///   Escalating those would turn a broken install into cloud traffic, put "pause"
///   on the network, or send nothing at all; they stay visible as diagnostics
///   instead. This mirrors the contract ruling that a local capability failure is
///   a *visible non-escalation*, not a silent one.
///
/// Unlisted reasons escalate: the set of silent-local reasons is deliberately
/// explicit, so a new router reason fails toward the service rather than toward
/// silence.
enum RouteFailureEscalationPolicy {
    static let localReasons: Set<String> = [
        RouterStageDiagnostic.reasonBlankTranscript,
        RouterStageDiagnostic.reasonModelNotLoaded,
        RouterStageDiagnostic.reasonUnsupportedInputFormat,
    ]

    static func outcome(for reason: String?) -> RouteFailureEscalation {
        // No reported metrics means the router never spoke, which is a failure
        // rather than a decision.
        guard let reason else { return .escalate }
        return localReasons.contains(reason) ? .stayLocal : .escalate
    }

    /// The same decision, with the transcript considered.
    ///
    /// A transcript that is the wake phrase and nothing else is a deliberate local
    /// rejection: speaking the wake word is the signal that the user started
    /// talking, not a question, so it must not be a routing or escalation candidate
    /// and must not spend the window's allowance. Anything that survives the wake
    /// phrase — including words the router failed to classify — follows the
    /// ordinary rules.
    static func outcome(for reason: String?, transcript: String) -> RouteFailureEscalation {
        WakeWordPhraseSet.isWakeOnly(transcript) ? .stayLocal : outcome(for: reason)
    }
}
