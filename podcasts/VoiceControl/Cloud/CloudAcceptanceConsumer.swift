import Foundation

/// THE EXECUTABLE CONSUMER for the acceptance protocol. It drives `collectAcceptance` for the three
/// controlled turns and decides recall and isolation from the RECORDS, not from logs:
///
///   A1  conversation A carries the benign nonce
///   A2  the SAME conversation asks for the nonce without supplying it  -> recall iff A2's response contains it
///   B1  a NEW conversation asks for the nonce without supplying it     -> isolation iff B1's response does not
///
/// It enforces the checks a log scan cannot: every request id must be nonempty and FRESH, the
/// conversation ids must satisfy A1 == A2 != B1, each step must have its own terminal, and a step's
/// evidence is that step's own record. It rejects empty/mismatched/stale ids and outgoing-only evidence
/// rather than treating a record's mere existence as a pass.
struct CloudAcceptanceConsumer {

    struct StepOutcome {
        let requestId: String?
        let conversationId: String?
        let responseText: String
        let terminal: CloudAcceptanceRecord.Terminal?
    }

    enum Verdict: Equatable {
        case pass
        case fail(String)
    }

    /// The three steps' outcomes, in protocol order.
    let a1: StepOutcome
    let a2: StepOutcome
    let b1: StepOutcome
    /// The nonce the operator was asked to send in A1. Kept so the check compares CONTENT.
    let nonce: String

    /// A BOUNDED rendering of a terminal for verdict text: stage and code only, never a server message.
    static func bounded(_ terminal: CloudAcceptanceRecord.Terminal?) -> String {
        guard let terminal else { return "none" }
        switch terminal {
        case .done: return "done"
        case .cancelled: return "cancelled"
        case .transportFailure(let stage, let code, _): return "\(stage.rawValue):\(code)"
        }
    }

    func evaluate() -> Verdict {
        // An EMPTY NONCE proves nothing: every response would vacuously "not contain" it, so isolation
        // would pass for the wrong reason and recall could never be demonstrated.
        guard !nonce.isEmpty else { return .fail("the nonce is empty, so recall cannot be demonstrated") }

        // Every step needs its own request identity, and they must be distinct: a reused or missing id
        // means the evidence cannot be tied to its turn.
        for (name, step) in [("A1", a1), ("A2", a2), ("B1", b1)] {
            guard let id = step.requestId, !id.isEmpty else { return .fail("\(name) has no request id") }
            guard let conv = step.conversationId, !conv.isEmpty else { return .fail("\(name) has no conversation id") }
            // A SUCCESSFUL done terminal is REQUIRED. An error, a transport failure or a cancellation is
            // not a completed turn: counting any terminal as success would let a failed step pass, and a
            // missing done/error would be indistinguishable from one.
            guard step.terminal == .done else {
                // BOUNDED: the failure text is built from STAGE and CODE only. Interpolating the
                // terminal would embed the raw server message in the verdict, which is the free-form
                // text this protocol must not carry out of the app.
                return .fail("\(name) did not complete successfully (terminal: \(Self.bounded(step.terminal)))")
            }
        }
        let ids = [a1.requestId!, a2.requestId!, b1.requestId!]
        guard Set(ids).count == 3 else { return .fail("request ids are not distinct: \(ids)") }

        // A1 and A2 are the SAME conversation; B1 is a different one.
        guard a1.conversationId == a2.conversationId else {
            return .fail("A1 and A2 are different conversations: \(a1.conversationId ?? "nil") vs \(a2.conversationId ?? "nil")")
        }
        guard b1.conversationId != a1.conversationId else {
            return .fail("B1 reused conversation A's id: \(b1.conversationId ?? "nil")")
        }

        // Recall is judged on A2's INCOMING response only, never on A1's outgoing prompt.
        guard a2.responseText.contains(nonce) else {
            return .fail("conversation A did not recall the nonce (response: \(a2.responseText.prefix(80)))")
        }
        // Isolation is judged on B1's response: a new conversation must not reach A's history. An EMPTY
        // response is not evidence of isolation — it says the turn produced nothing, so the question was
        // never answered and the check must fail rather than pass vacuously.
        guard !b1.responseText.isEmpty else {
            return .fail("B1 returned no response, so isolation was not demonstrated")
        }
        guard !b1.responseText.contains(nonce) else {
            return .fail("a NEW conversation recalled the nonce, so conversations are not isolated")
        }
        // Recall needs a nonempty incoming response too: an empty A2 response cannot contain the nonce,
        // and the earlier check already fails for it — stated here so the requirement is explicit.
        guard !a2.responseText.isEmpty else {
            return .fail("A2 returned no response, so recall was not demonstrated")
        }
        return .pass
    }

    /// The verdict as a single machine-readable line, because `simctl launch` reports the launch and
    /// always exits 0 — an exit code would hide a failed acceptance run.
    func verdictLine() -> String {
        switch evaluate() {
        case .pass: return "ACCEPTANCE-VERDICT=PASS"
        case .fail(let why): return "ACCEPTANCE-VERDICT=FAIL (\(why))"
        }
    }
}
