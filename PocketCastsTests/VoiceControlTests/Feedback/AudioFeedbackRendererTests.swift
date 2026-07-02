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
        let ttsEngine = MockTtsEngine()
        let renderer = AudioFeedbackRenderer(earconPlayer: earconPlayer, ttsEngine: ttsEngine)
        renderer.render(.silent)
        XCTAssertNil(earconPlayer.lastPlayed)
        XCTAssertNil(ttsEngine.lastSpokenText)
    }

    func test_playEarcon_delegatesToRender() {
        let earconPlayer = MockEarconPlayer()
        let renderer = AudioFeedbackRenderer(earconPlayer: earconPlayer, ttsEngine: MockTtsEngine())
        renderer.playEarcon(.listeningStart)
        XCTAssertTrue(earconPlayer.didPlay(.listeningStart))
    }

    func test_combinedResponse_playsEarconAndSpeaks() async {
        let earconPlayer = MockEarconPlayer()
        let ttsEngine = MockTtsEngine()
        let renderer = AudioFeedbackRenderer(earconPlayer: earconPlayer, ttsEngine: ttsEngine)
        renderer.render(.combined(earcon: .success, spokenText: "Done"))
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(earconPlayer.didPlay(.success))
        XCTAssertEqual(ttsEngine.lastSpokenText, "Done")
    }

    func test_newRenderCancelsPrevious() async {
        let ttsEngine = MockTtsEngine()
        let renderer = AudioFeedbackRenderer(earconPlayer: MockEarconPlayer(), ttsEngine: ttsEngine)
        renderer.render(.spoken("First"))
        renderer.render(.spoken("Second"))
        try? await Task.sleep(nanoseconds: 100_000_000)
        // Second should have cancelled first; cancel should have been called
        XCTAssertTrue(ttsEngine.wasCancelled)
    }

    func test_release_releasesBothEngines() {
        let earconPlayer = MockEarconPlayer()
        let ttsEngine = MockTtsEngine()
        let renderer = AudioFeedbackRenderer(earconPlayer: earconPlayer, ttsEngine: ttsEngine)
        renderer.release()
        XCTAssertTrue(earconPlayer.wasReleased)
        XCTAssertTrue(ttsEngine.wasReleased)
    }
}

// MARK: - Mocks

private final class MockEarconPlayer: EarconPlayer {
    var lastPlayed: EarconId?
    var didPlay: [EarconId] = []
    var wasReleased = false

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

    override func release() {
        wasReleased = true
        super.release()
    }
}

private final class MockTtsEngine: TtsEngineProtocol {
    var lastSpokenText: String?
    var lastLanguage: String?
    var wasWarmedUp = false
    var wasCancelled = false
    var wasReleased = false

    func warmUp(language: String) {
        wasWarmedUp = true
    }

    func speak(text: String, language: String) async {
        lastSpokenText = text
        lastLanguage = language
    }

    func cancel() {
        wasCancelled = true
    }

    func release() {
        wasReleased = true
    }
}
