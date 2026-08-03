import Foundation

/// One bounded prior turn rendered inside the request suffix for pending dialogs.
struct DialogPromptTurn: Equatable {
    let role: String
    let content: String
}

/// Renders the FunctionGemma prompt contract from the recognition-pipeline spec.
///
/// The canonical sequence is:
/// `<bos><start_of_turn>developer\n<message>\n<declarations><end_of_turn>\n`
/// followed by the request suffix
/// `\n<start_of_turn>user\n<transcript><end_of_turn>\n<start_of_turn>model\n`.
/// Tool declarations use the FunctionGemma declaration format with `<escape>`
/// wrapped descriptions, enum values, types, a `required` list, and a `return`
/// spec — do not hand-roll a structurally different prompt, because the model is
/// trained on these exact bytes (see recognition-pipeline.md "FunctionGemma
/// Prompt Contract").
enum PromptBuilder {
    static let developerMessage = "You are a model that can do function calling with the following functions"

    static func buildSystemPrompt(tools: [[String: Any]]) -> String {
        var prompt = "<bos><start_of_turn>developer\n"
        prompt += developerMessage
        prompt += "\n"
        prompt += tools.map(formatToolDeclaration).joined()
        prompt += "<end_of_turn>\n"
        return prompt
    }

    static func buildUserTurn(transcript: String, history: [DialogPromptTurn] = []) -> String {
        var prompt = ""
        for turn in history {
            prompt += "\n<start_of_turn>\(turn.role)\n\(turn.content)<end_of_turn>"
        }
        prompt += "\n<start_of_turn>user\n\(transcript)<end_of_turn>\n<start_of_turn>model\n"
        return prompt
    }

    static func escape(_ value: String) -> String {
        "<escape>\(value)</escape>"
    }

    static func formatToolDeclaration(_ tool: [String: Any]) -> String {
        guard let name = tool["name"] as? String else { return "" }
        let description = escape(tool["description"] as? String ?? "")
        let parameters = tool["parameters"] as? [[String: Any]] ?? []
        let properties = parameters.map(formatParameter).joined(separator: ",")
        let required = (tool["required"] as? [String] ?? ["action"]).map(escape).joined(separator: ",")
        let returnSpec = formatReturn(tool["return"] as? [String: Any])
        return "<start_function_declaration>declaration:\(name){description:\(description),parameters:{properties:{\(properties)},required:[\(required)],type:<escape>OBJECT<escape>},return:\(returnSpec)}<end_function_declaration>"
    }

    private static func formatParameter(_ parameter: [String: Any]) -> String {
        guard let name = parameter["name"] as? String else { return "" }
        let description = escape(parameter["description"] as? String ?? "")
        var declaration = "\(name):{description:\(description)"
        if let enumValues = parameter["enum"] as? [String] {
            let escaped = enumValues.map(escape).joined(separator: ",")
            declaration += ",enum:[\(escaped)]"
        }
        let type = uppercaseType(parameter["type"] as? String ?? "string")
        declaration += ",type:\(escape(type))}"
        return declaration
    }

    private static func uppercaseType(_ type: String) -> String {
        switch type.lowercased() {
        case "string": return "STRING"
        case "integer": return "INTEGER"
        case "number": return "NUMBER"
        case "boolean": return "BOOLEAN"
        case "object": return "OBJECT"
        case "array": return "ARRAY"
        default: return type.uppercased()
        }
    }

    private static func formatReturn(_ returnSpec: [String: Any]?) -> String {
        let type = uppercaseType(returnSpec?["type"] as? String ?? "OBJECT")
        return "{type:\(escape(type))}"
    }
}
