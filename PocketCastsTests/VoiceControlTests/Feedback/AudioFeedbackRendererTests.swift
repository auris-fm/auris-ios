import XCTest
@testable import podcasts

final class AudioFeedbackRendererTests: XCTestCase {

    func test_earconResponse_playsEarcon() {
        let earconPlayer = MockEarconPlayer()
        let renderer = AudioFeedbackRenderer(earconPlayer: earconPlayer, ttsEngine: MockTtsEngine())
        renderer.render(.earcon(.success))
        XCTAssertTrue(earconPlayer.didPlay(.success))
    }

    func test_spokenResponse_speaksText() async {
        let ttsEngine = MockTtsEngine()
        let renderer = AudioFeedbackRenderer(earconPlayer: MockEarconPlayer(), ttsEngine: ttsEngine)
        renderer.render(.spoken("Playing at 1.5x"))
        // Allow async speak to complete
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(ttsEngine.lastSpokenText, "Playing at 1.5x")
    }

    func test_silentResponse_doesNothing() {
        let earconPlayer = MockEarconPlayer()
        let renderer = AudioFeedbackRenderer(earconPlayer: earconPlayer, ttsEngine: MockTtsEngine())
        renderer.render(.silent)
        XCTAssertNil(earconPlayer.lastPlayed)
    }

    func test_playEarcon_delegatesToRender() {
        let earconPlayer = MockEarconPlayer()
        let renderer = AudioFeedbackRenderer(earconPlayer: earconPlayer, ttsEngine: MockTtsEngine())
        renderer.playEarcon(.listeningStart)
        XCTAssertTrue(earconPlayer.didPlay(.listeningStart))
    }
}

// MARK: - Mocks

private final class MockEarconPlayer: EarconPlayer {
    var lastPlayed: EarconId?
    var didPlay: [EarconId] = []

    init() {
        // Skip actual AVAudioEngine setup for tests
        super.init(engine: AVAudioEngine())
    }

    override func play(_ id: EarconId) {
        lastPlayed = id
        didPlay.append(id)
    }

    func didPlay(_ id: EarconId) -> Bool {
        didPlay.contains(id)
    }
}

private final class MockTtsEngine: TtsEngineProtocol {
    var lastSpokenText: String?
    var lastLanguage: String?
    var wasWarmedUp = false

    func warmUp(language: String) {
        wasWarmedUp = true
    }

    func speak(text: String, language: String) async {
        lastSpokenText = text
        lastLanguage = language
    }

    func release() {}
}
