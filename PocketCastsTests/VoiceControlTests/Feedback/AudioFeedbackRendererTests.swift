import XCTest
@testable import podcasts

final class AudioFeedbackRendererTests: XCTestCase {

    func test_earconResponse_playsEarcon() {
        let earconPlayer = MockEarconPlayer()
        let renderer = AudioFeedbackRenderer(earconPlayer: earconPlayer, ttsEngine: MockTtsEngine(), ducker: NoOpDucker())
        renderer.render(.earcon(.success))
        XCTAssertTrue(pumpUntil { earconPlayer.didPlay(.success) })
        XCTAssertTrue(earconPlayer.didPlay(.success))
    }

    func test_spokenResponse_speaksText() {
        let ttsEngine = MockTtsEngine()
        let renderer = AudioFeedbackRenderer(earconPlayer: MockEarconPlayer(), ttsEngine: ttsEngine, ducker: NoOpDucker())
        renderer.render(.spoken("Playing at 1.5x"))
        XCTAssertTrue(pumpUntil { ttsEngine.lastSpokenText != nil })
        XCTAssertEqual(ttsEngine.lastSpokenText, "Playing at 1.5x")
    }

    func test_silentResponse_doesNothing() {
        let earconPlayer = MockEarconPlayer()
        let ttsEngine = MockTtsEngine()
        let renderer = AudioFeedbackRenderer(earconPlayer: earconPlayer, ttsEngine: ttsEngine, ducker: NoOpDucker())
        renderer.render(.silent)
        XCTAssertNil(earconPlayer.lastPlayed)
        XCTAssertNil(ttsEngine.lastSpokenText)
    }

    func test_playEarcon_delegatesToRender() {
        let earconPlayer = MockEarconPlayer()
        let renderer = AudioFeedbackRenderer(earconPlayer: earconPlayer, ttsEngine: MockTtsEngine(), ducker: NoOpDucker())
        renderer.playEarcon(.listeningStart)
        XCTAssertTrue(pumpUntil { earconPlayer.didPlay(.listeningStart) })
        XCTAssertTrue(earconPlayer.didPlay(.listeningStart))
    }

    func test_combinedResponse_playsEarconAndSpeaks() {
        let earconPlayer = MockEarconPlayer()
        let ttsEngine = MockTtsEngine()
        let renderer = AudioFeedbackRenderer(earconPlayer: earconPlayer, ttsEngine: ttsEngine, ducker: NoOpDucker())
        renderer.render(.combined(earcon: .success, spokenText: "Done"))
        XCTAssertTrue(pumpUntil { earconPlayer.didPlay(.success) && ttsEngine.lastSpokenText != nil })
        XCTAssertTrue(earconPlayer.didPlay(.success))
        XCTAssertEqual(ttsEngine.lastSpokenText, "Done")
    }

    func test_newRenderCancelsPrevious() async {
        let ttsEngine = MockTtsEngine()
        let renderer = AudioFeedbackRenderer(earconPlayer: MockEarconPlayer(), ttsEngine: ttsEngine, ducker: NoOpDucker())
        renderer.render(.spoken("First"))
        renderer.render(.spoken("Second"))
        try? await Task.sleep(nanoseconds: 100_000_000)
        // Second should have cancelled first; cancel should have been called
        XCTAssertTrue(ttsEngine.wasCancelled)
    }

    func test_release_releasesBothEngines() {
        let earconPlayer = MockEarconPlayer()
        let ttsEngine = MockTtsEngine()
        let renderer = AudioFeedbackRenderer(earconPlayer: earconPlayer, ttsEngine: ttsEngine, ducker: NoOpDucker())
        renderer.release()
        XCTAssertTrue(earconPlayer.wasReleased)
        XCTAssertTrue(ttsEngine.wasReleased)
    }

    /// Pumps the main run loop until `condition` holds. The renderer's render
    /// task is scheduled on the main run loop, and XCTest's wait(for:) does not
    /// reliably advance it, so tests pump directly.
    @discardableResult
    private func pumpUntil(_ condition: () -> Bool, timeout: TimeInterval = 6.0) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        return condition()
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

    override func hasEarcon(_ id: EarconId) -> Bool {
        true
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

private final class NoOpDucker: AudioSessionDucking {
    func duck() {}
    func unduck() {}
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

    func releaseEngine() {
        wasReleased = true
    }
}
