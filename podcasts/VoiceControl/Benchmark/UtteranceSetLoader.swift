#if DEBUG
import Foundation

/// Loads the shared utterance-set JSONL (Item 21 text contract, frozen sha
/// `20a68433…`): one JSON object per line with `case_id`, `language`, `text`,
/// `is_rejection`. An optional English-translation sidecar (`case_id` →
/// English) supplies the router transcripts for both pipeline paths; cases
/// without a sidecar entry fall back to the native text so latency rows are
/// never dropped (the fallback is labeled in the run manifest).
enum UtteranceSetLoader {
    struct LoaderError: Error, CustomStringConvertible {
        let line: Int
        let description: String
    }

    static func load(
        jsonl: String,
        translations: [String: String] = [:],
        failClosedOnMissingTranslations: Bool = false
    ) throws -> [RepresentationBenchmarkCase] {
        var cases: [RepresentationBenchmarkCase] = []
        for (index, rawLine) in jsonl.split(separator: "\n", omittingEmptySubsequences: true).enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let caseID = obj["case_id"] as? String,
                  let language = obj["language"] as? String,
                  let text = obj["text"] as? String
            else {
                throw LoaderError(line: index + 1, description: "missing required contract fields")
            }
            let english = translations[caseID]
            if failClosedOnMissingTranslations, language != "en", english == nil {
                throw LoaderError(
                    line: index + 1,
                    description: "missing non-English sidecar translation for \(caseID) (fail-closed)"
                )
            }
            cases.append(
                RepresentationBenchmarkCase(
                    caseID: caseID,
                    language: language,
                    nativeText: text,
                    englishText: english ?? text,
                    isRejection: obj["is_rejection"] as? Bool ?? false
                )
            )
        }
        return cases
    }

    static func load(
        fileURL: URL,
        translations: [String: String] = [:],
        failClosedOnMissingTranslations: Bool = false
    ) throws -> [RepresentationBenchmarkCase] {
        try load(
            jsonl: String(contentsOf: fileURL, encoding: .utf8),
            translations: translations,
            failClosedOnMissingTranslations: failClosedOnMissingTranslations
        )
    }

    /// Loads a `{ "case_id": "english", … }` JSON sidecar.
    static func loadTranslations(fileURL: URL) throws -> [String: String] {
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode([String: String].self, from: data)
    }
}

#endif
