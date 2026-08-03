import Foundation
@testable import podcasts

/// Recording double for `InferenceSession` used by router and session-pool tests.
final class RecordingSession: InferenceSession {
    let output: String
    private(set) var prefilled: [String] = []
    private(set) var generated: [String] = []

    init(output: String = "") {
        self.output = output
    }

    func prefill(_ prompt: String) async throws -> Int? {
        prefilled.append(prompt)
        return nil
    }

    func generate(_ prompt: String) throws -> String {
        generated.append(prompt)
        return output
    }

    func close() {}
}

/// Recording factory for `InferenceSession` creation.
final class RecordingSessionFactory: FunctionGemmaSessionFactory {
    let output: String
    private(set) var sessions: [RecordingSession] = []
    var makeError: Error?

    init(output: String = "") {
        self.output = output
    }

    func makeSession() async throws -> MadeSession {
        if let makeError { throw makeError }
        let session = RecordingSession(output: output)
        sessions.append(session)
        return MadeSession(session: session, backend: .litert)
    }
}

/// Controllable monotonic clock for timing tests.
final class FakeMonotonicClock: MonotonicClock {
    private var nowValue: CFTimeInterval = 0

    func setNow(_ value: CFTimeInterval) {
        nowValue = value
    }

    func now() -> CFTimeInterval {
        nowValue
    }
}
