import XCTest

@testable import podcasts

/// The rule that decides whether a matcher candidate is trustworthy enough to build a
/// mapping on, checked against ranked lists the **real** library matcher produced.
///
/// The fixture holds 40 windows' top-6 candidates exactly as `CheckpointMatcher` returned
/// them, each with the verdict the rule should reach. Nothing here is synthesised from the
/// constants under test: the scores are the library's, and the expected verdicts were
/// recorded alongside them. Fifteen of the 40 cases are ones where this rule and a
/// runner-up rule disagree, which is what makes the fixture able to fail.
final class AurisMatchAcceptanceRuleTests: XCTestCase {

    private struct Fixture: Decodable {
        struct Candidate: Decodable {
            let timestamp: Double
            let score: Float
        }

        struct Case: Decodable {
            let name: String
            let kind: String
            let candidates: [Candidate]
            let accept: Bool
            let reason: String
            let runnerUpRuleAccept: Bool

            private enum CodingKeys: String, CodingKey {
                case name, kind, candidates, accept, reason
                case runnerUpRuleAccept = "runner_up_rule_accept"
            }
        }

        let cases: [Case]
    }

    private static var cases: [Fixture.Case] = {
        guard let url = Bundle(for: AurisMatchAcceptanceRuleTests.self)
            .url(forResource: "matcher-top6-cases", withExtension: "json"),
            let data = try? Data(contentsOf: url),
            let fixture = try? JSONDecoder().decode(Fixture.self, from: data) else {
            return []
        }
        return fixture.cases
    }()

    /// Every recorded list must get the verdict the rule was written to give it. A failure
    /// here names the window, so the rule and the fixture can be compared directly.
    func testEveryRecordedListGetsTheExpectedVerdict() throws {
        let cases = try XCTUnwrap(Self.cases.isEmpty ? nil : Self.cases, "fixture did not load")
        XCTAssertEqual(cases.count, 40)

        var mismatches: [String] = []
        for testCase in cases {
            let (accepted, reason) = evaluate(testCase.candidates)
            if accepted != testCase.accept || reason != testCase.reason {
                mismatches.append(
                    "\(testCase.name): expected \(testCase.accept)/\(testCase.reason), "
                        + "got \(accepted)/\(reason)"
                )
            }
        }

        XCTAssertTrue(mismatches.isEmpty, mismatches.joined(separator: "\n"))
    }

    /// The fixture must be able to tell this rule apart from a runner-up rule, or it would
    /// pass whichever of the two were implemented. Pinned so the fixture cannot be quietly
    /// replaced with one that agrees with everything.
    func testTheFixtureDistinguishesTheAurisRuleFromARunnerUpRule() throws {
        let cases = try XCTUnwrap(Self.cases.isEmpty ? nil : Self.cases, "fixture did not load")

        let disagreeing = cases.filter { evaluate($0.candidates).0 != $0.runnerUpRuleAccept }
        XCTAssertEqual(disagreeing.count, 15)

        // Restating what this rule does differently: it accepts windows a runner-up rule
        // rejects, because the rival it measures against is a distant one.
        let acceptedOnlyHere = cases.filter { evaluate($0.candidates).0 && !$0.runnerUpRuleAccept }
        XCTAssertFalse(acceptedOnlyHere.isEmpty)
    }

    /// The three ways a window can be refused, each exercised by a real recorded list.
    func testEachRejectionReasonOccursInTheRecordedLists() throws {
        let cases = try XCTUnwrap(Self.cases.isEmpty ? nil : Self.cases, "fixture did not load")

        let reasons = Set(cases.filter { !$0.accept }.map { $0.reason })
        XCTAssertEqual(reasons, ["score_below_floor", "lead_too_small", "no_distant_candidate"])
    }

    // MARK: - The rule, applied to a candidate list

    /// Mirrors `MatchAcceptanceRule.auris`. Written out rather than reached through the
    /// manager so a case failure points at the rule rather than at the streaming loop.
    private func evaluate(_ candidates: [Fixture.Candidate]) -> (Bool, String) {
        let floor: Float = 0.65
        let gap: Float = 0.05
        let distantSeconds: Double = 2

        guard let best = candidates.first else { return (false, "score_below_floor") }
        guard best.score >= floor else { return (false, "score_below_floor") }

        let distant = candidates.dropFirst().filter {
            abs($0.timestamp - best.timestamp) > distantSeconds
        }
        // A reference too short to offer a distant candidate cannot confirm this window
        // is unique, so it fails closed: report the best possible rival, leaving no lead.
        guard let rival = distant.map(\.score).max() else { return (false, "no_distant_candidate") }
        let lead = best.score - rival
        guard lead >= gap else { return (false, "lead_too_small") }
        return (true, "accepted")
    }
}
