import Foundation
import QuartzCore
import PocketCastsUtils

/// Result of classifying a user transcript.
enum ClassificationResult {
    case intent(any VoiceIntent)
    case dialogControl(DialogControlAction)
    case none
}

/// Classify-then-generate intent router backed by CPU llama.cpp + LFMC head.
final class LfmIntentRouter {
    private let modelManager: ModelManager
    private let inference: LfmInference
    private let mapper = ToolCallMapper()
    private let lock = NSRecursiveLock()
    private var loadedRelease: String?
    private var loadedQuant: String?
    private var loadedInputFormat: RouterInputFormat = .englishV1
    private var promptHistory: [DialogPromptTurn] = []

    /// Exactly-once local diagnostic sink. Must not throw; failures are isolated.
    var onMetrics: ((RouterStageDiagnostic) -> Void)?

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
        // Only wipe+redownload for parse/corruption-style load failures. Resource
        // exhaustion (OOM) must not delete good assets and force a CDN round-trip.
        if case .failure(let error) = firstAttempt,
           let routerError = error as? RouterError,
           case .loadFailed(let message) = routerError,
           looksLikeCorruptModelError(message) {
            modelManager.invalidateLfmModel()
            let redownload = await modelManager.ensureLfmModel()
            if case .failure(let redownloadError) = redownload {
                return .failure(redownloadError)
            }
            return lock.withLock { loadLocked() }
        }
        return firstAttempt
    }

    private func looksLikeCorruptModelError(_ message: String) -> Bool {
        let lower = message.lowercased()
        // Omit bare "gguf" — OOM/tensor-allocation messages often mention the GGUF
        // layer and must not trigger wipe+redownload. Header corruption already
        // surfaces via magic/invalid/mismatch/parse-style markers.
        let markers = ["magic", "corrupt", "invalid", "mismatch", "parse", "classifier", "label"]
        return markers.contains { lower.contains($0) }
    }

    private func loadLocked() -> Result<Void, Error> {
        guard modelManager.isLfmModelReady() else {
            if let format = modelManager.lfmRouterInputFormat(), !format.isReadyForInference {
                return .failure(RouterError.unsupportedInputFormat(format.wireName))
            }
            return .failure(RouterError.modelNotReady)
        }
        guard let release = modelManager.lfmReleaseVersion(),
              let format = modelManager.lfmRouterInputFormat()
        else {
            return .failure(RouterError.modelNotReady)
        }
        if loadedRelease == release, loadedInputFormat == format {
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
        loadedQuant = modelManager.lfmQuant()
        loadedInputFormat = format
        return .success(())
    }

    /// Compatibility adapter: English-only envelope with `translationKind = none`.
    func classify(transcript: String, pendingDialog: PendingVoiceDialog? = nil) -> ClassificationResult {
        classify(input: .english(transcript: transcript), pendingDialog: pendingDialog)
    }

    func classify(input: IntentRoutingInput, pendingDialog: PendingVoiceDialog? = nil) -> ClassificationResult {
        let start = CACurrentMediaTime()
        let trimmed = input.routerTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = DiagnosticBase(
            sourceLanguage: input.sourceLanguage,
            translationKind: input.translationKind.wireName
        )
        guard !trimmed.isEmpty else {
            report(
                start: start,
                base: base,
                finalOutcome: RouterStageDiagnostic.outcomeNoIntent,
                failedStage: RouterStageDiagnostic.stageBlank,
                reason: RouterStageDiagnostic.reasonBlankTranscript
            )
            return .none
        }

        let release: String?
        let inputFormat: RouterInputFormat
        lock.lock()
        release = loadedRelease
        inputFormat = loadedInputFormat
        let history = pendingDialog == nil ? [] : promptHistory
        if pendingDialog == nil {
            promptHistory = []
        }

        guard release != nil else {
            lock.unlock()
            FileLog.shared.addMessage("[VoicePipeline] LFM router not ready for: \"\(trimmed)\"")
            let cachedFormat = modelManager.lfmRouterInputFormat()
            if let cachedFormat, !cachedFormat.isReadyForInference {
                report(
                    start: start,
                    base: base,
                    modelRelease: modelManager.lfmReleaseVersion(),
                    inputFormat: cachedFormat.wireName,
                    finalOutcome: RouterStageDiagnostic.outcomeNoIntent,
                    failedStage: RouterStageDiagnostic.stageUnsupportedFormat,
                    reason: RouterStageDiagnostic.reasonUnsupportedInputFormat
                )
            } else {
                report(
                    start: start,
                    base: base,
                    modelRelease: modelManager.lfmReleaseVersion(),
                    inputFormat: cachedFormat?.wireName,
                    finalOutcome: RouterStageDiagnostic.outcomeNoIntent,
                    failedStage: RouterStageDiagnostic.stageNotReady,
                    reason: RouterStageDiagnostic.reasonModelNotLoaded
                )
            }
            return .none
        }

        // Hold the lock across tokenize→classify→generate so KV-cache continuity
        // cannot be poisoned by a concurrent ensureReady/classify caller.
        defer {
            inference.reset()
            lock.unlock()
        }

        // english_v1 only — prompt/token span/slot repair use routerTranscript.
        precondition(inputFormat.isReadyForInference, "unsupported format must fail before load")

        do {
            let prompt = LfmPrompt.render(transcript: trimmed, history: history)
            let promptTokenIds: [Int]
            let userTokenIds: [Int]
            do {
                promptTokenIds = try inference.tokenize(prompt, addBos: false)
                userTokenIds = try inference.tokenize(trimmed, addBos: false)
            } catch {
                FileLog.shared.addMessage("[VoicePipeline] LFM tokenize failed")
                report(
                    start: start,
                    base: base,
                    modelRelease: release,
                    inputFormat: inputFormat.wireName,
                    finalOutcome: RouterStageDiagnostic.outcomeNoIntent,
                    failedStage: RouterStageDiagnostic.stageTokenize,
                    reason: RouterStageDiagnostic.reasonTokenizeFailed
                )
                return .none
            }

            let span: (start: Int, end: Int)
            do {
                span = try LfmTokenSpan.lastUserTokenSpan(
                    promptTokenIds: promptTokenIds,
                    userTokenIds: userTokenIds
                )
            } catch {
                FileLog.shared.addMessage("[VoicePipeline] LFM span failed")
                report(
                    start: start,
                    base: base,
                    modelRelease: release,
                    inputFormat: inputFormat.wireName,
                    finalOutcome: RouterStageDiagnostic.outcomeNoIntent,
                    failedStage: RouterStageDiagnostic.stageTokenize,
                    reason: RouterStageDiagnostic.reasonTokenizeFailed
                )
                return .none
            }

            let label: String
            do {
                label = try inference.classify(
                    promptTokenIds: promptTokenIds,
                    poolStart: span.start,
                    poolEnd: span.end
                )
            } catch {
                FileLog.shared.addMessage("[VoicePipeline] LFM classify failed")
                report(
                    start: start,
                    base: base,
                    modelRelease: release,
                    inputFormat: inputFormat.wireName,
                    finalOutcome: RouterStageDiagnostic.outcomeNoIntent,
                    failedStage: RouterStageDiagnostic.stageClassify,
                    reason: RouterStageDiagnostic.reasonClassifyFailed
                )
                return .none
            }

            let (tool, action): (String, String)
            do {
                (tool, action) = try LfmLabel.parse(label)
            } catch {
                FileLog.shared.addMessage("[VoicePipeline] LFM label parse failed")
                report(
                    start: start,
                    base: base,
                    modelRelease: release,
                    inputFormat: inputFormat.wireName,
                    classifierLabel: label,
                    finalOutcome: RouterStageDiagnostic.outcomeNoIntent,
                    failedStage: RouterStageDiagnostic.stageClassify,
                    reason: RouterStageDiagnostic.reasonClassifyFailed
                )
                return .none
            }

            if tool == "no_match" {
                report(
                    start: start,
                    base: base,
                    modelRelease: release,
                    inputFormat: inputFormat.wireName,
                    classifierLabel: label,
                    finalOutcome: RouterStageDiagnostic.outcomeNoIntent,
                    failedStage: RouterStageDiagnostic.stageNoMatch,
                    reason: RouterStageDiagnostic.reasonNoMatch
                )
                return .none
            }

            let prefill = LfmCallPrefill.render(tool: tool, action: action)
            let generated: String
            do {
                generated = try inference.generate(prefill: prefill, nPredict: 64)
            } catch {
                FileLog.shared.addMessage("[VoicePipeline] LFM generate failed")
                report(
                    start: start,
                    base: base,
                    modelRelease: release,
                    inputFormat: inputFormat.wireName,
                    classifierLabel: label,
                    finalOutcome: RouterStageDiagnostic.outcomeNoIntent,
                    failedStage: RouterStageDiagnostic.stageGenerate,
                    reason: RouterStageDiagnostic.reasonGenerateFailed
                )
                return .none
            }

            guard let repaired = SlotRepair.repair(
                raw: generated,
                utterance: trimmed,
                tool: tool,
                action: action
            ) else {
                report(
                    start: start,
                    base: base,
                    modelRelease: release,
                    inputFormat: inputFormat.wireName,
                    classifierLabel: label,
                    finalOutcome: RouterStageDiagnostic.outcomeNoIntent,
                    failedStage: RouterStageDiagnostic.stageParseRepair,
                    reason: RouterStageDiagnostic.reasonParseOrRepairFailed
                )
                return .none
            }

            recordHistoryIfNeeded(
                pendingDialog: pendingDialog,
                toolName: repaired.name,
                arguments: repaired.arguments,
                transcript: trimmed,
                generated: generated
            )

            FileLog.shared.addMessage("[VoicePipeline] Classified: \(repaired.name)(\(repaired.arguments))")

            if repaired.name == "dialog_control" {
                if let dialogAction = mapDialogControl(repaired.arguments) {
                    report(
                        start: start,
                        base: base,
                        modelRelease: release,
                        inputFormat: inputFormat.wireName,
                        classifierLabel: label,
                        finalOutcome: RouterStageDiagnostic.outcomeDialogControl
                    )
                    return .dialogControl(dialogAction)
                }
                report(
                    start: start,
                    base: base,
                    modelRelease: release,
                    inputFormat: inputFormat.wireName,
                    classifierLabel: label,
                    finalOutcome: RouterStageDiagnostic.outcomeNoIntent,
                    failedStage: RouterStageDiagnostic.stageMapperDialog,
                    reason: RouterStageDiagnostic.reasonMapperOrDialogFailed
                )
                return .none
            }

            if let intent = mapper.map(repaired) {
                report(
                    start: start,
                    base: base,
                    modelRelease: release,
                    inputFormat: inputFormat.wireName,
                    classifierLabel: label,
                    finalOutcome: RouterStageDiagnostic.outcomeIntent
                )
                return .intent(intent)
            }
            report(
                start: start,
                base: base,
                modelRelease: release,
                inputFormat: inputFormat.wireName,
                classifierLabel: label,
                finalOutcome: RouterStageDiagnostic.outcomeNoIntent,
                failedStage: RouterStageDiagnostic.stageMapperDialog,
                reason: RouterStageDiagnostic.reasonMapperOrDialogFailed
            )
            return .none
        } catch {
            FileLog.shared.addMessage("[VoicePipeline] LFM inference failed")
            report(
                start: start,
                base: base,
                modelRelease: release,
                inputFormat: inputFormat.wireName,
                finalOutcome: RouterStageDiagnostic.outcomeNoIntent,
                failedStage: RouterStageDiagnostic.stageException,
                reason: RouterStageDiagnostic.reasonInferenceException
            )
            return .none
        }
    }

    func release() {
        lock.lock()
        loadedRelease = nil
        loadedQuant = nil
        loadedInputFormat = .englishV1
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

    private struct DiagnosticBase {
        let sourceLanguage: String?
        let translationKind: String
    }

    private func report(
        start: CFTimeInterval,
        base: DiagnosticBase,
        modelRelease: String? = nil,
        quant: String? = nil,
        inputFormat: String? = nil,
        classifierLabel: String? = nil,
        finalOutcome: String,
        failedStage: String? = nil,
        reason: String? = nil
    ) {
        let totalMs = (CACurrentMediaTime() - start) * 1000
        let (release, cachedQuant, format): (String?, String?, String?) = lock.withLock {
            (
                modelRelease ?? loadedRelease,
                quant ?? loadedQuant ?? modelManager.lfmQuant(),
                inputFormat ?? loadedInputFormat.wireName
            )
        }
        let diagnostic = RouterStageDiagnostic(
            modelRelease: release,
            quant: cachedQuant,
            inputFormat: format,
            sourceLanguage: base.sourceLanguage,
            translationKind: base.translationKind,
            classifierLabel: classifierLabel,
            finalOutcome: finalOutcome,
            failedStage: failedStage,
            reason: reason,
            totalLatencyMs: totalMs
        )
        // Emit before any reset side-effects; sink is non-throwing so classify always
        // observes exactly one diagnostic per exit.
        onMetrics?(diagnostic)
        FileLog.shared.addMessage(
            "[LfmRouter] stage=\(failedStage ?? "ok") outcome=\(finalOutcome) reason=\(reason ?? "-") label=\(classifierLabel ?? "-") format=\(format ?? "-") lang=\(base.sourceLanguage ?? "-") kind=\(base.translationKind) release=\(release ?? "-") quant=\(cachedQuant ?? "-") \(Int(totalMs))ms"
        )
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
        case unsupportedInputFormat(String)

        var errorDescription: String? {
            switch self {
            case .modelNotReady: return "LFM model is unavailable"
            case .loadFailed(let message): return message
            case .unsupportedInputFormat(let format): return "Unsupported router_input_format: \(format)"
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
