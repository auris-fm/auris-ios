import Foundation

@MainActor
protocol TtsEngineProtocol {
    func warmUp(language: String) async
    func speak(text: String, language: String) async
    func cancel()
    func releaseEngine()
}
