import XCTest
@testable import podcasts

/// Byte-pins the versioned routing-input serializers against the core
/// `routing_input.py` fixtures (english_v1 / source_v1 / dual_v1).
final class RoutingInputRendererTests: XCTestCase {
    private func envelope(
        source: String? = "倒回去3分钟。",
        language: String? = "zh",
        router: String = "Go back to 3 minutes.",
        kind: TranslationKind = .platform
    ) -> IntentRoutingInput {
        IntentRoutingInput(
            sourceTranscript: source,
            sourceLanguage: language,
            routerTranscript: router,
            translationKind: kind
        )
    }

    func test_englishV1_isRouterTranscriptOnly() throws {
        XCTAssertEqual(
            try RoutingInputRenderer.render(format: .englishV1, input: envelope()),
            "Go back to 3 minutes."
        )
    }

    func test_englishV1_ignoresSourceFields() throws {
        let input = envelope(source: "乱七八糟", language: "zh")
        XCTAssertEqual(
            try RoutingInputRenderer.render(format: .englishV1, input: input),
            "Go back to 3 minutes."
        )
    }

    func test_sourceV1_tagsNativeSource() throws {
        XCTAssertEqual(
            try RoutingInputRenderer.render(format: .sourceV1, input: envelope()),
            #"<source lang="zh">倒回去3分钟。</source>"#
        )
    }

    func test_sourceV1_fallbackUsesEnAndMarker() throws {
        let input = envelope(source: nil, language: "zh")
        XCTAssertEqual(
            try RoutingInputRenderer.render(format: .sourceV1, input: input),
            #"<source lang="en" source_fallback="router_transcript">Go back to 3 minutes.</source>"#
        )
    }

    func test_sourceV1_fallbackDoesNotRetainBackendLang() throws {
        let out = try RoutingInputRenderer.render(
            format: .sourceV1,
            input: envelope(source: nil, language: "zh")
        )
        XCTAssertFalse(out.contains(#"lang="zh""#))
    }

    func test_dualV1_separatelyTagsSourceAndEnglish() throws {
        XCTAssertEqual(
            try RoutingInputRenderer.render(format: .dualV1, input: envelope()),
            #"<source lang="zh">倒回去3分钟。</source><en>Go back to 3 minutes.</en>"#
        )
    }

    func test_dualV1_missingSourceIsExplicitNotCopied() throws {
        let out = try RoutingInputRenderer.render(
            format: .dualV1,
            input: envelope(source: nil, language: "zh")
        )
        XCTAssertTrue(out.contains(#"source_missing="true""#))
        XCTAssertFalse(out.contains("倒回去3分钟"))
        XCTAssertEqual(
            out,
            #"<source_missing="true" lang="en"><en>Go back to 3 minutes.</en>"#
        )
    }

    func test_blankRouterTranscriptIsRejected() {
        XCTAssertThrowsError(
            try RoutingInputRenderer.render(
                format: .englishV1,
                input: envelope(router: "   ")
            )
        )
    }

    func test_unknownFormatIsRejected() {
        XCTAssertThrowsError(
            try RoutingInputRenderer.render(
                format: .unknown("tri_v2"),
                input: envelope()
            )
        )
    }
}
