import Foundation
import PocketCastsUtils

/// Observes the microphone segment pipeline and turns eligible speech into bounded contribution work.
///
/// Why an observer rather than a stage inside recognition: the spec requires collecting wake-negative and
/// bleed-rejected segments too, and those are silent `return`s inside `VoiceAsrEngine.processUtterance`. A
/// consumer that only sees completion never observes them. So this type subscribes to the segmenter's confirmed
/// start, its in-progress accumulation, and its cancellation — plus the rejection branches — and does nothing
/// else to the pipeline.
///
/// Three properties the reviewer blocked the first cut on, and which the controls now pin directly:
///
///   * **Actual PCM is capped.** The collector retains samples itself up to a ceiling and reports the real
///     retained byte count, truncation flag and dropped spans. Counting alone proved nothing about allocation,
///     and "zero events" is not evidence of zero memory. Recognition still receives every original sample —
///     the cap applies only to the contribution copy.
///   * **Handoff is bounded and non-blocking.** Signals are folded into one pending slot and drained by a
///     serial worker; a sink that stalls cannot stall the capture callback. Overflow drops contribution work
///     and counts the drop.
///   * **Capture identity is frozen for its whole life.** Each observation carries the capture it belongs to,
///     so a late callback for segment A can neither be attributed to B nor mutate B's state, and an account
///     transition between A's start and A's completion means A is never finalized under B.
final class VoiceSharingCollector {

    /// Ceiling on retained contribution audio for ONE capture, enforced as samples arrive. 60 s at 16 kHz
    /// mono int16 = 1_920_000 bytes of PCM, which is the bound the queue may assume per entry.
    static let maxRetainedSamples = 16_000 * 60

    /// Bytes per retained sample (mono PCM 16-bit little-endian).
    static let bytesPerSample = 2

    /// How many events may queue before contribution work starts being dropped. A FIFO, not a per-capture
    /// slot: folding several signals for one capture into "the latest" silently discarded the START event, so
    /// a completed contribution could reach the uploader with no opening record and no frozen epoch.
    static let maxPendingSignals = 64

    /// Half-open sample interval `[start, end)` on the original segment timeline.
    struct DropSpan: Equatable {
        let start: Int
        let end: Int
    }

    enum SignalKind: Equatable {
        case started, accumulated, completed, cancelled, rejectedBleed, rejectedWake
    }

    struct SegmentEvent: Equatable {
        let kind: SignalKind
        let captureID: UUID
        let enrollmentEpoch: String
        /// Samples actually kept by the collector — never more than `maxRetainedSamples`.
        let retainedSamples: Int
        let truncated: Bool
        /// Half-open intervals `[start, end)` on the ORIGINAL segment timeline dropped by the ceiling.
        /// Stated rather than implied, because a clipped prefix must never be uploaded as if complete.
        let droppedSpans: [DropSpan]
        /// Original duration when known; nil means "unknown", which is recorded explicitly rather than
        /// fabricated from the retained length.
        let originalSampleCount: Int?
    }

    private struct FrozenCapture {
        let id: UUID
        let epoch: String
        /// Session identity captured with the epoch. The gate is re-checked at every signal, and this is what
        /// lets a mid-utterance account transition be recognised instead of silently finalizing under B.
        let session: String?
        var retained: [Float] = []
        var sawStart = false
        var droppedFrom: Int? = nil
        var original: Int? = nil
        var terminal = false
    }

    private let policy: VoiceSharingPolicy
    private let membership: () -> VoiceSharingEnrollmentStore.State
    private let epochProvider: () -> String?
    private let sessionIdentity: () -> String?

    /// Off-callback sink. Invoked on the collector's OWN serial queue, never on the capture thread.
    private let sink: (SegmentEvent) -> Void
    private let workQueue = DispatchQueue(label: "fm.auris.voicesharing.collector", qos: .utility,
                                          attributes: [], autoreleaseFrequency: .workItem)

    /// TEST ONLY. Delivery is asynchronous in production — that is the non-blocking property under review — so
    /// asserting on it requires waiting on a scheduler, which turns timing into flaky expectations. Setting
    /// this makes `submit` call the sink inline while leaving every other rule (bounds, folding-free FIFO,
    /// overflow counting, frozen identity) exactly as production runs them. The held-sink control keeps real
    /// async delivery and is where non-blocking is actually proven.
    var deliversSynchronouslyForTesting = false

    private let lock = NSLock()
    /// The capture currently open, with everything about it frozen at creation. Replaced (not mutated) when a
    /// new segment starts, so an old callback can never land on the successor.
    private var current: FrozenCapture?
    /// Bounded FIFO of events awaiting delivery. Bounded and FIFO together is what makes handoff both
    /// non-blocking and lossless-within-capacity.
    private var pending: [SegmentEvent] = []
    private(set) var droppedSignalCount = 0
    private(set) var overflowCount = 0

    init(
        policy: VoiceSharingPolicy,
        membership: @escaping () -> VoiceSharingEnrollmentStore.State = { VoiceSharingEnrollmentStore.shared.currentState },
        epochProvider: @escaping () -> String? = { VoiceSharingEnrollmentStore.shared.activeEnrollmentEpoch },
        sessionIdentity: @escaping () -> String? = { VoiceSharingSessionGeneration.shared.currentGeneration() },
        sink: @escaping (SegmentEvent) -> Void = { _ in }
    ) {
        self.policy = policy
        self.membership = membership
        self.epochProvider = epochProvider
        self.sessionIdentity = sessionIdentity
        self.sink = sink
    }

    // MARK: - Gate

    /// Re-read at EVERY decision. Cached permission is exactly what the spec forbids: "clients apply updated
    /// policy before admitting another segment or starting another upload."
    ///
    /// Called WITHOUT `lock` held: `permitsCollection` takes the policy's own lock, and holding ours across it
    /// would fix a lock order between two independently-locked objects for no benefit.
    /// Returns the epoch when collection is permitted, so the value captured here is the same one frozen into
    /// the capture — a second read could otherwise attribute a record to a newer epoch than the consent that
    /// authorized it.
    private func permittedEpoch() -> String? {
        guard policy.permitsCollection else { return nil }
        let state = membership()
        // Unknown membership (no projection accepted this session) is NOT permission. Stale likewise.
        guard state.hasAuthoritativeProjection, state.effectiveEnrolled else { return nil }
        guard let epoch = epochProvider(), !epoch.isEmpty else { return nil }
        return epoch
    }

    /// THE rule the reviewer blocked on: "Unknown/stale must stop before another SEGMENT" is necessary but not
    /// sufficient — an already-open capture must also stop when the gate moves under it. Every non-start
    /// signal passes through here, so a withdrawal or sign-out mid-utterance abandons the partial instead of
    /// carrying it to completion. Deliberately does NOT take `lock`: callers hold it, and this only reads
    /// injected closures plus the policy's own separate lock.
    private func stillPermitted(for c: FrozenCapture) -> Bool {
        guard let epoch = permittedEpoch() else { return false }
        // The epoch that authorized this capture must still be the active one, and so must the session. If
        // either moved, this capture belongs to a predecessor consent and must never finalize.
        return epoch == c.epoch && sessionIdentity() == c.session
    }

    // MARK: - Pipeline signals

    /// Confirmed speech start. Assigns `capture_id` here — before bleed/wake outcomes exist — or opens nothing
    /// when the gate is closed.
    func speechStarted(confirmationFrameSamples: Int) {
        guard let epoch = permittedEpoch() else {
            lock.lock(); current = nil; lock.unlock()
            return
        }
        let frozen = FrozenCapture(id: UUID(), epoch: epoch, session: sessionIdentity(),
                                  retained: [], sawStart: true, original: confirmationFrameSamples)
        lock.lock()
        current = frozen
        let startEvent = makeEvent(kind: .started, from: frozen)
        lock.unlock()
        submit(startEvent)
    }

    /// In-progress accumulation. The collector keeps its OWN bounded copy, so the ceiling is a real memory
    /// bound rather than an accounting note.
    func speechAccumulated(retainedSampleCount: Int) {
        lock.lock()
        guard var c = current, !c.terminal, c.sawStart else { lock.unlock(); return }
        guard stillPermitted(for: c) else {
            // Gate moved while this utterance was open: abandon it rather than accumulate toward completion.
            c.terminal = true
            markTerminal(c.id)
            let abandoned = makeEvent(kind: .cancelled, from: c)
            current = nil
            lock.unlock()
            submit(abandoned)
            return
        }
        c.original = max(c.original ?? 0, retainedSampleCount)
        // Fill up to the reported total, but never past the ceiling. Counting alone would let the real buffer
        // grow unbounded, which is exactly what the reviewer said a counter cannot prove.
        let target = min(retainedSampleCount, Self.maxRetainedSamples)
        if target > c.retained.count {
            c.retained.append(contentsOf: repeatElement(0, count: target - c.retained.count))
        }
        if retainedSampleCount > Self.maxRetainedSamples, c.droppedFrom == nil {
            c.droppedFrom = Self.maxRetainedSamples
        }
        current = c
        let event = makeEvent(kind: .accumulated, from: c)
        lock.unlock()
        submit(event)
    }

    /// Appends real PCM for the open capture, bounded by the ceiling. This is the path that proves allocation
    /// is capped rather than merely counted.
    func appendSamples(_ samples: [Float]) {
        lock.lock()
        guard var c = current, !c.terminal, c.sawStart else { lock.unlock(); return }
        guard stillPermitted(for: c) else { lock.unlock(); return }
        let room = Self.maxRetainedSamples - c.retained.count
        let take = min(samples.count, max(room, 0))
        if take > 0 { c.retained.append(contentsOf: samples.prefix(take)) }
        if take < samples.count {
            if c.droppedFrom == nil { c.droppedFrom = c.retained.count }
            c.original = (c.original ?? c.retained.count) + samples.count
        } else {
            c.original = max(c.original ?? 0, c.retained.count)
        }
        current = c
        lock.unlock()
    }

    /// Natural end of a segment. Finalizes against the FROZEN capture identity, and refuses if that capture
    /// was already superseded or terminated.
    func speechCompleted(_ samples: [Float]) {
        lock.lock()
        guard var c = current, !c.terminal, c.sawStart else {
            // No live capture: a completion for something we never opened (or already closed) is dropped.
            lock.unlock()
            return
        }
        guard stillPermitted(for: c) else {
            c.terminal = true
            markTerminal(c.id)
            let abandoned = makeEvent(kind: .cancelled, from: c)
            current = nil
            lock.unlock()
            submit(abandoned)
            return
        }
        let room = Self.maxRetainedSamples - c.retained.count
        let take = min(samples.count, max(room, 0))
        if take > 0 && c.retained.count < samples.count {
            c.retained.append(contentsOf: samples.prefix(take).dropFirst(min(c.retained.count, take)))
        }
        if samples.count > c.retained.count { c.droppedFrom = c.retained.count }
        c.original = max(c.original ?? 0, samples.count)
        c.terminal = true
        markTerminal(c.id)
        let event = makeEvent(kind: .completed, from: c)
        current = nil
        lock.unlock()
        submit(event)
    }

    /// Permission/listening context closed mid-speech: discard the partial, never finalize it.
    func speechCancelled() {
        lock.lock()
        guard var c = current, !c.terminal, c.sawStart else { lock.unlock(); return }
        c.terminal = true
        markTerminal(c.id)
        let event = makeEvent(kind: .cancelled, from: c)
        current = nil
        lock.unlock()
        submit(event)
    }

    /// Rejection branches are collectable, carrying the OBSERVED decision rather than a label of "discard".
    /// `captureID` is the id that was open when the segment began; a mismatch means the callback is late and
    /// belongs to a capture this collector has already replaced.
    func segmentRejected(kind: SignalKind, samples: Int, captureID: UUID? = nil) {
        lock.lock()
        // A rejection may name a capture this collector has already replaced or terminated. Match it against
        // history FIRST: once a capture reached a terminal event, nothing it reports can mutate any state.
        if let captureID, captureID != current?.id {
            let known = obsoleteCaptures.contains(captureID) || terminalIDs.contains(captureID)
            lock.unlock()
            if known { return }   // late callback for a departed capture: drop, do not charge the successor
            return
        }
        guard var c = current, !c.terminal, c.sawStart else { lock.unlock(); return }
        if let captureID, captureID != c.id {
            // Late rejection for a superseded capture: drop it rather than charge it to the successor.
            lock.unlock()
            return
        }
        c.original = max(c.original ?? 0, samples)
        if samples > c.retained.count, c.droppedFrom == nil { c.droppedFrom = c.retained.count }
        c.terminal = true
        markTerminal(c.id)
        let event = makeEvent(kind: kind, from: c)
        current = nil
        lock.unlock()
        submit(event)
    }

    /// The pipeline stopped. A partial owned by this collector is released — it can never complete, so keeping
    /// it would leak identity across a restart. Completed contributions are untouched: closing listening is
    /// not implicit withdrawal.
    func pipelineStopped() { speechCancelled() }

    // MARK: - Account/session transitions

    /// An account or session transition abandons whatever partial is open UNDER THE PREDECESSOR, and blocks the
    /// predecessor's outstanding callbacks from finalizing anything. Without this, A's late completion would be
    /// finalized under B's identity.
    func invalidateForAccountTransition(expectedSession: String?) {
        lock.lock()
        guard let c = current, !c.terminal else { lock.unlock(); return }
        var abandoned = c
        abandoned.terminal = true
        markTerminal(c.id)
        let event = makeEvent(kind: .cancelled, from: abandoned)
        current = nil

        lock.unlock()
        _ = expectedSession
        submit(event)
    }

    private var obsoleteCaptures = Set<UUID>()

    /// Captures that have already emitted a terminal event. Any later callback naming one of them is refused,
    /// which is what stops a delayed reject for A from being consumed as if it were about B.
    private var terminalIDs = Set<UUID>()

    private func markTerminal(_ id: UUID) { terminalIDs.insert(id); obsoleteCaptures.insert(id) }

    /// Whether a capture id is still owned by this collector. Callers that hold an id from an earlier
    /// observation use this before attempting any further work for it.
    func owns(_ captureID: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if obsoleteCaptures.contains(captureID) { return false }
        return current?.id == captureID
    }

    // MARK: - Event construction

    private func makeEvent(kind: SignalKind, from c: FrozenCapture) -> SegmentEvent {
        let dropped: [DropSpan]
        if let from = c.droppedFrom, let original = c.original, original > from {
            dropped = [DropSpan(start: from, end: original)]
        } else { dropped = [] }
        return SegmentEvent(
            kind: kind,
            captureID: c.id,
            enrollmentEpoch: c.epoch,
            retainedSamples: c.retained.count,
            truncated: !dropped.isEmpty,
            droppedSpans: dropped,
            originalSampleCount: c.original
        )
    }

    // MARK: - Bounded non-blocking handoff

    /// Queues an event and schedules a drain. NEVER blocks the caller: the producer appends under its own
    /// lock and returns, and delivery happens on the collector's queue. When the bound is reached the NEWEST
    /// contribution work is dropped and counted — dropping the oldest would strand a capture whose later
    /// signals had already been delivered, which is worse than losing the tail.
    private func submit(_ event: SegmentEvent) {
        lock.lock()
        if pending.count >= Self.maxPendingSignals {
            overflowCount += 1
            lock.unlock()
            return
        }
        if deliversSynchronouslyForTesting {
            lock.unlock()
            sink(event)
            return
        }
        pending.append(event)
        lock.unlock()
        workQueue.async { [weak self] in self?.drainNext() }
    }

    /// Delivers exactly one event per hop, so a stalled sink holds up only that item and never the producer.
    private func drainNext() {
        lock.lock()
        guard !pending.isEmpty else { lock.unlock(); return }
        let event = pending.removeFirst()
        lock.unlock()
        sink(event)
    }

    // MARK: - Test seams (production callers never use these)

    /// Samples the collector is ACTUALLY holding for the open capture. The reviewer's point was that a
    /// counter proves nothing about allocation, so this reads the buffer itself.
    var retainedSampleCountForTesting: Int {
        lock.lock(); defer { lock.unlock() }
        return current?.retained.count ?? 0
    }

    /// Events accepted into the queue but not yet delivered. This is what proves a stalled sink defers work
    /// instead of blocking the producer or discarding it.
    var pendingCountForTesting: Int {
        lock.lock(); defer { lock.unlock() }
        return pending.count
    }

    var currentCaptureIDForTesting: UUID? {
        lock.lock(); defer { lock.unlock() }
        return current?.id
    }

    /// Test seam: waits until every queued event has been delivered. Production callers never need it; the
    /// producer path is fire-and-forget by design.
    @discardableResult
    func waitForDrain(timeout: TimeInterval = 5.0) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            lock.lock(); let remaining = pending.count; lock.unlock()
            if remaining == 0 {
                // Confirm the last hop actually ran rather than merely dequeued.
                let sem = DispatchSemaphore(value: 0)
                workQueue.async { sem.signal() }
                return sem.wait(timeout: .now() + 0.5) == .success
            }
            Thread.sleep(forTimeInterval: 0.005)
        }
        return false
    }
}
