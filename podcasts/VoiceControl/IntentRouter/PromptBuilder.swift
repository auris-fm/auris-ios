class PromptBuilder {
    private let developerMessage = "You are a model that can do function calling with the following functions"

    func buildSystemPrompt(tools: [[String: Any]]) -> String {
        let toolDeclarations = tools.map { formatToolDeclaration($0) }.joined()
        return "<bos><start_of_turn>developer\n\(developerMessage)\n\(toolDeclarations)<end_of_turn>"
    }

    func buildUserTurn(transcript: String) -> String {
        "<start_of_turn>user\n\(transcript)<end_of_turn>\n<start_of_turn>model\n"
    }

    private func formatToolDeclaration(_ tool: [String: Any]) -> String {
        guard let name = tool["name"] as? String else { return "" }
        return "<start_function_declaration>declaration:\(name){\(formatParameters(tool))}<end_function_declaration>"
    }

    private func formatParameters(_ tool: [String: Any]) -> String {
        guard let params = tool["parameters"] as? [String: Any] else { return "" }
        return params.map { "\($0.key):\($0.value)" }.joined(separator: ",")
    }
}
