struct GateSetup: Equatable {
    let enabledByUser: GateCondition
    let deviceSupported: GateCondition
    let modelsReady: GateCondition

    var isReady: Bool {
        enabledByUser.isAllowed && deviceSupported.isAllowed && modelsReady.isAllowed
    }

    static let allAllowed = GateSetup(
        enabledByUser: .allowed,
        deviceSupported: .allowed,
        modelsReady: .allowed
    )
}

struct GateConflicts: Equatable {
    let notOnCall: GateCondition
    let notCasting: GateCondition
    let batteryOk: GateCondition
    let otherAppPlaying: GateCondition

    var isClear: Bool {
        notOnCall.isAllowed && notCasting.isAllowed && batteryOk.isAllowed && otherAppPlaying.isAllowed
    }

    static let noneBlocked = GateConflicts(
        notOnCall: .allowed,
        notCasting: .allowed,
        batteryOk: .allowed,
        otherAppPlaying: .allowed
    )
}

enum GateContext: Equatable {
    case none
    case playbackActive
    case appInForeground
    case both
}
