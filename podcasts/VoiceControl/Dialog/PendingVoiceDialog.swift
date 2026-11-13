struct PendingVoiceDialog {
    let targetTool: String
    let targetAction: String
    var filledSlots: [String: String] = [:]
    let requiredSlots: Set<String>
}

enum DialogControlAction {
    case begin(targetTool: String, targetAction: String)
    case provideSlot(targetTool: String, targetAction: String, slot: String, value: String)
    case confirm
    case deny
    case cancel
    case newCommand(value: String)
}
