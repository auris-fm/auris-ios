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

    func evaluate() -> Verdict {
        // Every step needs its own request identity, and they must be distinct: a reused or missing id
        // means the evidence cannot be tied to its turn.
        for (name, step) in [("A1", a1), ("A2", a2), ("B1", b1)] {
            guard let id = step.requestId, !id.isEmpty else { return .fail("\(name) has no request id") }
            guard let conv = step.conversationId, !conv.isEmpty else { return .fail("\(name) has no conversation id") }
            guard step.terminal != nil else { return .fail("\(name) has no terminal outcome") }
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
        // Isolation is judged on B1's response: a new conversation must not reach A's history.
        guard !b1.responseText.contains(nonce) else {
            return .fail("a NEW conversation recalled the nonce, so conversations are not isolated")
        }
        // A1's terminal must be a completed turn too; a transport failure there means nothing was sent.
        if case .transportFailure(let code) = a1.terminal {
            return .fail("A1 did not complete: \(code)")
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
