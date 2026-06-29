enum GateState: Equatable {
    case off(reason: GateOffReason)
    case listening(mode: ListeningMode)

    enum GateOffReason: Equatable {
        case setupNotReady
        case conflictBlocking
        case noContext
        case noMicrophone
        case onCall
        case modelsNotReady
    }
}
