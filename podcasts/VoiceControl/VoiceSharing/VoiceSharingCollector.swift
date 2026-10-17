import Foundation
import PocketCastsUtils

/// Observes the microphone segment pipeline and turns eligible speech into contribution work.
///
/// Why an observer rather than a stage inside recognition: the spec requires collecting wake-negative and
/// bleed-rejected segments too, and those are silent `return`s inside `VoiceAsrEngine.processUtterance`. A
/// consumer that only sees completion never observes them. So this type subscribes to the segmenter's
/// confirmed start, its in-progress accumulation, and its cancellation — plus the rejection branches — and
/// does nothing else to the pipeline.
///
/// Fail-closed is the whole design. Collection happens ONLY while every one of these holds at the moment of
/// the decision, re-read each time rather than cached from segment start:
///
///   * the policy snapshot permits collection (`permitsCollection`, which itself re-checks enrollment);
///   * membership is *known* and enrolled. Unknown or stale reads as not-enrolled — never as "probably fine";
///   * an enrollment epoch exists, because records must be scoped to a server-issued epoch.
///
/// Consequences the controls pin down: with the switch off, membership unknown/stale, or no epoch, the
/// collector retains ZERO samples, writes NO files, and enqueues NOTHING. Turning the gate off mid-segment
/// abandons the partial immediately rather than finishing it into the queue.
final class VoiceSharingCollector {

    /// Hard ceiling on one contribution's retained samples, enforced DURING the utterance. The point is that
    /// long speech cannot exceed memory/disk bounds before completion arrives — completion may never arrive if
    /// the permission or listening context closes mid-speech.
    static let maxSamplesPerContribution = 16_000 * 120   // 120 s at 16 kHz mono

    /// Bounded mailbox for handoffs off the capture callback. Overflow drops contribution work and counts the
    /// drop; it never blocks recognition.
    static let maxPendingHandoffs = 32

    struct SegmentEvent: Equatable {
        enum Kind: Equatable { case started, accumulated, completed, cancelled, rejectedBleed, rejectedWake }
        let kind: Kind
        let captureID: UUID
        let retainedSamples: Int
        /// True when the ceiling was hit and further audio for this capture was dropped. Truncation is stated
        /// rather than hidden: a clipped prefix must never be uploaded as if it were the whole utterance.
        let truncated: Bool
    }

    private let policy: VoiceSharingPolicy
    private let membership: () -> VoiceSharingEnrollmentStore.State
    private let epochProvider: () -> String?
    /// Off-callback work lands here. Kept as an injectable sink so tests observe exactly what production would
    /// enqueue, without touching the filesystem.
    private let sink: (SegmentEvent) -> Void

    private let lock = NSLock()
    /// Capture IDs opened by THIS instance, keyed by nothing but their own lifecycle: the segmenter gives no
    /// id, so the collector owns it, minted at confirmed start BEFORE rejection decisions exist.
    private var openCapture: UUID?
    private var retainedForOpenCapture = 0
    private var truncatedOpenCapture = false
    private(set) var droppedHandoffCount = 0
    private var pendingHandoffs = 0

    init(
        policy: VoiceSharingPolicy,
        membership: @escaping () -> VoiceSharingEnrollmentStore.State = { VoiceSharingEnrollmentStore.shared.currentState },
        epochProvider: @escaping () -> String? = { VoiceSharingEnrollmentStore.shared.activeEnrollmentEpoch },
        sink: @escaping (SegmentEvent) -> Void = { _ in }
    ) {
        self.policy = policy
        self.membership = membership
        self.epochProvider = epochProvider
        self.sink = sink
    }

    // MARK: - Gate

    /// The gate, re-read at EVERY decision. Cached permission is exactly what the spec forbids: "clients apply
    /// updated policy before admitting another segment or starting another upload."
    ///
    /// Must be called WITHOUT `lock` held: `policy.permitsCollection` takes the policy's own lock, and holding
    /// ours across it would fix a lock order between two independently-locked objects for no benefit. So every
    /// public method reads the capture state under the lock, releases it, then consults the gate.
    private func mayCollectNow() -> Bool {
        guard policy.permitsCollection else { return false }
        let state = membership()
        // Unknown membership (no projection accepted this session) is NOT permission. Stale likewise.
        guard state.hasAuthoritativeProjection, state.effectiveEnrolled else { return false }
        // Records key on a server-issued epoch; without one there is nothing to scope the capture to.
        guard let epoch = epochProvider(), !epoch.isEmpty else { return false }
        return true
    }

    // MARK: - Pipeline signals

    /// Confirmed speech start. Assigns `capture_id` here — before bleed/wake outcomes exist — or opens
    /// nothing when the gate is closed.
    func speechStarted(confirmationFrameSamples: Int) {
        // Gate first, outside our lock; then take a fresh capture only if it permits.
        guard mayCollectNow() else {
            lock.lock()
            openCapture = nil
            retainedForOpenCapture = 0
            truncatedOpenCapture = false
            lock.unlock()
            return
        }
        let id = UUID()
        lock.lock()
        openCapture = id
        retainedForOpenCapture = confirmationFrameSamples
        truncatedOpenCapture = false
        lock.unlock()
        emit(.init(kind: .started, captureID: id, retainedSamples: confirmationFrameSamples, truncated: false))
    }

    /// In-progress accumulation. Enforces the ceiling HERE, so overshoot is bounded even if completion never
    /// comes.
    func speechAccumulated(retainedSampleCount: Int) {
        // Read the open capture under the lock, decide the gate outside it.
        lock.lock()
        let id = openCapture
        retainedForOpenCapture = retainedSampleCount
        let overCeiling = retainedSampleCount > Self.maxSamplesPerContribution
        if overCeiling && !truncatedOpenCapture { truncatedOpenCapture = true }
        let truncated = truncatedOpenCapture
        lock.unlock()

        guard let id else { return }
        guard mayCollectNow() else {
            // The gate closed mid-speech: abandon the partial rather than carry it to completion.
            lock.lock()
            openCapture = nil
            truncatedOpenCapture = false
            lock.unlock()
            return
        }
        if overCeiling {
            emit(.init(kind: .accumulated, captureID: id, retainedSamples: retainedSampleCount, truncated: truncated))
        }
    }

    /// Natural end of a segment: finalize what was retained, marked truncated if the ceiling was hit.
    func speechCompleted(_ samples: [Float]) {
        lock.lock()
        let id = openCapture
        let truncated = truncatedOpenCapture
        openCapture = nil
        retainedForOpenCapture = 0
        truncatedOpenCapture = false
        lock.unlock()
        guard let id, mayCollectNow() else { return }
        emit(.init(kind: .completed, captureID: id, retainedSamples: samples.count, truncated: truncated))
    }

    /// Permission or listening context closed mid-speech. The partial is discarded, never emitted, and no
    /// already-completed contribution is touched (spec: closing listening is not implicit withdrawal).
    func speechCancelled() {
        lock.lock()
        let id = openCapture
        openCapture = nil
        retainedForOpenCapture = 0
        truncatedOpenCapture = false
        lock.unlock()
        guard let id else { return }
        emit(.init(kind: .cancelled, captureID: id, retainedSamples: 0, truncated: false))
    }

    /// Rejection branches are collectable. Notified from the observation points added in
    /// `VoiceAsrEngine.processUtterance`; they must not change any recognition outcome.
    func segmentRejectedBleed(samples: Int) { noteRejection(.rejectedBleed, samples: samples) }
    func segmentRejectedWake(samples: Int) { noteRejection(.rejectedWake, samples: samples) }

    private func noteRejection(_ kind: SegmentEvent.Kind, samples: Int) {
        lock.lock()
        let id = openCapture
        let truncated = truncatedOpenCapture
        openCapture = nil
        retainedForOpenCapture = 0
        truncatedOpenCapture = false
        lock.unlock()
        guard let id, mayCollectNow() else { return }
        emit(.init(kind: kind, captureID: id, retainedSamples: samples, truncated: truncated))
    }

    /// Bounded handoff. Full mailbox drops contribution work and increments a counter; recognition is never
    /// blocked by a saturated collector.
    private func emit(_ event: SegmentEvent) {
        lock.lock()
        if pendingHandoffs >= Self.maxPendingHandoffs {
            droppedHandoffCount += 1
            lock.unlock()
            return
        }
        pendingHandoffs += 1
        lock.unlock()
        sink(event)
        lock.lock()
        pendingHandoffs -= 1
        lock.unlock()
    }
}
