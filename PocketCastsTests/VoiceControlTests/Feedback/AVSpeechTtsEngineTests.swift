import XCTest
@testable import podcasts

final class AVSpeechTtsEngineTests: XCTestCase {

    func test_warmUp_doesNotThrow() {
        let engine = AVSpeechTtsEngine()
        engine.warmUp(language: "en-US")
        // Verifying it doesn't crash
    }

    func test_speak_completesAsync() async {
        let engine = AVSpeechTtsEngine()
        await engine.speak(text: "Hello", language: "en-US")
        // Verifies async speak completion via delegate
    }

    func test_cancel_stopsSpeaking() {
        let engine = AVSpeechTtsEngine()
        engine.cancel()
        // Verifies no crash on cancel when not speaking
    }

    func test_release_stopsEngine() {
        let engine = AVSpeechTtsEngine()
        engine.release()
        // Verifies no crash on release
    }

    func test_speak_cancelsPreviousUtterance() async {
        let engine = AVSpeechTtsEngine()
        // Start first utterance (fire and forget to simulate ongoing speech)
        Task {
            await engine.speak(text: "Long text that takes time", language: "en-US")
        }
        // Give it a moment to start
        try? await Task.sleep(nanoseconds: 50_000_000)
        // Second utterance should cancel the first
        await engine.speak(text: "Short", language: "en-US")
        // Should complete without hanging
    }

    func test_warmUp_acceptsAnyLanguage() {
        let engine = AVSpeechTtsEngine()
        engine.warmUp(language: "ja-JP")
        engine.warmUp(language: "fr-FR")
        engine.warmUp(language: "es-ES")
        // Verifying no crash with different languages
    }
}
