import Foundation
import PocketCastsUtils

/// The collector's production sink: turns completed collector events into durable queue entries
/// (encode → `prepare` → `finalize`), gated on the live collection policy.
///
/// Authorization binding (reviewer 5357d089/5b1ba085/70e5fc58): each event captures the CURRENT
/// revocation generation at enqueue (slot lock, short), and the publication transaction — the
/// final gate re-checks and `finalize` — runs inside ONE critical section (`publicationLock`)
/// shared with `noteRevocation()`. A withdrawal cannot interleave between the final check and
/// publication;
/// an event queued under a superseded authorization never publishes even if the gate later reads
/// true again (account switch / off→on). Revocation also routes through the ASSEMBLY gate-lost
/// handler, which purges both the collector and the durable queue.
///
/// Off the audio callback: `handle` reserves a pending slot under a lock (before enqueue — the
/// bound must hold while the worker is blocked, not merely inside it), enqueues, and returns.
/// Over the compiled ceiling the event is dropped and logged.
///
/// Admission before allocation (reviewer 5b1ba085): the sink asks the queue for its remaining
/// byte allowance and refuses BEFORE encoding the WAV/metadata copies. `prepare` still re-checks
/// exactly at write time.
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

    /// TWO locks, deliberately (reviewer 70e5fc58): `slotLock` is held ONLY for the short
    /// admission/accounting steps (slot reservation, generation capture, the final gate read), so
    /// `handle` returns promptly on the audio caller even while a slow publication is running disk
    /// work. `publicationLock` serializes the publication transaction with `noteRevocation()` so a
    /// withdrawal cannot interleave between the final checks and `finalize`. Never nest them in the
    /// opposite order: publicationLock → slotLock only, never slotLock → publicationLock.
    private let slotLock = NSLock()
    private let publicationLock = NSLock()
    private var revocationGeneration = 0
    /// Bounded pending slot accounting, OUTSIDE the worker (the bound must hold while the worker
    /// is blocked or slow, so the check cannot live inside the serialized worker block).
    private var pendingSlots = 0

    /// Test-only seam: called at worker start when set (lets controls block the worker).
    var testingWorkerGate: (() -> Void)?

    struct PendingEvent {
        let event: VoiceSharingCollector.SegmentEvent
        let capturedGeneration: Int
    }

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

    /// Consent revocation signal (withdrawal, sign-out, switch-off, lease loss). Bumps the
    /// generation under the SAME lock the publication transaction holds, so no publication can
    /// interleave between its final check and `finalize`.
    func noteRevocation() {
        publicationLock.lock()
        slotLock.lock()
        revocationGeneration += 1
        slotLock.unlock()
        publicationLock.unlock()
    }

    /// Audio-callback safe: slot reservation under lock, then enqueue. No disk, no encode.
    func handle(_ event: VoiceSharingCollector.SegmentEvent) {
        slotLock.lock()
        guard pendingSlots < Self.maxPendingEvents else {
            slotLock.unlock()
            FileLog.shared.addMessage(
                "[VoiceSharing] sink saturated, event dropped capture=\(event.captureID)")
            return
        }
        pendingSlots += 1
        let captured = revocationGeneration
        slotLock.unlock()
        workerQueue.async { [self] in
            defer {
                slotLock.lock()
                pendingSlots -= 1
                slotLock.unlock()
            }
            process(PendingEvent(event: event, capturedGeneration: captured))
        }
    }

    /// Reads the live revocation generation under the slot lock (short, never held across disk).
    private func currentGeneration() -> Int {
        slotLock.lock()
        defer { slotLock.unlock() }
        return revocationGeneration
    }

    /// Test seam: blocks until every enqueued event has been processed.
    func waitForIdleForTesting() {
        workerQueue.sync {}
    }

    private func process(_ pending: PendingEvent) {
        testingWorkerGate?()
        // Admission BEFORE allocation: the queue's measured remaining allowance must cover the
        // worst-case entry (WAV payload + largest legal metadata + protocol overhead) before any
        // encoded copy exists. prepare re-checks exactly at write time.
        let worstCase = pending.event.audio.count * 2
            + VoiceSharingRecordBinding.wavHeaderBytes
            + VoiceSharingUploadQueue.maxMetadataBytes
            + VoiceSharingUploadQueue.protocolOverheadBytes
        guard queue.hasAdmissionAllowance(forBytes: worstCase) else {
            FileLog.shared.addMessage(
                "[VoiceSharing] contribution dropped (queue budget) capture=\(pending.event.captureID)")
            return
        }

        // The publication transaction: encode + prepare + final revocation check + finalize run
        // inside the critical section shared with noteRevocation. Only the WORKER takes this lock
        // for a long interval; `handle` on the audio caller never waits on it.
        publicationLock.lock()
        defer { publicationLock.unlock() }
        // Gate check 1: authorization still current (live switch AND captured generation).
        guard isEnabled(), currentGeneration() == pending.capturedGeneration else { return }
        var provenance = encoderProvenance()
        if let session = pending.event.authorizationSession {
            provenance.captureSessionID = session
        }
        do {
            // ENGINE-PRODUCED OBSERVATIONS WIN (review c48461e6): the event carries the stages the
            // recogniser actually reported for this capture; a claim supplied by the caller covers only
            // stages the engine did not report. A caller can therefore never overwrite a real
            // observation with its own narrative, and the recorded claim traces to the engine.
            var claims = observations()
            for (stage, observed) in pending.event.reportedStages {
                claims[stage] = observed
            }
            let encoded = try VoiceSharingContributionEncoder.encode(
                event: pending.event, provenance: provenance, observations: claims)
            // Gate check 2: the encoded bytes must not become a queue entry under a closed gate.
            guard isEnabled(), currentGeneration() == pending.capturedGeneration else { return }
            let entry = try queue.prepare(metadata: encoded.metadataEnvelope, audio: encoded.wav)
            // Gate check 3 + finalize in the SAME critical section: a noteRevocation() cannot
            // land between this check and publication — it waits for the lock, and the next
            // reader (purge in the assembly) removes what this transaction published.
            guard isEnabled(), currentGeneration() == pending.capturedGeneration else {
                do { try queue.discardUnready(entry) } catch {
                    FileLog.shared.addMessage(
                        "[VoiceSharing] revocation discard failed (entry retained, charged) capture=\(pending.event.captureID)")
                }
                return
            }
            try queue.finalize(entry)
        } catch {
            FileLog.shared.addMessage(
                "[VoiceSharing] contribution dropped kind=\(pending.event.kind) capture=\(pending.event.captureID) error=\(String(describing: type(of: error)))"
            )
        }
    }
}
