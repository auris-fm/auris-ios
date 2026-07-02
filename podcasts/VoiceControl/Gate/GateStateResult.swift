enum GateState: Equatable {
    case off(reason: GateOffReason)
    case listening(mode: ListeningMode)

    var isListening: Bool {
        if case .listening = self { return true }
        return false
    }

    var listeningMode: ListeningMode? {
        if case .listening(let mode) = self { return mode }
        return nil
    }

    var offReason: GateOffReason? {
        if case .off(let reason) = self { return reason }
        return nil
    }

    enum GateOffReason: Equatable {
        case setupNotReady
        case conflictBlocking
        case noContext
        case noMicrophone
        case onCall
        case modelsNotReady
    }
}

/// Full per-condition breakdown of the gate state for diagnostics and settings UI.
struct GatePosture: Equatable {
    let allowed: Bool
    let listeningMode: ListeningMode?
    let setup: GateSetup
    let conflicts: GateConflicts
    let context: GateContext
    let micExposure: MicExposure
    let attended: Bool
    let gracePeriodActive: Bool
    let playbackRecent: Bool
    let offReason: GateState.GateOffReason?
}
