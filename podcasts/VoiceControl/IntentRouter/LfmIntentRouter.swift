import Foundation
import QuartzCore
import PocketCastsUtils

/// Result of classifying a user transcript.
enum ClassificationResult {
    case intent(any VoiceIntent)
    case dialogControl(DialogControlAction)
    case none
}

/// Engagement/latency observation for one classification request.
/// `outcome` is one of: `intent`, `dialog_control`, `no_match`, `parse_failure`,
/// `router_not_ready`.
struct RouterClassificationMetrics {
    let totalMs: Double
    let outcome: String
    let modelRelease: String?
}

/// Classify-then-generate intent router backed by CPU llama.cpp + LFMC head.
final class LfmIntentRouter {
    private let modelManager: ModelManager
    private let inference: LfmInference
    private let mapper = ToolCallMapper()
    private let lock = NSRecursiveLock()
    private var loadedRelease: String?
    private var promptHistory: [DialogPromptTurn] = []

    var onMetrics: ((RouterClassificationMetrics) -> Void)?

    var isReady: Bool {
        lock.lock()
        defer { lock.unlock() }
        return loadedRelease != nil
    }

    init(modelManager: ModelManager = ModelManager(), inference: LfmInference = LfmNativeInference()) {
        self.modelManager = modelManager
        self.inference = inference
    }

    func ensureReady() async -> Result<Void, Error> {
        let download = await modelManager.ensureLfmModel()
        if case .failure(let error) = download {
            return .failure(error)
        }
        let firstAttempt = lock.withLock { loadLocked() }
        if case .success = firstAttempt {
            return firstAttempt
        }
        // Size-ok but corrupt assets (especially GGUF) fail native load. Wipe so the
        // next ensureReady/ensureLfmModel re-downloads, and retry once here.
        if case .failure(let error) = firstAttempt,
           let routerError = error as? RouterError,
           case .loadFailed(let message) = routerError {
            modelManager.invalidateLfmModel()
            let redownload = await modelManager.ensureLfmModel()
            if case .failure = redownload {
                // Prefer the original native load error when re-download also fails
                // (offline / test without network).
                return .failure(RouterError.loadFailed(message))
            }
            return lock.withLock { loadLocked() }
        }
        return firstAttempt
    }

    private func loadLocked() -> Result<Void, Error> {
        guard modelManager.isLfmModelReady() else {
            return .failure(RouterError.modelNotReady)
        }
        guard let release = modelManager.lfmReleaseVersion() else {
            return .failure(RouterError.modelNotReady)
        }
        if loadedRelease == release {
            return .success(())
        }
        inference.release()
        let loaded = inference.load(
            modelPath: modelManager.lfmModelFile.path,
            classifierPath: modelManager.lfmClassifierFile.path,
            labelMapPath: modelManager.lfmLabelMapFile.path,
            nCtx: 2048
        )
        guard loaded else {
            let message = inference.lastError.isEmpty ? "LFM native load failed" : inference.lastError
            return .failure(RouterError.loadFailed(message))
        }
        loadedRelease = release
        return .success(())
    }

    func classify(transcript: String, pendingDialog: PendingVoiceDialog? = nil) -> ClassificationResult {
        let start = CACurrentMediaTime()
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            reportMetrics(start: start, outcome: "no_match")
            return .none
        }

        let release: String?
        lock.lock()
        release = loadedRelease
        let history = pendingDialog == nil ? [] : promptHistory
        if pendingDialog == nil {
            promptHistory = []
        }

        guard release != nil else {
            lock.unlock()
            FileLog.shared.addMessage("[VoiceControl/Intent] LFM router not ready for: \"\(trimmed)\"")
            reportMetrics(start: start, outcome: "router_not_ready")
            return .none
        }

        // Hold the lock across tokenize→classify→generate so KV-cache continuity
        // cannot be poisoned by a concurrent ensureReady/classify caller.
        defer {
            inference.reset()
            lock.unlock()
        }

        do {
            let prompt = LfmPrompt.render(transcript: trimmed, history: history)
            let promptTokenIds = try inference.tokenize(prompt, addBos: false)
            let userTokenIds = try inference.tokenize(trimmed, addBos: false)
            let span = try LfmTokenSpan.lastUserTokenSpan(
                promptTokenIds: promptTokenIds,
                userTokenIds: userTokenIds
            )
            let label = try inference.classify(
                promptTokenIds: promptTokenIds,
                poolStart: span.start,
                poolEnd: span.end
            )
            let (tool, action) = try LfmLabel.parse(label)
            if tool == "no_match" {
                reportMetrics(start: start, outcome: "no_match")
                return .none
            }

            let prefill = LfmCallPrefill.render(tool: tool, action: action)
            let generated = try inference.generate(prefill: prefill, nPredict: 64)
            guard let repaired = SlotRepair.repair(
                raw: generated,
                utterance: trimmed,
                tool: tool,
                action: action
            ) else {
                reportMetrics(start: start, outcome: "parse_failure")
                return .none
            }

            recordHistoryIfNeeded(
                pendingDialog: pendingDialog,
                toolName: repaired.name,
                arguments: repaired.arguments,
                transcript: trimmed,
                generated: generated
            )

            FileLog.shared.addMessage("[VoiceControl/Intent] Classified: \(repaired.name)(\(repaired.arguments))")

            if repaired.name == "dialog_control" {
                if let dialogAction = mapDialogControl(repaired.arguments) {
                    reportMetrics(start: start, outcome: "dialog_control")
                    return .dialogControl(dialogAction)
                }
                reportMetrics(start: start, outcome: "parse_failure")
                return .none
            }

            if let intent = mapper.map(repaired) {
                reportMetrics(start: start, outcome: "intent")
                return .intent(intent)
            }
            reportMetrics(start: start, outcome: "parse_failure")
            return .none
        } catch {
            FileLog.shared.addMessage("[VoiceControl/Intent] LFM inference failed: \(error)")
            reportMetrics(start: start, outcome: "parse_failure")
            return .none
        }
    }

    func release() {
        lock.lock()
        loadedRelease = nil
        promptHistory = []
        lock.unlock()
        inference.release()
    }

    private func recordHistoryIfNeeded(
        pendingDialog: PendingVoiceDialog?,
        toolName: String,
        arguments: [String: Any],
        transcript: String,
        generated: String
    ) {
        let shouldRecord = pendingDialog != nil || toolName == "dialog_control"
        guard shouldRecord else {
            lock.lock()
            promptHistory = []
            lock.unlock()
            return
        }
        lock.lock()
        defer { lock.unlock() }
        if toolName == "dialog_control",
           pendingDialog != nil,
           (arguments["action"] as? String) == "begin" {
            promptHistory = []
        }
        promptHistory.append(DialogPromptTurn(role: "user", content: transcript))
        promptHistory.append(DialogPromptTurn(role: "assistant", content: generated))
        if promptHistory.count > 4 {
            promptHistory = Array(promptHistory.suffix(4))
        }
    }

    private func reportMetrics(start: CFTimeInterval, outcome: String) {
        let totalMs = (CACurrentMediaTime() - start) * 1000
        let release = lock.withLock { loadedRelease }
        onMetrics?(RouterClassificationMetrics(totalMs: totalMs, outcome: outcome, modelRelease: release))
    }

    private func mapDialogControl(_ args: [String: Any]) -> DialogControlAction? {
        guard let action = args["action"] as? String else { return nil }
        switch action {
        case "begin":
            guard let tool = args["target_tool"] as? String,
                  let actionName = args["target_action"] as? String else { return nil }
            return .begin(targetTool: tool, targetAction: actionName)
        case "provide_slot":
            guard let tool = args["target_tool"] as? String,
                  let actionName = args["target_action"] as? String,
                  let slot = args["slot"] as? String,
                  let value = args["value"] as? String else { return nil }
            return .provideSlot(targetTool: tool, targetAction: actionName, slot: slot, value: value)
        case "confirm": return .confirm
        case "deny": return .deny
        case "cancel": return .cancel
        case "new_command":
            guard let value = args["value"] as? String else { return nil }
            return .newCommand(value: value)
        default: return nil
        }
    }

    enum RouterError: Error, LocalizedError {
        case modelNotReady
        case loadFailed(String)

        var errorDescription: String? {
            switch self {
            case .modelNotReady: return "LFM model is unavailable"
            case .loadFailed(let message): return message
            }
        }
    }
}

private extension NSRecursiveLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
