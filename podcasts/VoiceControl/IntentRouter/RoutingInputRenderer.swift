import Foundation

/// Byte-pinned serializers for the versioned routing-input representation,
/// mirroring core `training/function-call/routing_input.py`. The release
/// manifest owns `router_input_format`; training, MLX eval, GGUF eval,
/// Android, and iOS must all render identical routing-input strings.
enum RoutingInputRenderer {
    enum RenderError: Error, Equatable {
        case blankRouterTranscript
        case unknownFormat(String)
    }

    /// Renders the exact routing-input user content for an envelope.
    static func render(format: RouterInputFormat, input: IntentRoutingInput) throws -> String {
        let router = input.routerTranscript
        guard !router.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RenderError.blankRouterTranscript
        }
        let sourceText = input.sourceTranscript
        let sourceLang = input.sourceLanguage ?? "en"
        let hasSource = sourceText.map { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? false

        switch format {
        case .englishV1:
            return router

        case .sourceV1:
            if hasSource {
                return "<source lang=\"\(sourceLang)\">\(sourceText!)</source>"
            }
            // Missing native source: effective language is en, never the
            // backend's configured source language; pin the fallback marker.
            return "<source lang=\"en\" source_fallback=\"router_transcript\">\(router)</source>"

        case .dualV1:
            if hasSource {
                return "<source lang=\"\(sourceLang)\">\(sourceText!)</source><en>\(router)</en>"
            }
            return "<source_missing=\"true\" lang=\"en\"><en>\(router)</en>"

        case .unknown(let raw):
            throw RenderError.unknownFormat(raw)
        }
    }
}
