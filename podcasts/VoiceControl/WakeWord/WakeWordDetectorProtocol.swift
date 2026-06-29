import Foundation

protocol WakeWordDetectorProtocol: AnyObject {
    func detect(samples: [Float], sampleRate: Int) -> Float
    func release()
}
