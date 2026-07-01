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
        guard let session = sessionPool.acquire() else { return nil }
        defer { sessionPool.scheduleReplacement() }

        let userTurn = promptBuilder.buildUserTurn(transcript: transcript)
        guard let output = try? session.generate(userTurn) else { return nil }
        guard let toolCall = FunctionGemmaParser.parse(output) else { return nil }
        return mapper.map(toolCall)
    }

    enum RouterError: Error {
        case modelNotReady
    }
}
