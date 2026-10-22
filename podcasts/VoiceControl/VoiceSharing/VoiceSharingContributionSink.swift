import Foundation
import PocketCastsUtils

/// The collector's production sink: turns completed collector events into durable queue entries
/// (encode → `prepare` → `finalize`), gated on the live collection policy.
///
/// Disabled-by-design: the gate is re-read from the coordinator's snapshot at THREE points —
/// before encode, before prepare, before finalize (reviewer 5357d089: a one-time check lets a
/// withdrawal during that work publish a revoked entry). Consent loss between prepare and
/// finalize discards the UNREADY entry; a cleanup failure leaves it retained and charged.
///
/// Off the audio callback: `handle` only validates and enqueues onto an internal bounded serial
/// queue and returns; encode/disk work never runs inside the recognition path. The pending bound
/// is a compiled ceiling, NOT an activation value — over it, the event is dropped and logged.
///
/// Error discipline: the sink NEVER throws into the segment pipeline. Failures are logged with
/// opaque IDs only (no audio, no transcript) and the event is dropped.
final class VoiceSharingContributionSink {
    /// Compiled ceiling on events awaiting the worker. NOT an activation value.
    static let maxPendingEvents = 16

    private let queue: VoiceSharingUploadQueue
    private let isEnabled: () -> Bool
    private let encoderProvenance: () -> VoiceSharingContributionEncoder.Provenance
    private let observations: () -> [String: VoiceSharingContributionEncoder.StageOutcome]
    private let workerQueue = DispatchQueue(label: "fm.auris.voicesharing.contribution-sink")
    private var pendingCount = 0

    init(
        queue: VoiceSharingUploadQueue,
        isEnabled: @escaping () -> Bool,
        encoderProvenance: @escaping () -> VoiceSharingContributionEncoder.Provenance,
        observations: @escaping () -> [String: VoiceSharingContributionEncoder.StageOutcome] = { [:] }
    ) {
        self.queue = queue
        self.isEnabled = isEnabled
        self.encoderProvenance = encoderProvenance
        self.observations = observations
    }

    /// Audio-callback safe: bounded enqueue, no disk, no encode on the caller's thread.
    func handle(_ event: VoiceSharingCollector.SegmentEvent) {
        workerQueue.async { [self] in
            guard pendingCount < Self.maxPendingEvents else {
                FileLog.shared.addMessage(
                    "[VoiceSharing] sink saturated, event dropped capture=\(event.captureID)")
                return
            }
            pendingCount += 1
            defer { pendingCount -= 1 }
            process(event)
        }
    }

    /// Test seam: blocks until every enqueued event has been processed (serial worker drain).
    func waitForIdleForTesting() {
        workerQueue.sync {}
    }

    private func process(_ event: VoiceSharingCollector.SegmentEvent) {
        // Gate check 1: before any work.
        guard isEnabled() else { return }
        // capture_session_id is the EVENT's authorization session, never a fresh fabrication.
        var provenance = encoderProvenance()
        if let session = event.authorizationSession {
            provenance.captureSessionID = session
        }
        do {
            let encoded = try VoiceSharingContributionEncoder.encode(
                event: event, provenance: provenance, observations: observations())
            // Gate check 2: the encoded bytes must not become a queue entry under a closed gate.
            guard isEnabled() else { return }
            let entry = try queue.prepare(metadata: encoded.metadataEnvelope, audio: encoded.wav)
            // Gate check 3: consent loss between prepare and finalize must NOT publish. The
            // unready entry is discarded; a cleanup failure leaves it retained and charged.
            guard isEnabled() else {
                do { try queue.discardUnready(entry) } catch {
                    FileLog.shared.addMessage(
                        "[VoiceSharing] revocation discard failed (entry retained, charged) capture=\(event.captureID)")
                }
                return
            }
            try queue.finalize(entry)
        } catch {
            FileLog.shared.addMessage(
                "[VoiceSharing] contribution dropped kind=\(event.kind) capture=\(event.captureID) error=\(String(describing: type(of: error)))"
            )
        }
    }
}
