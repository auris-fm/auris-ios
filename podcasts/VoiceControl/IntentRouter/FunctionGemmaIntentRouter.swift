import PocketCastsUtils

class FunctionGemmaIntentRouter {
    private var sessionPool = FunctionGemmaSessionPool()
    private let mapper = ToolCallMapper()
    private let promptBuilder = PromptBuilder()

    func ensureReady() async -> Result<Void, Error> {
        await sessionPool.prepare()
        if sessionPool.acquire() != nil {
            return .success(())
        }
        return .failure(RouterError.modelNotReady)
    }

    func classify(transcript: String, pendingDialog: PendingVoiceDialog? = nil) -> (any VoiceIntent)? {
        guard let session = sessionPool.acquire() else {
            FileLog.shared.addMessage("[VoiceControl/Intent] No session available for: \"\(transcript)\"")
            return nil
        }
        defer { sessionPool.scheduleReplacement() }

        let userTurn = promptBuilder.buildUserTurn(transcript: transcript)
        guard let output = try? session.generate(userTurn) else {
            FileLog.shared.addMessage("[VoiceControl/Intent] Generation failed for: \"\(transcript)\"")
            return nil
        }
        guard let toolCall = FunctionGemmaParser.parse(output) else {
            FileLog.shared.addMessage("[VoiceControl/Intent] Parse failed — raw output: \(output.prefix(200))")
            return nil
        }
        FileLog.shared.addMessage("[VoiceControl/Intent] Classified: \(toolCall.name)(\(toolCall.arguments))")
        return mapper.map(toolCall)
    }

    enum RouterError: Error {
        case modelNotReady
    }
}
