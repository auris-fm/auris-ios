import Foundation

/// Immutable ASR/translation → intent-routing envelope.
/// Current `english_v1` releases consume `routerTranscript` only; source fields
/// must still survive unchanged for later format selection.
struct IntentRoutingInput: Equatable {
    let sourceTranscript: String?
    let sourceLanguage: String?
    let routerTranscript: String
    let translationKind: TranslationKind

    /// Same source/router text with `.none` (native English path).
    static func english(transcript: String, language: String? = "en") -> IntentRoutingInput {
        IntentRoutingInput(
            sourceTranscript: transcript,
            sourceLanguage: language,
            routerTranscript: transcript,
            translationKind: .none
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

    var isReadyForInference: Bool {
        if case .englishV1 = self { return true }
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
