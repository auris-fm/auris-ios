import Foundation

/// What the ASR engine should do with a segment after wake detection, per
/// recognition-pipeline.md "Detector placement and conversation grace period".
enum WakeGateDecision: Equatable {
    /// Detector error: discard the segment, report a processing error, leave
    /// grace unchanged; never run ASR or play the wake earcon.
    case discardProcessing(errorCode: String)
    /// Negative outside grace: drop the segment before ASR.
    case dropUtterance
    /// Positive in either mode (open/reset grace + earcon handled by caller) or
    /// negative during grace: forward the complete original VAD segment to ASR.
    case forward(detected: Bool)
}

enum WakeGate {
    static func decide(
        result: WakeWordResult,
        listeningMode: ListeningMode,
        graceActive: Bool
    ) -> WakeGateDecision {
        switch result {
        case .error(let code):
            return .discardProcessing(errorCode: code)
        case .notDetected:
            if listeningMode == .wakeWord && !graceActive {
                return .dropUtterance
            }
            return .forward(detected: false)
        case .detected:
            return .forward(detected: true)
        }
    }
}
