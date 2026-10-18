import Foundation

/// The client → server `app_operation_result` frame, as fixed by the owning wire contract
/// (core-app-tools `app-operation-wire-contract.md`, rev da327e624, section 1).
///
/// Field rules the encoder enforces by construction: `operation_id` and `outcome` are always
/// present; `reason` is present on every non-success outcome and absent on `succeeded` (a
/// success with a reason is a client bug the contract names); `state` rides only `succeeded`.
struct AppOperationResultFrame: Equatable {
    let operationId: String
    let outcome: OperationOutcome
    /// Machine-readable refusal/failure reason. Nil exactly when `outcome == .succeeded`.
    let reason: String?
    /// The actual resulting state on success (typed per the owning sink), if reported.
    let state: [String: CloudRouteJSONValue]?
    /// Bounded prose for humans. Never the gate.
    let detail: String?

    init(
        operationId: String,
        outcome: OperationOutcome,
        reason: String? = nil,
        state: [String: CloudRouteJSONValue]? = nil,
        detail: String? = nil
    ) {
        precondition(
            (outcome == .succeeded) == (reason == nil),
            "a success carries no reason; every non-success carries one"
        )
        self.operationId = operationId
        self.outcome = outcome
        self.reason = reason
        self.state = state
        self.detail = detail
    }

    /// The wire shape. Failure here is a programming error (non-string values), so it traps via
    /// the force-unwrap of the encoding guard's alternative — JSONSerialization on dictionary
    /// literals of strings/numbers cannot fail.
    func jsonFrame() -> [String: Any] {
        var frame: [String: Any] = [
            "type": "app_operation_result",
            "operation_id": operationId,
            "outcome": outcome.rawValue,
        ]
        if let reason { frame["reason"] = reason }
        if let state { frame["state"] = state.mapValues { $0.toJSONSerializable() } }
        if let detail { frame["detail"] = detail }
        return frame
    }
}
