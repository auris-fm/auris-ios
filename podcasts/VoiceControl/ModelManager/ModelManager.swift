import Foundation

class ModelManager: ObservableObject {
    @Published var downloadProgress: Double = 0
    @Published var isReady = false

    private let downloader = ModelDownloader()
    private let storageDir: URL

    init() {
        storageDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!.appendingPathComponent("Auris/Models")
        try? FileManager.default.createDirectory(at: storageDir, withIntermediateDirectories: true)
    }

    func ensureSelectedModels() async {
        let whisperDir = storageDir.appendingPathComponent("whisper-model")
        try? FileManager.default.createDirectory(at: whisperDir, withIntermediateDirectories: true)

        let whisperSpec = ModelSpec(
            id: "whisper",
            files: [
                ModelFile(
                    url: URL(string: "https://download.auris.fm/whisper/ggml-small-q5_1.bin")!,
                    filename: "ggml-small-q5_1.bin",
                    sha256: nil
                ),
            ],
            targetDir: "whisper-model"
        )

        _ = await downloadModel(spec: whisperSpec)

        // FunctionGemma model will be downloaded here using URL from manifest
        // let fgSpec = await fetchLatestFunctionGemmaManifest()
        // _ = await downloadModel(spec: fgSpec)

        isReady = true
    }

    private func downloadModel(spec: ModelSpec) async -> Result<Void, Error> {
        let targetDir = storageDir.appendingPathComponent(spec.targetDir)
        try? FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)

        for file in spec.files {
            // Skip SHA-256 check if not provided (manifest may not have it yet)
            let sha = file.sha256 ?? ""
            let result = await downloader.download(url: file.url, sha256: sha, to: targetDir)
            if case .failure = result { return result }
        }
        return .success(())
    }
}
