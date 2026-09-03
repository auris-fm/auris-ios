import Foundation

/// Parses LFM Pythonic tool-call spans into `ToolCall` values.
enum LfmToolCallParser {
    private static let toolCallStart = "<|tool_call_start|>"
    private static let toolCallEnd = "<|tool_call_end|>"

    static func parse(_ response: String) -> ToolCall? {
        guard let callText = extractLastCallText(response) else { return nil }
        return parsePythonicCall(callText)
    }

    private static func extractLastCallText(_ response: String) -> String? {
        var searchFrom = response.startIndex
        var lastCall: String?
        while true {
            guard let startRange = response.range(of: toolCallStart, range: searchFrom..<response.endIndex) else {
                break
            }
            guard let openBracket = response[startRange.upperBound...].firstIndex(of: "[") else { break }
            let afterOpen = response.index(after: openBracket)
            guard let closeBracket = response[afterOpen...].firstIndex(of: "]") else { break }
            guard let endRange = response.range(of: toolCallEnd, range: closeBracket..<response.endIndex) else {
                break
            }
            lastCall = String(response[afterOpen..<closeBracket])
            searchFrom = endRange.upperBound
        }
        return lastCall
    }

    private static func parsePythonicCall(_ callText: String) -> ToolCall? {
        let trimmed = callText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let openParen = trimmed.firstIndex(of: "("), trimmed.hasSuffix(")") else { return nil }

        let toolName = String(trimmed[..<openParen]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !toolName.isEmpty else { return nil }
        if toolName == "no_match" {
            return ToolCall(name: "no_match", arguments: [:])
        }

        let closeParen = trimmed.index(before: trimmed.endIndex)
        let argsText = String(trimmed[trimmed.index(after: openParen)..<closeParen])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if argsText.isEmpty {
            return ToolCall(name: toolName, arguments: [:])
        }

        var arguments: [String: Any] = [:]
        var pos = argsText.startIndex
        while pos < argsText.endIndex {
            while pos < argsText.endIndex, argsText[pos].isWhitespace {
                pos = argsText.index(after: pos)
            }
            if pos >= argsText.endIndex { break }

            guard let keyEnd = argsText[pos...].firstIndex(of: "=") else { return nil }
            let key = String(argsText[pos..<keyEnd]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { return nil }
            pos = argsText.index(after: keyEnd)
            while pos < argsText.endIndex, argsText[pos].isWhitespace {
                pos = argsText.index(after: pos)
            }
            guard pos < argsText.endIndex else { return nil }

            guard let parsed = parseValue(argsText, start: pos) else { return nil }
            arguments[key] = parsed.value as Any
            pos = parsed.nextIndex
            while pos < argsText.endIndex, argsText[pos].isWhitespace || argsText[pos] == "," {
                pos = argsText.index(after: pos)
            }
        }

        return ToolCall(name: toolName, arguments: arguments)
    }

    private struct ParsedValue {
        let value: Any?
        let nextIndex: String.Index
    }

    private static func parseValue(_ text: String, start: String.Index) -> ParsedValue? {
        guard start < text.endIndex else { return nil }
        if text[start] == "'" {
            return parseQuotedString(text, start: start)
        }
        return parseBareValue(text, start: start)
    }

    private static func parseQuotedString(_ text: String, start: String.Index) -> ParsedValue? {
        guard text[start] == "'" else { return nil }
        var builder = ""
        var index = text.index(after: start)
        while index < text.endIndex {
            let char = text[index]
            switch char {
            case "\\":
                index = text.index(after: index)
                guard index < text.endIndex else { return nil }
                builder.append(text[index])
            case "'":
                return ParsedValue(value: builder, nextIndex: text.index(after: index))
            default:
                builder.append(char)
            }
            index = text.index(after: index)
        }
        return nil
    }

    private static func parseBareValue(_ text: String, start: String.Index) -> ParsedValue? {
        let end = text[start...].firstIndex(of: ",") ?? text.endIndex
        let raw = String(text[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        let value: Any?
        switch raw {
        case "True", "true":
            value = true
        case "False", "false":
            value = false
        case "None", "null":
            value = nil
        default:
            if let int = Int(raw) {
                value = int
            } else if let double = Double(raw) {
                value = double
            } else {
                value = raw
            }
        }
        return ParsedValue(value: value, nextIndex: end)
    }
}
