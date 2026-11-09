import Foundation
import PocketCastsUtils

/// The collector's sink: encodes one segment and publishes it straight into the queue.
///
/// This replaces the former contribution sink, whose job was to hold, bind and reconcile entries
/// against a recovery journal. With folders as the only queue state there is nothing to reconcile:
/// encode, publish, ask for a drain. A failure anywhere is logged and dropped — never into the
/// recognition pipeline.
final class VoiceSharingDirectSink {

    private let queue: VoiceSharingQueue
    private let isEnabled: () -> Bool
    private let encoderProvenance: () -> VoiceSharingContributionEncoder.Provenance
    /// Caller-supplied stage claims. The event's own engine-produced stages override these, so a
    /// caller can cover a stage the engine did not report but can never overwrite a real observation.
    /// Production passes nothing; tests use it to drive specific stage combinations.
    private let observations: () -> [String: VoiceSharingContributionEncoder.StageOutcome]
    private let requestUploadDrain: () -> Void

    init(queue: VoiceSharingQueue,
         isEnabled: @escaping () -> Bool,
         encoderProvenance: @escaping () -> VoiceSharingContributionEncoder.Provenance,
         observations: @escaping () -> [String: VoiceSharingContributionEncoder.StageOutcome] = { [:] },
         requestUploadDrain: @escaping () -> Void) {
        self.queue = queue
        self.isEnabled = isEnabled
        self.encoderProvenance = encoderProvenance
        self.observations = observations
        self.requestUploadDrain = requestUploadDrain
    }

    func handle(_ event: VoiceSharingCollector.SegmentEvent) async {
        guard isEnabled() else { return }
        do {
            // ENGINE-PRODUCED observations win: the event carries the stages the recogniser
            // actually reported, and they override any caller claim for the same stage.
            var claims = observations()
            for (stage, observed) in event.reportedStages { claims[stage] = observed }
            let encoded = try VoiceSharingContributionEncoder.encode(
                event: event, provenance: encoderProvenance(), observations: claims)
            // The drain is requested only once the recording is actually on disk: asking first
            // would have the uploader look at a queue that does not yet contain this segment.
            guard await queue.publish(audio: encoded.wav, metadata: encoded.metadata) != nil else {
                return // the queue logs its own drop reason
            }
            requestUploadDrain()
        } catch {
            FileLog.shared.addMessage("[VoiceSharing] encode failed capture=\(event.captureID)")
        }
    }
}
