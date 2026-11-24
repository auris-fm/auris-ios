import XCTest

import Fingerprint

@testable import podcasts

/// The library's matcher, run on a device, producing the ranked lists the rule is judged against.
///
/// `AurisMatchAcceptanceRuleTests` checks the rule against recorded lists, which cannot show
/// that the matcher still produces them: the rule and its fixture could agree with each other
/// and both be wrong. This rebuilds the references from the recorded inputs, asks the real
/// `CheckpointMatcher` for six candidates per window, and requires the same six lists back.
final class FingerprintMatcherTop6Tests: XCTestCase {

    private struct Inputs: Decodable {
        struct Checkpoint: Decodable {
            let timestampS: Double
            let values: [UInt32]

            private enum CodingKeys: String, CodingKey {
                case timestampS = "timestamp_s"
                case values
            }
        }

        struct Case: Decodable {
            let name: String
            let referenceCheckpoints: Int
            let queryValues: [UInt32]

            private enum CodingKeys: String, CodingKey {
                case name
                case referenceCheckpoints = "reference_checkpoints"
                case queryValues = "query_values"
            }
        }

        let reference: [Checkpoint]
        let cases: [Case]
    }

    private struct Expected: Decodable {
        struct Candidate: Decodable {
            let timestamp: Double
            let score: Float
        }

        struct Case: Decodable {
            let name: String
            let candidates: [Candidate]
        }

        let cases: [Case]
    }

    private func load<T: Decodable>(_ type: T.Type, from name: String) throws -> T {
        let url = try XCTUnwrap(
            Bundle(for: Self.self).url(forResource: name, withExtension: "json", subdirectory: "Fixtures")
                ?? Bundle(for: Self.self).url(forResource: name, withExtension: "json"),
            "\(name).json is not in the test bundle"
        )
        return try JSONDecoder().decode(T.self, from: Data(contentsOf: url))
    }

    /// Every one of the forty windows, through the real matcher.
    func testTheMatcherReproducesEveryRecordedTop6List() throws {
        let inputs = try load(Inputs.self, from: "matcher-top6-inputs")
        let expected = try load(Expected.self, from: "matcher-top6-cases")

        XCTAssertEqual(inputs.cases.count, 40)
        XCTAssertEqual(
            inputs.cases.map(\.name), expected.cases.map(\.name),
            "the two fixture files describe different cases, or in a different order"
        )

        var compared = 0
        for (testCase, want) in zip(inputs.cases, expected.cases) {
            let matcher = CheckpointMatcher()
            // Only the first `reference_checkpoints` entries: a short reference is what makes
            // some of these cases interesting, and adding the rest would change their answers.
            for checkpoint in inputs.reference.prefix(testCase.referenceCheckpoints) {
                matcher.add(
                    timestamp: Float(checkpoint.timestampS),
                    hashes: checkpoint.values,
                    duration: 8
                )
            }

            let got = matcher.findTopMatches(queryHashes: testCase.queryValues, maxResults: UInt32(6))

            XCTAssertEqual(
                got.count, want.candidates.count,
                "\(testCase.name): candidate count"
            )
            for (index, pair) in zip(got, want.candidates).enumerated() {
                XCTAssertEqual(
                    pair.0.timestamp, Float(pair.1.timestamp), accuracy: 0.001,
                    "\(testCase.name) candidate \(index): timestamp"
                )
                XCTAssertEqual(
                    pair.0.score, pair.1.score, accuracy: 1e-5,
                    "\(testCase.name) candidate \(index): score"
                )
                compared += 1
            }
        }

        // Every candidate in the fixture: 216, not 40 x 6, because a reference too short to
        // offer six candidates returns fewer. Pinned so a run that stopped early, or silently
        // matched nothing, cannot still be green.
        XCTAssertEqual(compared, 216)
    }
}
