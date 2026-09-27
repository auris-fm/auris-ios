import XCTest
@testable import podcasts

/// The policy unit is the interesting part of the contract: *where each reason
/// lands* decides whether the service ever sees the turn.
final class RouteFailureEscalationPolicyTests: XCTestCase {
    func testFailuresEscalate() {
        let failures = [
            RouterStageDiagnostic.reasonTokenizeFailed,
            RouterStageDiagnostic.reasonClassifyFailed,
            RouterStageDiagnostic.reasonGenerateFailed,
            RouterStageDiagnostic.reasonParseOrRepairFailed,
            RouterStageDiagnostic.reasonMapperOrDialogFailed,
            RouterStageDiagnostic.reasonInferenceException,
        ]
        for reason in failures {
            XCTAssertEqual(RouteFailureEscalationPolicy.outcome(for: reason), .escalate,
                           "\(reason) is a failure to decide, so the service gets the chance")
        }
    }

    /// Deliberate, but after a wake the user spoke to us: escalating gives up the
    /// label's role of keeping ambient audio local. Accepted trade, bounded by the
    /// grace window rather than by the label.
    func testNoMatchEscalates() {
        XCTAssertEqual(RouteFailureEscalationPolicy.outcome(for: RouterStageDiagnostic.reasonNoMatch), .escalate)
    }

    func testLocalCapabilityFailuresStayLocalAndVisible() {
        XCTAssertEqual(RouteFailureEscalationPolicy.outcome(for: RouterStageDiagnostic.reasonModelNotLoaded), .stayLocal)
        XCTAssertEqual(RouteFailureEscalationPolicy.outcome(for: RouterStageDiagnostic.reasonUnsupportedInputFormat), .stayLocal)
        XCTAssertEqual(RouteFailureEscalationPolicy.outcome(for: RouterStageDiagnostic.reasonBlankTranscript), .stayLocal)
    }

    /// Unlisted reasons fail toward the service rather than toward silence.
    func testUnknownReasonEscalatesRatherThanFallingSilent() {
        XCTAssertEqual(RouteFailureEscalationPolicy.outcome(for: nil), .escalate)
        XCTAssertEqual(RouteFailureEscalationPolicy.outcome(for: "a_reason_added_later"), .escalate)
    }

    /// The local set is explicit: no member of it may also escalate, which is what
    /// keeps "not a decision" from silently including "nothing to send".
    func testLocalReasonsAreExplicitAndDisjointFromFailures() {
        let failures = [
            RouterStageDiagnostic.reasonTokenizeFailed,
            RouterStageDiagnostic.reasonClassifyFailed,
            RouterStageDiagnostic.reasonGenerateFailed,
            RouterStageDiagnostic.reasonParseOrRepairFailed,
            RouterStageDiagnostic.reasonMapperOrDialogFailed,
            RouterStageDiagnostic.reasonInferenceException,
            RouterStageDiagnostic.reasonNoMatch,
        ]
        XCTAssertTrue(Set(failures).isDisjoint(with: RouteFailureEscalationPolicy.localReasons))
    }
}
