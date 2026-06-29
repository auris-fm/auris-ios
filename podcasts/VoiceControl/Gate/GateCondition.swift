enum GateCondition: Equatable {
    case allowed
    case blocked(reason: String)
    case unknown(reason: String)

    var isAllowed: Bool {
        if case .allowed = self { return true }
        return false
    }
}
