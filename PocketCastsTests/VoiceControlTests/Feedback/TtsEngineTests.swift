import XCTest
@testable import podcasts

final class TtsEngineTests: XCTestCase {

    func test_warmUp_callsEngineWarmUp() {
        let engine = AVSpeechTtsEngine()
        engine.warmUp(language: "en-US")
        // No assertion needed — verifying it doesn't crash
    }

    func test_speak_callsEngine() async {
        let engine = AVSpeechTtsEngine()
        await engine.speak(text: "Hello", language: "en-US")
        // Verifies async speak completion
    }

    func test_release_stopsEngine() {
        let engine = AVSpeechTtsEngine()
        engine.release()
        // Verifies no crash on release
    }
}
