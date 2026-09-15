import Foundation
import CryptoKit

/// Debug-only Item 21 measured-run harness (representation benchmark).
///
/// Protocol mirrors the Android lane: sideloaded Q8 `dual_v1` release is
/// copied over the app's live LFM dir (no `latest.json`, no upload), the
/// router is measured per case over the shared text contract for
/// D (`english_v1`) and E (`dual_v1`), and the report lands in Documents.
///
/// Provenance rules from the standing ruling (@spec, `#reviews:d18481a8`):
/// the run manifest records the contract sha, the sideload release, and the
/// benchmark-exception label. Production stays fail-closed: the `dual_v1`
/// gate is opened only for the duration of the run.
final class AsrIntentBenchmarkRunner {
    static let variantD = "D_english_v1"
    static let variantE = "E_dual_v1"

    struct RunManifest: Codable {
        let utteranceSha256: String
        let sideloadRelease: String?
        let sideloadRouterInputFormat: String?
        let translationSource: String
        let gate: String
        let finishedAt: Date
    }

    private let modelManager: ModelManager
    var driver = RepresentationBenchmarkDriver()

    init(modelManager: ModelManager = ModelManager()) {
        self.modelManager = modelManager
    }

    var releaseVersion: String? { modelManager.lfmReleaseVersion() }
    var routerInputFormat: RouterInputFormat? { modelManager.lfmRouterInputFormat() }

    /// Variant input envelopes, shared with the unit tests so both mobile
    /// lanes measure identical protocol. Throws on unknown variants.
    static func makeInputOrThrow(variant: String, benchmarkCase: RepresentationBenchmarkCase) throws -> IntentRoutingInput {
        let english = benchmarkCase.englishText
        switch variant {
        case variantD:
            // D (translate → english_v1): router sees English only.
            return IntentRoutingInput(
                sourceTranscript: benchmarkCase.nativeText,
                sourceLanguage: benchmarkCase.language,
                routerTranscript: english,
                translationKind: benchmarkCase.language == "en" ? .none : .platform
            )
        case variantE:
            // E (dual_v1): router renders from native + English transcript.
            return IntentRoutingInput(
                sourceTranscript: benchmarkCase.nativeText,
                sourceLanguage: benchmarkCase.language,
                routerTranscript: english,
                translationKind: benchmarkCase.language == "en" ? .none : .platform
            )
        default:
            throw BenchmarkVariantError.unknown(variant)
        }
    }

    static func makeInput(variant: String, benchmarkCase: RepresentationBenchmarkCase) -> IntentRoutingInput {
        // swiftlint:disable:next force_try
        try! makeInputOrThrow(variant: variant, benchmarkCase: benchmarkCase)
    }

    enum BenchmarkVariantError: Error {
        case unknown(String)
    }

    /// Copies a sideloaded release dir (manifest + assets) over the live LFM
    /// dir. Equivalent to a model update; no publish channel is touched.
    func installSideload(from sourceDir: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: modelManager.lfmDir, withIntermediateDirectories: true)
        for name in [ModelManager.lfmModelFilename, ModelManager.lfmClassifierFilename, ModelManager.lfmLabelMapFilename, "manifest.json"] {
            let source = sourceDir.appendingPathComponent(name)
            let target = modelManager.lfmDir.appendingPathComponent(name)
            if fileManager.fileExists(atPath: target.path) {
                try fileManager.removeItem(at: target)
            }
            try fileManager.copyItem(at: source, to: target)
        }
    }

    /// Measures one case on one path through `classify(input:)`, capturing the
    /// exactly-once per-request diagnostic from the router's metric sink.
    func measureCase(
        _ benchmarkCase: RepresentationBenchmarkCase,
        variant: String,
        router: LfmIntentRouter
    ) -> RepresentationBenchmarkCaseReport {
        var captured: RouterStageDiagnostic?
        let previousSink = router.onMetrics
        router.onMetrics = { captured = $0 }
        defer { router.onMetrics = previousSink }

        return driver.measureCase(
            benchmarkCase,
            inputFormat: variant,
            makeInput: { Self.makeInput(variant: variant, benchmarkCase: $0) },
            pathRouter: { input in
                _ = router.classify(input: input)
                guard let diagnostic = captured else {
                    fatalError("router classify produced no diagnostic for \(benchmarkCase.caseID)")
                }
                return diagnostic
            }
        )
    }

    func sha256(of fileURL: URL) -> String? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
