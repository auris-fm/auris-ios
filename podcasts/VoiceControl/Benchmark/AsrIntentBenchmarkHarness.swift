#if DEBUG
import Foundation
import PocketCastsUtils

/// Debug-only launch trigger for the Item 21 measured run.
///
/// Set on launch (simctl launch env or Xcode scheme):
/// - `ASR_INTENT_BENCHMARK_UTTERANCES` — absolute path to the text-contract
///   JSONL (1118 rows, frozen sha `20a68433…`)
/// - `ASR_INTENT_BENCHMARK_TRANSLATIONS` — optional English sidecar JSON
/// - `ASR_INTENT_BENCHMARK_SIDELOAD_DIR` — absolute path to the Q8 sideload dir
///
/// The harness runs D (production english_v1) then installs the sideload and
/// runs E (dual_v1, gate opened only for the run), writes the report + run
/// manifest into app Documents, and clears the gate before returning.
enum AsrIntentBenchmarkHarness {
    static func runIfRequested() {
        let env = ProcessInfo.processInfo.environment
        guard let utterancesPath = env["ASR_INTENT_BENCHMARK_UTTERANCES"] else { return }
        let sideloadDir = env["ASR_INTENT_BENCHMARK_SIDELOAD_DIR"].map { URL(fileURLWithPath: $0) }
        let translationsURL = env["ASR_INTENT_BENCHMARK_TRANSLATIONS"].map { URL(fileURLWithPath: $0) }
        var config = RepresentationBenchmarkConfig(warmupIterations: 3, measuredIterations: 30)
        if let value = env["ASR_INTENT_BENCHMARK_WARMUP"], let parsed = Int(value), parsed >= 0 {
            config.warmupIterations = parsed
        }
        if let value = env["ASR_INTENT_BENCHMARK_MEASURED"], let parsed = Int(value), parsed > 0 {
            config.measuredIterations = parsed
        }
        let maxCases = env["ASR_INTENT_BENCHMARK_MAX_CASES"].flatMap(Int.init)
        Task.detached(priority: .userInitiated) {
            await run(
                utterancesURL: URL(fileURLWithPath: utterancesPath),
                translationsURL: translationsURL,
                sideloadDir: sideloadDir,
                config: config,
                maxCases: maxCases
            )
        }
    }

    static func run(
        utterancesURL: URL,
        translationsURL: URL?,
        sideloadDir: URL?,
        config: RepresentationBenchmarkConfig = RepresentationBenchmarkConfig(warmupIterations: 3, measuredIterations: 30),
        maxCases: Int? = nil
    ) async {
        do {
            let runner = AsrIntentBenchmarkRunner()
            runner.driver.config = config
            let translations = try translationsURL.map { try UtteranceSetLoader.loadTranslations(fileURL: $0) } ?? [:]
            var cases = try UtteranceSetLoader.load(
                fileURL: utterancesURL,
                translations: translations,
                failClosedOnMissingTranslations: true
            )
            if let maxCases, cases.count > maxCases {
                cases = Array(cases.prefix(maxCases))
            }

            var caseReports: [RepresentationBenchmarkReport.CaseReport] = []

            // D on the installed production english_v1 model.
            let router = LfmIntentRouter()
            guard case .success = await router.ensureReady() else {
                FileLog.shared.addMessage("[Benchmark] router ensureReady failed for variant D")
                return
            }
            for benchmarkCase in cases {
                caseReports.append(
                    .init(
                        caseID: benchmarkCase.caseID,
                        language: benchmarkCase.language,
                        paths: [AsrIntentBenchmarkRunner.variantD: runner.measureCase(benchmarkCase, variant: AsrIntentBenchmarkRunner.variantD, router: router)]
                    )
                )
            }

            // E on the sideloaded dual_v1 release (gate opened for the run only).
            var sideloadRelease: String?
            var sideloadFormat: String?
            if let sideloadDir {
                try runner.installSideload(from: sideloadDir)
                RouterInputFormat.benchmarkGateOpen = true
                defer { RouterInputFormat.benchmarkGateOpen = false }
                sideloadRelease = runner.releaseVersion
                sideloadFormat = runner.routerInputFormat?.wireName
                let dualRouter = LfmIntentRouter()
                guard case .success = await dualRouter.ensureReady() else {
                    FileLog.shared.addMessage("[Benchmark] router ensureReady failed for variant E")
                    return
                }
                for (index, benchmarkCase) in cases.enumerated() {
                    let e = runner.measureCase(benchmarkCase, variant: AsrIntentBenchmarkRunner.variantE, router: dualRouter)
                    var paths = caseReports[index].paths
                    paths[AsrIntentBenchmarkRunner.variantE] = e
                    caseReports[index] = .init(
                        caseID: caseReports[index].caseID,
                        language: caseReports[index].language,
                        paths: paths
                    )
                }
            }

            let report = RepresentationBenchmarkReport(
                config: config,
                cases: caseReports
            )
            let manifest = AsrIntentBenchmarkRunner.RunManifest(
                utteranceSha256: runner.sha256(of: utterancesURL) ?? "unknown",
                sideloadRelease: sideloadRelease,
                sideloadRouterInputFormat: sideloadFormat,
                translationSource: translationsURL.map { "sidecar@\(runner.sha256(of: $0) ?? "unknown")" } ?? "native_fallback",
                gate: "benchmark-export exception, authorized @spec 2026-09-15",
                finishedAt: Date(),
                deviceStateAfterRun: "live LFM dir holds sideloaded dual_v1; production english_v1 NOT restored (dedicated benchmark sim)",
                translateEngineNote: "Apple Translation cannot run on simulator — iOS translate-stage cost is physical-iPhone-only; this run measures router cost with Gemini-stand-in sidecar (host OnDeviceTranslate engine parity)"
            )

            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let reportData = try encoder.encode(report)
            let manifestData = try encoder.encode(manifest)
            try reportData.write(to: docs.appendingPathComponent("representation_benchmark_report.json"))
            try manifestData.write(to: docs.appendingPathComponent("representation_benchmark_manifest.json"))
            FileLog.shared.addMessage("[Benchmark] Item 21 run complete: \(caseReports.count) cases → Documents/representation_benchmark_report.json")
        } catch {
            FileLog.shared.addMessage("[Benchmark] Item 21 run failed: \(error)")
        }
    }
}

#endif
