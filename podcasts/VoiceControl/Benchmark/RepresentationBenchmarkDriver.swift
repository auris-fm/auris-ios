#if DEBUG
import Foundation

/// One benchmark utterance: `case_id`, `language`, native ASR text, and the
/// English routing transcript (Pipeline E needs both; D uses only English).
struct RepresentationBenchmarkCase: Equatable {
    let caseID: String
    let language: String
    let nativeText: String
    let englishText: String
    var isRejection: Bool

    init(
        caseID: String,
        language: String,
        nativeText: String,
        englishText: String,
        isRejection: Bool = false
    ) {
        self.caseID = caseID
        self.language = language
        self.nativeText = nativeText
        self.englishText = englishText
        self.isRejection = isRejection
    }
}

struct RepresentationBenchmarkConfig: Codable, Equatable {
    var warmupIterations: Int
    var measuredIterations: Int
}

/// Aggregated measurements for one case on one path (D or E).
struct RepresentationBenchmarkCaseReport: Codable {
    let inputFormat: String
    let warmupIterations: Int
    let measuredIterations: Int
    let medianTotalMs: Double
    let p95TotalMs: Double
    let medianTokenizeMs: Double?
    let medianClassifyMs: Double?
    let medianGenerateMs: Double?
    /// Samples kept for the report (measured only, warm-up excluded).
    let samples: [Sample]

    struct Sample: Codable {
        let totalLatencyMs: Double
        let stageLatencies: RouterStageLatencies
        let outcome: String
        var failedStage: String?
        var reason: String?
    }
}

struct RepresentationBenchmarkReport: Codable {
    let config: RepresentationBenchmarkConfig
    let cases: [CaseReport]

    struct CaseReport: Codable {
        let caseID: String
        let language: String
        /// Keyed by path label, e.g. `D_english_v1`, `E_dual_v1`.
        let paths: [String: RepresentationBenchmarkCaseReport]
    }
}

/// Measures router latency for the representation benchmark (Item 21).
/// The router owns its per-stage timing (`RouterStageDiagnostic`); this driver
/// only supplies the measurement discipline: N warm-up iterations excluded,
/// M measured, median + nearest-rank p95.
struct RepresentationBenchmarkDriver {
    var config = RepresentationBenchmarkConfig(warmupIterations: 3, measuredIterations: 30)

    /// Measures one case. `makeInput` builds the path-shaped envelope (D:
    /// English-only; E: source + English transcript) and `pathRouter` runs it,
    /// returning that request's `RouterStageDiagnostic`.
    func measureCase(
        _ benchmarkCase: RepresentationBenchmarkCase,
        inputFormat: String,
        makeInput: (RepresentationBenchmarkCase) -> IntentRoutingInput,
        pathRouter: (IntentRoutingInput) -> RouterStageDiagnostic
    ) -> RepresentationBenchmarkCaseReport {
        let total = config.warmupIterations + config.measuredIterations
        var samples: [RepresentationBenchmarkCaseReport.Sample] = []
        samples.reserveCapacity(config.measuredIterations)

        for call in 0..<total {
            let diagnostic = pathRouter(makeInput(benchmarkCase))
            if call >= config.warmupIterations {
                samples.append(
                    .init(
                        totalLatencyMs: diagnostic.totalLatencyMs,
                        stageLatencies: diagnostic.stageLatencies,
                        outcome: diagnostic.finalOutcome,
                        failedStage: diagnostic.failedStage,
                        reason: diagnostic.reason
                    )
                )
            }
        }

        return Self.aggregate(inputFormat: inputFormat, config: config, samples: samples)
    }

    static func aggregate(
        inputFormat: String,
        config: RepresentationBenchmarkConfig,
        samples: [RepresentationBenchmarkCaseReport.Sample]
    ) -> RepresentationBenchmarkCaseReport {
        let sortedTotals = samples.map(\.totalLatencyMs).sorted()
        func median(_ values: [Double]) -> Double? {
            guard !values.isEmpty else { return nil }
            let sorted = values.sorted()
            let mid = sorted.count / 2
            return sorted.count % 2 == 1 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2
        }
        func nearestRankP95(_ values: [Double]) -> Double? {
            guard !values.isEmpty else { return nil }
            let rank = max(1, Int((0.95 * Double(values.count)).rounded(.up)))
            return values.sorted()[rank - 1]
        }
        func medianStage(_ keyPath: KeyPath<RouterStageLatencies, Double?>) -> Double? {
            median(samples.compactMap { $0.stageLatencies[keyPath: keyPath] })
        }

        return RepresentationBenchmarkCaseReport(
            inputFormat: inputFormat,
            warmupIterations: config.warmupIterations,
            measuredIterations: samples.count,
            medianTotalMs: median(sortedTotals) ?? 0,
            p95TotalMs: nearestRankP95(sortedTotals) ?? 0,
            medianTokenizeMs: medianStage(\.tokenizeMs),
            medianClassifyMs: medianStage(\.classifyMs),
            medianGenerateMs: medianStage(\.generateMs),
            samples: samples
        )
    }
}

#endif
