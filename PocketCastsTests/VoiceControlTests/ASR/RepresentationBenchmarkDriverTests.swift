import XCTest
@testable import podcasts

/// Unit tests for the representation-benchmark measurement driver (Item 21):
/// warm-up exclusion, median/p95 aggregation, and JSON report encoding.
final class RepresentationBenchmarkDriverTests: XCTestCase {
    private func diagnostic(totalMs: Double, tokenize: Double, classify: Double, generate: Double) -> RouterStageDiagnostic {
        RouterStageDiagnostic(
            modelRelease: "test",
            quant: "q4",
            inputFormat: "test_format",
            sourceLanguage: "zh",
            translationKind: "none",
            classifierLabel: "playback",
            finalOutcome: RouterStageDiagnostic.outcomeIntent,
            failedStage: nil,
            reason: nil,
            stageLatencies: RouterStageLatencies(
                tokenizeMs: tokenize,
                classifyMs: classify,
                generateMs: generate,
                parseRepairMs: nil,
                mapperDialogMs: nil
            ),
            totalLatencyMs: totalMs
        )
    }

    func test_warmupIterationsAreExcludedFromMeasurements() {
        var calls = 0
        var sequence: [Double] = []
        // 2 warm-up calls return garbage-large values; must not appear in stats.
        let driver = RepresentationBenchmarkDriver(
            config: .init(warmupIterations: 2, measuredIterations: 3)
        )
        let router: (IntentRoutingInput) -> RouterStageDiagnostic = { _ in
            defer { calls += 1 }
            if calls < 2 { return self.diagnostic(totalMs: 10_000, tokenize: 10_000, classify: 0, generate: 0) }
            sequence.append(Double(100 + calls))
            return self.diagnostic(totalMs: Double(100 + calls), tokenize: 1, classify: 2, generate: 3)
        }

        let report = driver.measureCase(
            RepresentationBenchmarkCase(
                caseID: "c1",
                language: "zh",
                nativeText: "暂停",
                englishText: "pause"
            ),
            inputFormat: "test_format",
            makeInput: { .english(transcript: $0.englishText) },
            pathRouter: router
        )

        XCTAssertEqual(calls, 5, "2 warm-up + 3 measured")
        XCTAssertFalse(
            report.samples.contains { $0.totalLatencyMs >= 10_000 },
            "warm-up samples must be excluded"
        )
        XCTAssertEqual(report.samples.count, 3)
    }

    func test_medianAndP95AreComputedFromMeasuredSamples() {
        let totals: [Double] = [10, 20, 30, 40, 100]
        var index = 0
        let driver = RepresentationBenchmarkDriver(
            config: .init(warmupIterations: 0, measuredIterations: totals.count)
        )
        let report = driver.measureCase(
            RepresentationBenchmarkCase(caseID: "c1", language: "en", nativeText: "pause", englishText: "pause"),
            inputFormat: "test_format",
            makeInput: { .english(transcript: $0.englishText) },
            pathRouter: { _ in
                defer { index += 1 }
                return self.diagnostic(totalMs: totals[index], tokenize: 1, classify: 1, generate: 1)
            }
        )

        XCTAssertEqual(report.medianTotalMs, 30)
        // Nearest-rank p95 of 5 samples → 5th sorted value.
        XCTAssertEqual(report.p95TotalMs, 100)
    }

    func test_jsonReportEncodesPerCasePerPath() throws {
        let driver = RepresentationBenchmarkDriver(config: .init(warmupIterations: 1, measuredIterations: 2))
        let caseReport = driver.measureCase(
            RepresentationBenchmarkCase(caseID: "c1", language: "zh", nativeText: "暂停", englishText: "pause"),
            inputFormat: "test_format",
            makeInput: { .english(transcript: $0.englishText) },
            pathRouter: { _ in self.diagnostic(totalMs: 42, tokenize: 1, classify: 30, generate: 11) }
        )
        let report = RepresentationBenchmarkReport(
            config: .init(warmupIterations: 1, measuredIterations: 2),
            cases: [
                .init(
                    caseID: "c1",
                    language: "zh",
                    paths: [
                        "D_english_v1": caseReport,
                        "E_dual_v1": caseReport
                    ]
                )
            ]
        )

        let data = try JSONEncoder().encode(report)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertNotNil(json?["config"])
        let cases = json?["cases"] as? [[String: Any]]
        XCTAssertEqual(cases?.count, 1)
        let paths = cases?.first?["paths"] as? [String: Any]
        XCTAssertEqual(paths?.count, 2, "both D and E reports present per case")
    }
}

extension RepresentationBenchmarkDriverTests {
    func test_samplesCarryFailureDiagnostics() {
        var d = diagnostic(totalMs: 10, tokenize: 5, classify: 2, generate: 1)
        // Rebuild with failure fields via the memberwise init.
        d = RouterStageDiagnostic(
            modelRelease: "test", quant: "q4", inputFormat: "f", sourceLanguage: "zh",
            translationKind: "none", classifierLabel: nil, finalOutcome: RouterStageDiagnostic.outcomeNoIntent,
            failedStage: RouterStageDiagnostic.stageTokenize, reason: RouterStageDiagnostic.reasonTokenizeFailed,
            stageLatencies: RouterStageLatencies(tokenizeMs: 5, classifyMs: nil, generateMs: nil, parseRepairMs: nil, mapperDialogMs: nil),
            totalLatencyMs: 10
        )
        let driver = RepresentationBenchmarkDriver(config: .init(warmupIterations: 0, measuredIterations: 1))
        let report = driver.measureCase(
            RepresentationBenchmarkCase(caseID: "c1", language: "zh", nativeText: "x", englishText: "y"),
            inputFormat: "test_format",
            makeInput: { .english(transcript: $0.englishText) },
            pathRouter: { _ in d }
        )
        XCTAssertEqual(report.samples.first?.failedStage, "tokenize")
        XCTAssertEqual(report.samples.first?.reason, "tokenize_failed")
    }
}
