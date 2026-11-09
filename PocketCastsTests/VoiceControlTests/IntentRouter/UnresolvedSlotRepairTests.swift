import CryptoKit
import XCTest
@testable import podcasts

/// The shared multilingual fixtures in `Fixtures/unresolved_slot_repair.json` are authored once and
/// consumed by every client, so they are the contract this file checks against rather than a set of
/// expectations written to match whatever the code already does.
///
/// A fixture whose `repaired` is null says the whole call must be dropped: an utterance that offers
/// alternatives, states a lower bound, or attaches a future condition has no settled amount, and
/// acting on a guess is worse than not acting. A fixture whose `repaired` is non-null says the
/// answer is already settled and must survive untouched.
final class UnresolvedSlotRepairTests: XCTestCase {

    private struct Fixture: Decodable {
        /// Parameters are mixed: `delta_seconds` is a number and `direction` is a word, so each
        /// value keeps whichever scalar the fixture stated.
        enum Scalar: Decodable, Equatable {
            case int(Int)
            /// Speeds are fractional (`0.5`), so a whole-number-only reader loses them.
            case double(Double)
            case string(String)

            init(from decoder: Decoder) throws {
                let container = try decoder.singleValueContainer()
                if let value = try? container.decode(Int.self) {
                    self = .int(value)
                } else if let value = try? container.decode(Double.self) {
                    self = .double(value)
                } else {
                    self = .string(try container.decode(String.self))
                }
            }

            var described: String {
                switch self {
                case .int(let value): return "\(value)"
                case .double(let value): return "\(value)"
                case .string(let value): return value
                }
            }
        }

        struct Call: Decodable {
            let tool: String
            let action: String
            let params: [String: Scalar]?
        }

        let id: String
        /// The language of the text being repaired. Absent when the fixture deliberately leaves it
        /// unstated, which is itself a case: repair must not guess a language.
        let textLanguage: String?
        let sourceLanguage: String?
        let utterance: String

        /// A label for reports, not an input to repair.
        var language: String {
            textLanguage ?? sourceLanguage ?? "unstated"
        }

        enum CodingKeys: String, CodingKey {
            case id, utterance, predicted, repaired, reason
            case textLanguage = "text_language"
            case sourceLanguage = "source_language"
        }
        let predicted: Call
        let repaired: Call?
        let reason: String
    }

    /// The core commit the bundled copy was taken from. The file is authored there and copied here,
    /// so nothing regenerates it: without a pin the two drift apart silently and this suite goes on
    /// passing against a contract that no longer exists.
    private static let fixtureCoreCommit = "fa7a34c1"
    private static let fixtureSHA256 =
        "7c35fcc3ca78df1c55d226f49007a8c557f224cfd78b5082a5d6452f727cdf8f"

    private func fixtureData() throws -> Data {
        let url = try XCTUnwrap(
            Bundle(for: Self.self).url(
                forResource: "unresolved_slot_repair", withExtension: "json"),
            "the shared fixture file must be bundled with the tests")
        return try Data(contentsOf: url)
    }

    /// Guards the copy against silent drift from the shared set.
    func test_theBundledFixturesMatchThePinnedCoreRevision() throws {
        let digest = Self.sha256Hex(try fixtureData())
        XCTAssertEqual(
            digest, Self.fixtureSHA256,
            "the bundled fixtures no longer match core \(Self.fixtureCoreCommit). If the shared set "
                + "changed on purpose, re-copy it and update both this pin and the commit note in the "
                + "same change; if it did not, the copy has been edited by hand and must be restored.")
    }

    /// `CryptoKit` is already linked for the app, so this avoids adding a dependency for a digest
    /// the test source cannot import any other way.
    private static func sha256Hex(_ data: Data) -> String {
        var digest = SHA256()
        digest.update(data: data)
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func loadFixtures() throws -> [Fixture] {
        try JSONDecoder().decode([Fixture].self, from: fixtureData())
    }

    /// Renders the call the way the fixture spells it, so a mismatch reports what differed rather
    /// than only that something did.
    private func rawCall(_ call: Fixture.Call) -> String {
        let params = (call.params ?? [:]).sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value.described)" }
            .joined(separator: ", ")
        return "\(call.tool)(action='\(call.action)'\(params.isEmpty ? "" : ", " + params))"
    }

    /// Every fixture, through the production repair path.
    func test_everySharedFixtureMatchesTheRepairResult() throws {
        let fixtures = try loadFixtures()
        XCTAssertEqual(fixtures.count, 136, "the shared fixture set must be complete")

        for fixture in fixtures {
            let raw = "<|tool_call_start|>[\(rawCall(fixture.predicted))]<|tool_call_end|>"
            let result = SlotRepair.repair(
                raw: raw,
                utterance: fixture.utterance,
                tool: fixture.predicted.tool,
                action: fixture.predicted.action,
                textLanguage: fixture.textLanguage)

            if let expected = fixture.repaired {
                let unwrapped = try XCTUnwrap(
                    result, "\(fixture.id) [\(fixture.language)]: expected a repaired call, got none")
                XCTAssertEqual(unwrapped.name, fixture.predicted.tool, "\(fixture.id): tool")
                for (key, value) in expected.params ?? [:] {
                    switch value {
                    case .int(let number):
                        XCTAssertEqual(
                            unwrapped.arguments[key] as? Int, number,
                            "\(fixture.id) [\(fixture.language)]: \(key) — \(fixture.reason)")
                    case .double(let number):
                        XCTAssertEqual(
                            unwrapped.arguments[key] as? Double, number,
                            "\(fixture.id) [\(fixture.language)]: \(key) — \(fixture.reason)")
                    case .string(let word):
                        XCTAssertEqual(
                            unwrapped.arguments[key] as? String, word,
                            "\(fixture.id) [\(fixture.language)]: \(key) — \(fixture.reason)")
                    }
                }
            } else {
                XCTAssertNil(
                    result,
                    "\(fixture.id) [\(fixture.language)] must repair to nothing — \(fixture.reason)"
                )
            }
        }
    }

    /// The deferral has to drop the CALL, not merely decline to fill the amount. If it only nulled
    /// the slot, the direction default would still reach the sink and the app would seek.
    func test_aDeferredUtteranceNeverReachesTheSink() throws {
        let fixtures = try loadFixtures().filter { $0.repaired == nil }
        XCTAssertFalse(fixtures.isEmpty, "expected deferred fixtures to exist")

        for fixture in fixtures {
            let raw = "<|tool_call_start|>[\(rawCall(fixture.predicted))]<|tool_call_end|>"
            let call = SlotRepair.repair(
                raw: raw,
                utterance: fixture.utterance,
                tool: fixture.predicted.tool,
                action: fixture.predicted.action,
                textLanguage: fixture.textLanguage)

            // A nil call is the only outcome that cannot produce a seek: there is nothing to map.
            XCTAssertNil(
                call,
                "\(fixture.id) produced \(String(describing: call?.arguments)) and would reach the sink")
        }
    }

    /// Two shapes the shared fixtures do not cover, reported from source probes.
    ///
    /// "at least a minute" is an unrestricted quantity written with an article, and
    /// "half an hour" is a name that contains a temporal word. Both are ordinary settled requests;
    /// deferring them would refuse a clear instruction.
    func test_articleQuantitiesAndQuotedTitlesStaySettled() {
        // An article is a quantity, so a bound on it is still a bound: this one must defer.
        XCTAssertNil(
            SlotRepair.repair(
                raw: "<|tool_call_start|>[playback(action='seek_relative', direction='backward')]<|tool_call_end|>",
                utterance: "rewind at least a minute",
                tool: "playback", action: "seek_relative", textLanguage: "en"),
            "a bound with an article is still a bound")

        // The same article in a plain amount states one value and must survive.
        let plain = SlotRepair.repair(
            raw: "<|tool_call_start|>[playback(action='seek_relative', direction='backward')]<|tool_call_end|>",
            utterance: "rewind a minute",
            tool: "playback", action: "seek_relative", textLanguage: "en")
        XCTAssertNotNil(plain, "a plain article amount is settled")
        XCTAssertEqual(plain?.arguments["delta_seconds"] as? Int, -60)

        // A quoted title is a name. Smart quotes must be normalized, or the title's own words
        // read as a condition and a clear bookmark command gets refused.
        // `play` takes a `ref`, which is where a bookmark name lands; the fixture set covers the
        // straight-quoted form, so this pins the smart-quoted one.
        for (opening, closing) in [("\u{201C}", "\u{201D}"), ("\u{300C}", "\u{300D}")] {
            let call = SlotRepair.repair(
                raw: "<|tool_call_start|>[bookmark(action='play', ref='x')]<|tool_call_end|>",
                utterance: "play bookmark \(opening)When This Episode Ends\(closing)",
                tool: "bookmark", action: "play", textLanguage: "en")
            XCTAssertNotNil(call, "a quoted bookmark name is a reference, not a condition (\(opening))")
        }
    }

    /// What the service actually does with a deferred turn.
    ///
    /// Repair returning nil is not the end of the story: the router reports a failed parse, and the
    /// escalation policy decides what happens next. A deferred turn must reach the service rather
    /// than a local sink, because the alternatives, bounds and conditions are answers the local
    /// model could not give and the service may. The counterpart matters just as much: the turn
    /// must not also be executed locally, since that is the wrong action this work exists to
    /// prevent.
    func test_aDeferredUtteranceEscalatesInsteadOfTouchingALocalSink() throws {
        let fixtures = try loadFixtures().filter { $0.repaired == nil }
        XCTAssertFalse(fixtures.isEmpty, "expected deferred fixtures to exist")

        for fixture in fixtures {
            let raw = "<|tool_call_start|>[\(rawCall(fixture.predicted))]<|tool_call_end|>"
            let call = SlotRepair.repair(
                raw: raw,
                utterance: fixture.utterance,
                tool: fixture.predicted.tool,
                action: fixture.predicted.action,
                textLanguage: fixture.textLanguage)
            XCTAssertNil(call, "\(fixture.id): a deferred turn must not produce a call to execute")

            // The reason the router reports when repair declines.
            let reason = RouterStageDiagnostic.reasonParseOrRepairFailed
            XCTAssertEqual(
                RouteFailureEscalationPolicy.outcome(for: reason), .escalate,
                "\(fixture.id): a deferred turn asks the service rather than staying silent")

            // The mapper is how a parsed call becomes an intent a sink executes, so an unmappable
            // call proves the local route is empty rather than merely unvisited.
            // `call` is proven nil above, so nothing can be mapped. Stated as a property of the
            // mapper rather than of this one value: a call reconstructed from the predicted
            // arguments would be the wrong action, and deferring must not leave that reachable.
            if let unmapped = call {
                let intent: (any VoiceIntent)? = ToolCallMapper().map(unmapped)
                XCTAssertNil(
                    intent,
                    "\(fixture.id): mapped to \(String(describing: intent)) — the deferred turn "
                        + "would have executed locally as well as escalated")
            }
        }
    }
}
