import Foundation

struct ToolCall {
    let name: String
    let arguments: [String: Any]
}

struct FunctionGemmaParser {
    private static let pattern = #/<start_function_call>call:(\w+)\{(.*?)\}<end_function_call>/#

    static func parse(_ output: String) -> ToolCall? {
        guard let match = output.firstMatch(of: pattern) else { return nil }
        let name = String(match.1)
        let argsString = String(match.2)
        let arguments = parseArguments(argsString)
        return ToolCall(name: name, arguments: arguments)
    }

    private static func parseArguments(_ raw: String) -> [String: Any] {
        var args: [String: Any] = [:]
        let pairs = raw.split(separator: ",")
        for pair in pairs {
            let kv = pair.split(separator: ":", maxSplits: 1)
            guard kv.count == 2 else { continue }
            let key = String(kv[0]).trimmingCharacters(in: .whitespaces)
            let rawValue = String(kv[1]).trimmingCharacters(in: .whitespaces)
            args[key] = unwrapValue(rawValue)
        }
        return args
    }

    private static func unwrapValue(_ raw: String) -> Any {
        if raw.hasPrefix("<escape>") && raw.hasSuffix("</escape>") {
            let start = raw.index(raw.startIndex, offsetBy: 8)
            let end = raw.index(raw.endIndex, offsetBy: -9)
            return String(raw[start..<end])
        }
        if let int = Int(raw) { return int }
        if let double = Double(raw) { return double }
        if raw == "true" { return true }
        if raw == "false" { return false }
        return raw
    }
}
