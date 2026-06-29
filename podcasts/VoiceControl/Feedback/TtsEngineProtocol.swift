import Foundation

protocol TtsEngineProtocol {
    func warmUp(language: String)
    func speak(text: String, language: String) async
    func release()
}
