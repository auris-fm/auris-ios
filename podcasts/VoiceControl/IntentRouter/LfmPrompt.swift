import Foundation

/// One bounded prior turn rendered inside the LFM ChatML prompt for pending dialogs.
struct DialogPromptTurn: Equatable {
    let role: String
    let content: String
}

/// Renders the LFM classify-then-generate ChatML prompt contract.
enum LfmPrompt {
    static let system = "You map podcast voice commands to a tool call."

    private static let startOfText = "<|startoftext|>"
    private static let imStart = "<|im_start|>"
    private static let imEnd = "<|im_end|>"
    private static let maxHistoryTurns = 4

    static func render(transcript: String, history: [DialogPromptTurn] = []) -> String {
        var prompt = ""
        prompt += startOfText
        prompt += imStart
        prompt += "system\n"
        prompt += system
        prompt += imEnd
        prompt += "\n"
        for turn in history.suffix(maxHistoryTurns) {
            prompt += imStart
            prompt += turn.role
            prompt += "\n"
            prompt += turn.content
            prompt += imEnd
            prompt += "\n"
        }
        prompt += imStart
        prompt += "user\n"
        prompt += transcript
        prompt += imEnd
        prompt += "\n"
        prompt += imStart
        prompt += "assistant\n"
        return prompt
    }
}
