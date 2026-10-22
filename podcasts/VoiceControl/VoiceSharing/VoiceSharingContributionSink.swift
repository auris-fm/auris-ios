import Foundation
import PocketCastsUtils

/// The collector's production sink: turns completed collector events into durable queue entries
/// (encode → `prepare` → `finalize`), gated on the live collection policy.
///
/// Disabled-by-design: the gate reads the coordinator's policy snapshot fresh on EVERY event, and
/// the remote switch defaults to disabled — nothing reaches the queue until the owner-approved
/// activation turns collection on. A stale "enabled" cannot survive a withdrawal: the next event
/// after consent loss sees the gate closed and purges nothing, records nothing.
///
/// Error discipline: the sink NEVER throws into the segment pipeline. Encode/queue failures are
/// logged with the capture ID only (no audio, no transcript) and the event is dropped — the
/// collector's own bounds decide what is retained, and a failed contribution must never take the
/// recognition pipeline down with it.
final class VoiceSharingContributionSink {
    private let queue: VoiceSharingUploadQueue
    private let isEnabled: () -> Bool
    private let encoderProvenance: VoiceSharingContributionEncoder.Provenance
    /// Caller-supplied stage claims (pipeline state at capture time).
    private let observations: () -> [String: VoiceSharingContributionEncoder.StageOutcome]

    init(
        queue: VoiceSharingUploadQueue,
        isEnabled: @escaping () -> Bool,
        encoderProvenance: VoiceSharingContributionEncoder.Provenance,
        observations: @escaping () -> [String: VoiceSharingContributionEncoder.StageOutcome] = { [:] }
    ) {
        self.queue = queue
        self.isEnabled = isEnabled
        self.encoderProvenance = encoderProvenance
        self.observations = observations
    }

    func handle(_ event: VoiceSharingCollector.SegmentEvent) {
        guard isEnabled() else { return }
        do {
            let encoded = try VoiceSharingContributionEncoder.encode(
                event: event, provenance: encoderProvenance, observations: observations())
            let entry = try queue.prepare(metadata: encoded.metadataEnvelope, audio: encoded.wav)
            try queue.finalize(entry)
        } catch {
            // Bounded log: kind + opaque capture ID + error identity. No audio, no transcript.
            FileLog.shared.addMessage(
                "[VoiceSharing] contribution dropped kind=\(event.kind) capture=\(event.captureID) error=\(String(describing: type(of: error)))"
            )
        }
    }
}
