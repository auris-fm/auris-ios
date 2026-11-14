import Foundation

/// Immutable ASR/translation → intent-routing envelope.
/// Current `english_v1` releases consume `routerTranscript` only; source fields
/// must still survive unchanged for later format selection.
struct IntentRoutingInput: Equatable {
    let sourceTranscript: String?
    let sourceLanguage: String?
    let routerTranscript: String
    let translationKind: TranslationKind
    /// REQUEST OWNERSHIP (owner delta 3484cbc/5eca874): the identity of the captured utterance
    /// this input carries. Duplicate callbacks re-emitting the SAME utterance carry the SAME id,
    /// so the request owner can join/reuse one prepared wire request; an independent utterance
    /// has its own id and dispatches its own request, even inside one grace window.
    let utteranceId: String

    /// The turn's own latency bookkeeping, created when the capture was admitted. Carried here
    /// because this envelope is the one object that spans admission → routing → dispatch, so the
    /// instants recorded at admission reach the cloud request without a side table keyed by
    /// utterance id — and die with the turn when it ends, whatever path it takes.
    let latency: TurnLatencyContext?

    init(
        sourceTranscript: String?,
        sourceLanguage: String?,
        routerTranscript: String,
        translationKind: TranslationKind,
        selection: CloudConversationSelection?,
        utteranceId: String,
        latency: TurnLatencyContext? = nil
    ) {
        self.sourceTranscript = sourceTranscript
        self.sourceLanguage = sourceLanguage
        self.routerTranscript = routerTranscript
        self.translationKind = translationKind
        self.selection = selection
        self.utteranceId = utteranceId
        self.latency = latency
    }

    /// The timing object is not part of identity: the same input describes the same turn whether
    /// or not it holds one. A synthesized `Equatable` would compare it by reference and make two
    /// otherwise identical inputs unequal.
    static func == (lhs: IntentRoutingInput, rhs: IntentRoutingInput) -> Bool {
        lhs.sourceTranscript == rhs.sourceTranscript
            && lhs.sourceLanguage == rhs.sourceLanguage
            && lhs.routerTranscript == rhs.routerTranscript
            && lhs.translationKind == rhs.translationKind
            && lhs.selection == rhs.selection
            && lhs.utteranceId == rhs.utteranceId
    }

    /// What SELECTED this utterance, carried from the gate decision that produced it.
    ///
    /// Read from live state instead, a wake that fires during grace and a follow-up inside the
    /// same grace are indistinguishable — both see `isActive == true` — so the two inputs cannot
    /// be told apart from the window they arrive in. The gate already computes the distinction
    /// (`detected` true/false) and it is a property of the INPUT, so it travels with it.
    let selection: CloudConversationSelection?

    /// Same source/router text with `.none` (native English path).
    static func english(
        transcript: String,
        language: String? = nil,
        selection: CloudConversationSelection? = nil,
        utteranceId: String,
        latency: TurnLatencyContext? = nil
    ) -> IntentRoutingInput {
        IntentRoutingInput(
            sourceTranscript: transcript,
            sourceLanguage: language,
            routerTranscript: transcript,
            translationKind: .none,
            selection: selection,
            utteranceId: utteranceId,
            latency: latency
        )
    }
}

enum TranslationKind: String, Equatable {
    case none
    case platform
    case backend

    var wireName: String { rawValue }
}

/// Manifest `router_input_format`. Missing field → `.englishV1`.
/// Only `.englishV1` is ready for inference until byte-matched fixtures land for others.
enum RouterInputFormat: Equatable {
    case englishV1
    case sourceV1
    case dualV1
    case unknown(String)

    var wireName: String {
        switch self {
        case .englishV1: return "english_v1"
        case .sourceV1: return "source_v1"
        case .dualV1: return "dual_v1"
        case .unknown(let raw): return raw
        }
    }

#if DEBUG
    /// Benchmark-only opt-in for the reviewed/debug harness path (Item 21).
    /// Production code must never set this — in release builds it does not
    /// even exist, so dual_v1 is compile-time fail-closed there.
    nonisolated(unsafe) static var benchmarkGateOpen = false
#endif

    var isReadyForInference: Bool {
        if case .englishV1 = self { return true }
#if DEBUG
        if case .dualV1 = self { return Self.benchmarkGateOpen }
#endif
        return false
    }

    static func parse(_ raw: String?) -> RouterInputFormat {
        switch raw {
        case nil, "english_v1": return .englishV1
        case "source_v1": return .sourceV1
        case "dual_v1": return .dualV1
        case let value?: return .unknown(value)
        }
    }
}
