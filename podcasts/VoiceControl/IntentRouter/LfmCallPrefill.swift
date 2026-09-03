import Foundation

enum LfmCallPrefill {
    private static let toolCallStart = "<|tool_call_start|>"
    private static let toolCallEnd = "<|tool_call_end|>"

    /// Emits the open tool-call span without the closing `)]<|tool_call_end|>`.
    static func render(tool: String, action: String) -> String {
        let escapedAction = action.replacingOccurrences(of: "'", with: "\\'")
        let inner = "\(tool)(action='\(escapedAction)')"
        let full = "\(toolCallStart)[\(inner))]\(toolCallEnd)"
        let suffix = ")]\(toolCallEnd)"
        precondition(full.hasSuffix(suffix), "unexpected tool-call suffix")
        return String(full.dropLast(suffix.count))
    }
}

enum LfmLabel {
    static func parse(_ label: String) throws -> (tool: String, action: String) {
        guard let separator = label.firstIndex(of: ":") else {
            throw LfmInferenceError.invalidLabel(label)
        }
        let tool = String(label[..<separator])
        let action = String(label[label.index(after: separator)...])
        return (tool, action)
    }
}

enum LfmTokenSpan {
    static func lastUserTokenSpan(promptTokenIds: [Int], userTokenIds: [Int]) throws -> (start: Int, end: Int) {
        guard !promptTokenIds.isEmpty else { throw LfmInferenceError.emptyPrompt }
        guard !userTokenIds.isEmpty else { throw LfmInferenceError.emptyUserTokens }
        var start = -1
        let userCount = userTokenIds.count
        if promptTokenIds.count >= userCount {
            for index in 0...(promptTokenIds.count - userCount) {
                if Array(promptTokenIds[index..<(index + userCount)]) == userTokenIds {
                    start = index
                }
            }
        }
        if start >= 0 {
            return (start, start + userCount - 1)
        }
        // BPE can merge across the user/transcript boundary. Prefer a trailing
        // window sized to the utterance so dialog history does not dominate.
        let window = max(userCount, 32)
        let fallbackStart = max(0, promptTokenIds.count - window)
        return (fallbackStart, promptTokenIds.count - 1)
    }
}

enum LfmInferenceError: Error, LocalizedError {
    case invalidLabel(String)
    case emptyPrompt
    case emptyUserTokens
    case userSpanNotFound
    case notReady
    case loadFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidLabel(let label): return "invalid label \(label)"
        case .emptyPrompt: return "prompt must not be empty"
        case .emptyUserTokens: return "user utterance must not be empty"
        case .userSpanNotFound: return "user utterance tokens not found in prompt"
        case .notReady: return "LFM runtime is not ready"
        case .loadFailed(let message): return message
        }
    }
}
