import Foundation

/// The latency bookkeeping of ONE turn, owned by the turn itself.
///
/// WHY A PER-TURN OBJECT. These instants — when the user stopped talking, when the endpoint fired,
/// when the request actually went out — were first held in the sink, keyed by utterance id. That
/// dictionary had to be cleaned up on every path a turn could leave by: the release from the
/// engine, the router's terminal, the dispatch's own exits. Each of those was a separate place to
/// forget, and each one that was missed leaked. The instants belong to the turn, so they live on an
/// object created when the turn is admitted and referenced by nothing else: when the turn ends,
/// ARC reclaims them. There is no mark, no discard, and no list of exits to keep complete.
///
/// Written once each, at the only moment the value exists: `endOfSpeech` and `endpointDecisionAt`
/// at admission, `requestSentAt` by the transport when the authenticated frame is sent. Read by the
/// latency record when the turn reaches its terminal.
///
/// `@unchecked Sendable`: the fields are written from different threads (capture, admission, the
/// transport) and read at the terminal, so they are guarded by `lock` rather than left to chance.
final class TurnLatencyContext: @unchecked Sendable {
    private let lock = NSLock()
    private var endOfSpeechStorage: MonotonicTime?
    private var endpointDecisionStorage: MonotonicTime?
    private var requestSentStorage: MonotonicTime?

    init() {}

    /// The acoustic end of speech, i.e. the last SPEECH sample of the utterance. First value wins:
    /// a duplicate admission for the same capture must not move the turn's start later.
    var endOfSpeech: MonotonicTime? {
        get { lock.lock(); defer { lock.unlock() }; return endOfSpeechStorage }
        set { lock.lock(); defer { lock.unlock() }; if endOfSpeechStorage == nil { endOfSpeechStorage = newValue } }
    }

    /// The instant the endpoint decision fired, which follows `endOfSpeech` by the hangover.
    var endpointDecisionAt: MonotonicTime? {
        get { lock.lock(); defer { lock.unlock() }; return endpointDecisionStorage }
        set { lock.lock(); defer { lock.unlock() }; if endpointDecisionStorage == nil { endpointDecisionStorage = newValue } }
    }

    /// The instant the authenticated request frame actually reached the transport. Stamped once,
    /// at the send — never inferred from the first reply frame.
    var requestSentAt: MonotonicTime? {
        get { lock.lock(); defer { lock.unlock() }; return requestSentStorage }
        set { lock.lock(); defer { lock.unlock() }; if requestSentStorage == nil { requestSentStorage = newValue } }
    }
}
