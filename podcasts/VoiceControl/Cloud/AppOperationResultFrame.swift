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

    /// Typed refusal of an invalid external result shape — NEVER a crash: reason values and
    /// outcomes can arrive from caller code assembling results from untrusted action frames, and
    /// a precondition there would take the app down over a shape the contract merely refuses.
    /// Nil = invalid: a success carrying a reason, or a non-success without one.
    init?(
        operationId: String,
        outcome: OperationOutcome,
        reason: String? = nil,
        state: [String: CloudRouteJSONValue]? = nil,
        detail: String? = nil
    ) {
        // Owning-frame contract, enforced on every external shape:
        // - operation_id is always present and NON-EMPTY (an empty id names nothing);
        // - reason is non-empty on every non-success and absent on success;
        // - state rides SUCCESS ONLY (a non-success has no resulting state to report);
        // - detail is bounded prose (512 chars), never the gate.
        guard !operationId.isEmpty else { return nil }
        guard (outcome == .succeeded) == (reason == nil) else { return nil }
        if let reason, reason.isEmpty { return nil }
        if outcome != .succeeded && state != nil { return nil }
        if let detail, detail.count > 512 { return nil }
        self.operationId = operationId
        self.outcome = outcome
        self.reason = reason
        self.state = state
        self.detail = detail
    }

    /// The wire shape. Values come from typed builders, so encoding cannot fail here.
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

/// The turn-bound handle a result send must travel by. Created with the turn (before the socket
/// opens); the client binds the registration identity at socket registration, and a send is only
/// delivered while THAT registration is still the live one for the request id — a late result
/// from a retired turn is `undelivered`, never routed onto a successor's socket.
final class AppOperationResultSocket: @unchecked Sendable {
    let requestId: String
    /// Bound by the client at socket registration; read by the send path.
    var boundIdentity: UUID?
    private var _closeHook: (() -> Void)?

    init(requestId: String) {
        self.requestId = requestId
    }
}

extension AppOperationResultSocket {
    /// Set by `routeWithResultSocket`; invoked by the sink when the turn's event loop has ended.
    /// Closes (cancels + retires) the turn socket AFTER the consumer's awaited result sends —
    /// never on producer completion, which `AsyncStream` signals via `onTermination` on
    /// `finish()` while the consumer may still be mid-turn.
    func finishTurn() {
        closeHook?()
        closeHook = nil
    }

    var closeHook: (() -> Void)? {
        get { _closeHook }
        set { _closeHook = newValue }
    }
}
