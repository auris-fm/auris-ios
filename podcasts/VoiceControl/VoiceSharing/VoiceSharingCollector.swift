import Foundation
import PocketCastsServer
import PocketCastsUtils

/// Observes the microphone segment pipeline and turns eligible speech into bounded contribution work.
///
/// Why an observer rather than a stage inside recognition: the spec requires collecting wake-negative and
/// bleed-rejected segments too, and those are silent `return`s inside `VoiceAsrEngine.processUtterance`. A
/// consumer that only sees completion never observes them. So this type subscribes to the segmenter's
/// confirmed start (with the confirming frame's real PCM), its in-progress accumulation (real new PCM per
/// call), and its cancellation — plus the rejection branches — and does nothing else to the pipeline.
///
/// The four properties reviewers pinned, and which the controls name directly:
///
/// * **Actual PCM is capped.** The collector appends the REAL samples the segmenter produced (byte-for-byte
/// slices, not counts or placeholders) into its own buffer up to a ceiling, and reports the real retained
/// count, truncation and dropped spans. In memory a Float sample is 4 bytes.
/// * **Association is by argument.** The engine freezes an immutable `CaptureContext` at utterance-launch
/// and every outcome carries it. A successor starting first cannot adopt a predecessor's callback, and
/// "whatever is current inside the collector" is never consulted for matching.
/// * **Handoff is bounded and non-blocking**, and queued work is INVALIDATED at dequeue: an event whose
/// epoch or authorizing session died while waiting in the FIFO never reaches the sink.
/// * **All retained identity state is bounded**: open capture (≤1), FIFO (≤ maxPendingSignals), and the
/// refusal sets (pruned to a floor once they exceed maxTerminalHistoryIDs).
final class VoiceSharingCollector {

    /// Ceiling on retained contribution audio for ONE capture, enforced as samples arrive. 60 s at 16 kHz.
    /// This is a compiled ceiling, not an approved activation value — activation limits stay an owner decision.
    static let maxRetainedSamples = 16_000 * 60

    /// In-memory cost per retained sample (mono Float = 4 bytes). Any int16 conversion at queue time is the
    /// queue's concern and is not claimed here.
    static let bytesPerInMemorySample = 4

    /// Events may queue before contribution work starts being dropped. FIFO, not fold-per-capture: folding
    /// silently discarded the START event, so a completed contribution could reach the uploader with no
    /// opening record and no frozen epoch.
    static let maxPendingSignals = 64
    /// Test seam: the FIFO cap controls assert boundedness against.
    static var pendingSignalCapForTesting: Int { maxPendingSignals }

    /// Refusal-set ceiling. These sets answer one question — "is this callback for a capture I already
    /// finished?" — only for captures recent enough that a late delivery is plausible. Events are delivered
    /// per hop, so anything older than the live window cannot still be in flight; prune to half once exceeded.
    static let maxTerminalHistoryIDs = 512


    /// Half-open sample interval `[start, end)` on the original segment timeline.
    struct DropSpan: Equatable {
        let start: Int
        let end: Int
    }

    enum SignalKind: Equatable {
        case started, completed, cancelled, rejectedBleed, rejectedWake
    }

    /// The enumerated ASR reason stating an observed bleed decision skipped recognition.
    /// Defined HERE because this is the site that actually made the decision.
    static let bleedSkipReason = "rejected_by_bleed"

    /// The enumerated ASR reason stating an observed wake decision skipped recognition.
    static let wakeSkipReason = "rejected_by_wake"

    /// The reason for a stage the pipeline never dispatched: a rejected wake word stops the turn
    /// before routing and execution are reached. Naming it is a fact the app OWNS, so these stages are
    /// `not_run` rather than `unknown` — they did not fail to be observed, they did not happen.
    static let notDispatchedReason = "not_dispatched"

    /// The enumerated routing reason stating the wake-positive trim left no text, so there was
    /// nothing to route (the session-start capture). Routing and execution were both skipped by
    /// the same decision, so both stages carry it.
    static let wakeOnlySkipReason = "wake_only"

    /// Immutable association token handed to the engine at confirmed start and REQUIRED on every later
    /// outcome for that segment. Association by argument, not by "whatever is current": utterance B starting
    /// before A's rejection arrives cannot make A's callback land on B, because A's Task holds A's context
    /// and the collector matches it explicitly.
    struct CaptureContext: Equatable {
        let id: UUID
        let epoch: String
        let session: String?
    }

    struct SegmentEvent: Equatable {
        let kind: SignalKind
        let captureID: UUID
        let enrollmentEpoch: String
        /// PHASE 2 (name schema v1): the grace state frozen at segment start — carried on the record
        /// as the required `wake_required` field. Captured once at capture open; never inferred.
        /// Defaults to `true` so synthetic/test events state the default mode explicitly.
        var wakeRequired: Bool = true
        /// Session that authorized this record, frozen with the epoch. Queued events are checked against the
        /// LIVE session at dequeue; a mismatch means the account moved while this event waited, and the sink
        /// never sees it.
        var authorizationSession: String?
        /// Samples actually kept by the collector — never more than `maxRetainedSamples`.
        let retainedSamples: Int
        let truncated: Bool
        let droppedSpans: [DropSpan]
        /// Original duration when known; nil means "unknown", recorded explicitly rather than fabricated.
        let originalSampleCount: Int?
        /// The retained contribution audio itself, delivered WITH the event. A handoff that carries counts
        /// and forces the uploader to come back for bytes is a second channel to keep consistent; the audio
        /// rides with the record that describes it.
        let audio: [Float]
        /// True for gate-control records (e.g. the cancellation synthesized by gate loss). These BYPASS the
        /// live dequeue check: their whole purpose is to report that consent ended, so gating them on the
        /// (now-closed) gate would drop the evidence of the drop.
        let isGateControl: Bool
        /// What the ENGINE actually reported while this capture was open: the stage
        /// observations carried on the event, so downstream claims describe observations that really
        /// happened rather than claims a caller supplied. Empty for legacy/gate-control events.
        var reportedStages: [String: VoiceSharingContributionEncoder.StageOutcome] = [:]
        var outcomeWaitExpired = false
        /// A collector event freezes actual invocation identities, including explicit unknown slots.
        var reportedModels: VoiceSharingContributionEncoder.Models? = nil
        var metadataByteCeiling = VoiceSharingContributionEncoder.maximumMetadataBytes
    }

    /// Validated scheduling input, not an activation default. Missing limits close admission.
    struct OutcomeWaitLimit {
        let nanoseconds: Int

        init?(milliseconds: Int, ceilingMilliseconds: Int? = nil) {
            guard let ceilingMilliseconds, ceilingMilliseconds > 0,
                  ceilingMilliseconds <= Int.max / 1_000_000,
                  milliseconds > 0, milliseconds <= ceilingMilliseconds else { return nil }
            nanoseconds = milliseconds * 1_000_000
        }
    }

    private struct OutcomeDeadline {
        let time: DispatchTime
        let work: DispatchWorkItem
    }

    private var outcomeDeadlines: [UUID: OutcomeDeadline] = [:]
    private let outcomeWaitLimit: OutcomeWaitLimit?

    /// FIXED annotation deadline: a segment released to the engine must eventually
    /// finalize even when a downstream stage never reports. This is an ordinary default, not an
    /// admission gate — its ABSENCE no longer refuses collection.
    static let defaultOutcomeWaitLimit = OutcomeWaitLimit(
        milliseconds: 20_000, ceilingMilliseconds: 60_000)
    private let monotonicNow: () -> DispatchTime
    private let scheduleOutcome: (DispatchTime, DispatchWorkItem) -> Void

    private struct FrozenCapture {
        let id: UUID
        /// Stage observations the engine reported for THIS capture, accumulated as its signals arrive.
        var reportedStages: [String: VoiceSharingContributionEncoder.StageOutcome] = [:]
        let epoch: String
        let session: String?
        var modelReferences: [String: VoiceSharingContributionEncoder.ModelRef] = [:]
        var observedModelSlots: Set<String> = []
        var conflictingModelSlots: Set<String> = []
        var clipSampleCeiling = VoiceSharingCollector.maxRetainedSamples
        var metadataByteCeiling = VoiceSharingContributionEncoder.maximumMetadataBytes
        var retained: [Float] = []
        var sawStart = false
        var droppedFrom: Int? = nil
        var original: Int? = nil
        var terminal = false
        /// Held until the engine finalizes the capture (downstream ASR/translation/routing complete).
        /// Without this, the record is emitted at segmentation time and can never carry a downstream stage.
        /// OPT-IN: a consumer that emits directly (and never finalizes) keeps the immediate behaviour.
        var deferEmissionUntilFinalized = false
        /// PHASE 2 (name schema v1): the REAL grace state when this segment started — true means a wake
        /// word was required for the speech to be heard; false means grace was active and speech was
        /// heard without one. Set once at capture open; never inferred later.
        var wakeRequired = true
    }

    /// ONE consent gate: the user's sharing choice under the ordinary session.
    /// The policy snapshot no longer gates capture; the server re-checks enrollment at accept.
    private let isCollectionPermitted: () -> Bool
    private let membership: () -> VoiceSharingEnrollmentStore.State
    private let epochProvider: () -> String?
    private let sessionIdentity: () -> String?

    /// Off-callback sink. Invoked on the collector's OWN serial queue, never on the capture thread.
    private let sink: (SegmentEvent) -> Void
    private let workQueue = DispatchQueue(label: "fm.auris.voicesharing.collector", qos: .utility,
                                          attributes: [], autoreleaseFrequency: .workItem)

    private let lock = NSLock()
    /// Monotonic stamp for ring entry order (see `TerminalRecord.deferredOrder`).
    private var terminalSequence: UInt64 = 0
    /// The capture currently open, with everything about it frozen at creation. Replaced (not mutated) when a
    /// new segment starts, so an old callback can never land on the successor.
    private var current: FrozenCapture?
    /// Bounded FIFO of events awaiting delivery.
    private var pending: [SegmentEvent] = []
    /// Captures that have emitted a terminal event, and the same information as the wider refusal set. Any
    /// later callback naming one is refused. Bounded: see `pruneTerminalHistoryIfNeeded`.
    private var terminalIDs = Set<UUID>()
    private var obsoleteCaptures = Set<UUID>()
    private(set) var overflowCount = 0

    /// HIGH-WATER marks. Retiring the in-process FIFO and sample budget as DROPPING
    /// gates removed the only bound on retained in-memory work, so the exposure has to be visible
    /// on a device rather than inferred. These record the PEAK fifo depth and the PEAK retained
    /// bytes and log ONE content-free line each time a new peak is reached — not per event, so the
    /// signal stays cheap and a log reader can see exactly how high pressure actually got.
    private(set) var peakPendingSignals = 0
    /// / incident: SEGMENTS seen vs CAPTURES emitted, counted from the
    /// collector's own decisions. The simulator stopped turning utterances into captures at
    /// 10:00:21Z with no log line naming a decision, so the numbers had to be inferred from
    /// absence — which is exactly the evidence that could not be produced afterwards. These two
    /// counters are content-free and let a later report say "N segments seen, M captures emitted"
    /// without reconstructing anything.
    private(set) var segmentsSeenCount = 0
    private(set) var capturesEmittedCount = 0

    /// Emits the running counters, rate-limited so a stuck gate cannot flood the log (which itself
    /// changes the behaviour under investigation): at most one line per interval, plus whenever the
    /// counts change by at least `decisionReportEvery` in between.
    private var lastDecisionReportAt: DispatchTime?
    private static let decisionReportInterval: TimeInterval = 300
    private static let decisionReportEvery = 10

    /// `logDecisionProgressLocked` for callers that do not already hold the lock.
    private func logDecisionProgress(force: Bool = false) {
        lock.lock()
        logDecisionProgressLocked(force: force)
        lock.unlock()
    }

    /// Content-free progress line for the capture path. Logged from the collector's own decisions:
    /// the fixed vocabulary names counters, never values from the audio or metadata.
    private func logDecisionProgressLocked(force: Bool = false) {
        let now = monotonicNow()
        if !force, let last = lastDecisionReportAt {
            let elapsed = Double(now.uptimeNanoseconds &- last.uptimeNanoseconds) / 1_000_000_000
            // Report early when enough decisions accumulated since the last line, so a long run
            // of refusals is visible without waiting the full interval.
            let decisionsSince = (segmentsSeenCount + capturesEmittedCount) - decisionsAtLastReport
            if elapsed < Self.decisionReportInterval && decisionsSince < Self.decisionReportEvery {
                return
            }
        }
        lastDecisionReportAt = now
        decisionsAtLastReport = segmentsSeenCount + capturesEmittedCount
        FileLog.shared.addMessage(
            "[VoiceSharing] capture decisions segments=\(segmentsSeenCount) "
                + "captures=\(capturesEmittedCount) overflow=\(overflowCount) "
                + "ring_drops=\(ringDropCount)")
    }
    /// Logs the peak FIFO depth and peak retained bytes when either sets a new high.
    /// Called with `lock` HELD, at the two enqueue points, so the peaks are exact rather than
    /// sampled. Content-free: counts only, no audio and no capture identifiers beyond the count.
    private func recordHighWaterLocked(capture: UUID) {
        let depth = pending.count
        var advanced = false
        if depth > peakPendingSignals { peakPendingSignals = depth; advanced = true }
        guard advanced else { return }
        // ONE line per NEW peak. `retained` is in samples so the floor on device memory is
        // `samples * 2` bytes (pcm_s16le), which is what an operator compares against a budget.
        FileLog.shared.addMessage(
            "[VoiceSharing] handoff high-water peak_fifo=\(peakPendingSignals) "
                + "capture=\(capture.uuidString)")
    }

    /// Decision count as of the last progress line (rate-limit bookkeeping only).
    private var decisionsAtLastReport = 0

    /// TEST only. Delivery is asynchronous in production — that is the non-blocking property under review —
    /// so content assertions use inline delivery instead of racing a scheduler. The held-sink and
    /// thread-identity controls keep real async delivery; that is where non-blocking is actually proven.
    var deliversSynchronouslyForTesting = false

    init(
        isCollectionPermitted: @escaping () -> Bool = {
            // THE one consent decision, shared with upload.
            ServerSettings.userId != nil
                && VoiceSharingEnrollmentStore.shared.consentAllowsCollection
        },
        outcomeWaitLimit: OutcomeWaitLimit? = VoiceSharingCollector.defaultOutcomeWaitLimit,
        monotonicNow: @escaping () -> DispatchTime = DispatchTime.now,
        scheduleOutcome: @escaping (DispatchTime, DispatchWorkItem) -> Void = {
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: $0, execute: $1)
        },
        membership: @escaping () -> VoiceSharingEnrollmentStore.State = { VoiceSharingEnrollmentStore.shared.currentState },
        // PROVENANCE, not permission: this epoch is stamped on the record the
        // account already holds. Gating it on `activeEnrollmentEpoch` made a cold-started app
        // unable to OPEN a capture until a projection round trip landed in this process.
        // Explicit opt-out and withdrawal still answer nil, so those stop capture immediately.
        epochProvider: @escaping () -> String? = {
            VoiceSharingEnrollmentStore.shared.persistedEnrollmentEpochForProvenance
        },
        sessionIdentity: @escaping () -> String? = { VoiceSharingEnrollmentStore.currentSessionOwner() },
        sink: @escaping (SegmentEvent) -> Void = { _ in }
    ) {
        self.outcomeWaitLimit = outcomeWaitLimit
        self.monotonicNow = monotonicNow
        self.scheduleOutcome = scheduleOutcome
        self.isCollectionPermitted = isCollectionPermitted
        self.membership = membership
        self.epochProvider = epochProvider
        self.sessionIdentity = sessionIdentity
        self.sink = sink
    }

    deinit {
        for deadline in outcomeDeadlines.values { deadline.work.cancel() }
    }

    // MARK: - Gate

    /// Re-read at every decision. Cached permission is exactly what the spec forbids.
    /// Called WITHOUT `lock` held.
    ///
    /// CONSENT is the only admission decision. The retired readiness gates are gone:
    /// a missing `outcomeWaitLimit` no longer refuses admission (the timeout is a fixed annotation
    /// deadline), and a missing enrollment epoch no longer refuses it either (the epoch is stamped on
    /// the record as PROVENANCE, never consulted to decide whether audio may be kept).
    private func collectionPermitted() -> Bool {
        isCollectionPermitted()
    }

    /// The gate rule that stops an ALREADY-OPEN capture: "Unknown/stale must stop before another SEGMENT" is
    /// necessary but not sufficient — an open partial must also stop when the gate moves under it. Every
    /// non-start signal passes through here. Does not take `lock`; callers hold it.
    /// The epoch frozen into the capture is not compared here: a re-enrollment moves the server's
    /// opaque epoch without invalidating what this account already captured. What
    /// must still hold is the ACCOUNT and the user's live consent.
    private func stillPermitted(for c: FrozenCapture) -> Bool {
        guard collectionPermitted() else { return false }
        return sessionIdentity() == c.session
    }

    // MARK: - Pipeline signals

    /// Confirmed speech start. Assigns `capture_id` here and returns the immutable context the engine must
    /// freeze into its utterance Task — or opens nothing (returns nil) when the gate is closed.
    @discardableResult
    func speechStarted(confirmationFrameSamples: Int, wakeRequired: Bool = true) -> CaptureContext? {
        lock.lock()
        segmentsSeenCount += 1
        logDecisionProgressLocked()
        lock.unlock()
        guard collectionPermitted() else {
            // Capture-side refusal names its own reason: "did the collector
            // decline" and "was the utterance unbuildable" are different decisions and must not
            // look the same. Fixed vocabulary, no values.
            FileLog.shared.addMessage("[VoiceSharing] capture refused reason=collection-not-permitted")
            // The seen-vs-emitted counters travel WITH the decision: a refusal alone says nothing
            // about whether the pipeline was otherwise healthy.
            logDecisionProgress(force: true)
            FileLog.shared.forceFlush()
            abandonForGateMove(context: currentCaptureContext())
            return nil
        }
        let session = sessionIdentity()
        // PROVENANCE with no placeholder: every record must carry the
        // real epoch the account holds at capture time. When no epoch is available there is nothing
        // truthful to stamp, so the capture is not opened — ordinary record construction fails rather
        // than writing an unsupported value the server refuses. This is not a readiness lifecycle: it
        // is the same "cannot build a valid record" condition as any other.
        guard let epoch = epochProvider(), !epoch.isEmpty else {
            FileLog.shared.addMessage("[VoiceSharing] capture refused reason=no-enrollment-epoch")
            logDecisionProgress(force: true)
            abandonForGateMove(context: currentCaptureContext())
            return nil
        }
        let stamp = VoiceSharingCaptureStamp(session: session, epoch: epoch, policyGeneration: 0)
        // No capture allowance is requested before retaining audio ("Actual upload
        // usage"): daily quota is metered from ACTUAL accepted bytes at the server, so there is
        // nothing to acquire here and nothing that can refuse local retention. The clip and
        // metadata ceilings are the compiled bounds, applied unconditionally.
        var frozen = FrozenCapture(id: UUID(), epoch: epoch, session: session,
                                   retained: [], sawStart: true, original: confirmationFrameSamples)
        frozen.clipSampleCeiling = Self.maxRetainedSamples
        frozen.metadataByteCeiling = VoiceSharingContributionEncoder.maximumMetadataBytes
        frozen.wakeRequired = wakeRequired
        lock.lock()
        guard stillPermitted(for: frozen) else {
            lock.unlock()
            return nil
        }
        // The segmenter owns one capture at a time, so a confirmed start while a partial still lingers
        // means the partial can never complete. Record it (bounded ring + cancellation record) instead of
        // silently overwriting it — a silent overwrite would strand its audio with no terminal record.
        var staleEvent: SegmentEvent?
        if let stale = current, !stale.terminal {
            var abandoned = stale
            abandoned.terminal = true
            current = nil
            markTerminal(abandoned, discarded: true)
            staleEvent = makeEvent(kind: .cancelled, from: abandoned)
        }
        current = frozen
        let startEvent = makeEvent(kind: .started, from: frozen)
        let context = CaptureContext(id: frozen.id, epoch: epoch, session: frozen.session)
        lock.unlock()
        if let staleEvent { submit(staleEvent) }
        submit(startEvent)
        return context
    }

    /// SYNCHRONOUS segmentation endpoint, called by the engine's onUtterance closure before it creates
    /// the outcome Task: the segmenter has finished THIS segment, so its audio is frozen and detached
    /// HERE — before any successor can start and before any await. Without this, a completed capture
    /// still sitting in `current` would be turned into an audio-carrying cancel by B's start, and the
    /// late outcome would emit a SECOND record. Emits NO event: the accept/reject decision arrives
    /// later via the frozen context and emits exactly once from the ring.
    func segmentationEnded(_ context: CaptureContext?) {
        lock.lock()
        guard let context, let c = current, c.id == context.id, !c.terminal else {
            lock.unlock()
            return
        }
        var done = c
        done.terminal = true
        // A SEGMENT that ended has downstream stages still to run.
        // The engine reaches this path from `segmenter.onUtterance`, i.e. before ASR, translation and
        // routing. Publishing here would emit a record that can never carry them, so the capture
        // stays ring-resident and the engine releases it via `finalizeDeferredCompletion`. Without
        // this stamp every real-engine capture is finalized into nothing and no durable record is
        // ever written.
        done.deferEmissionUntilFinalized = true
        current = nil
        markTerminal(done)
        let deadline = registerOutcomeDeadlineLocked(for: done.id)
        lock.unlock()
        if let deadline { scheduleOutcome(deadline.time, deadline.work) }
    }

    /// The context of the capture currently open, for the engine to freeze into its utterance Task. Nil when
    /// nothing is open — a later completion then carries nil and is refused, which is correct: an utterance
    /// with no confirmed start has nothing to attach to.
    func currentCaptureContext() -> CaptureContext? {
        lock.lock(); defer { lock.unlock() }
        guard let c = current else { return nil }
        return CaptureContext(id: c.id, epoch: c.epoch, session: c.session)
    }

    /// Test seam: same value production reads. Named separately so a test passing a STALE context
    /// deliberately does not reach for the live one by accident.
    var currentCaptureContextForTesting: CaptureContext? { currentCaptureContext() }

    /// Pointer metadata only; nil in production. Detects an accidental pre-admission PCM copy.
    var borrowedSampleAddressForTesting: ((UInt?) -> Void)?

    /// Appends the REAL pcm the segmenter just produced. `samples` is authoritative; `reportedTotal` only
    /// documents the segmenter's buffer size so the original duration can be stated.
    func appendSamples<Samples: Collection>(_ samples: Samples, reportedTotal: Int? = nil) where Samples.Element == Float {
        if let probe = borrowedSampleAddressForTesting {
            _ = samples.withContiguousStorageIfAvailable { buffer in
                probe(buffer.baseAddress.map { UInt(bitPattern: $0) })
            }
        }
        lock.lock()
        guard var c = current, !c.terminal, c.sawStart else { lock.unlock(); return }
        guard stillPermitted(for: c) else { lock.unlock(); return }
        // Release the `current` reference while mutating: with both `current` and `c` holding the array,
        // every append would trigger a copy-on-write of the WHOLE buffer (O(n²) per segment). With `c`
        // uniquely owned, `append` writes in place. Restored before unlock.
        current = nil
        // The per-capture ceiling is the only bound on growth here: admission is decided by the
        // record count in the queue, not by a running total of bytes this object happens to hold.
        let perCaptureRoom = c.clipSampleCeiling - c.retained.count
        let take = min(samples.count, max(perCaptureRoom, 0))
        if take > 0 { c.retained.append(contentsOf: samples.prefix(take)) }
        c.original = max(c.original ?? 0, reportedTotal ?? c.retained.count)
        if take < samples.count, c.droppedFrom == nil {
            c.droppedFrom = c.retained.count
        }
        current = c
        lock.unlock()
    }

    /// Called by the actual loaded component immediately before invocation. Unknown or conflicting
    /// instances cannot be represented as one known version. Matching uses the capture argument only.
    func engineUsedModel(slot: String, reference: VoiceSharingContributionEncoder.ModelRef?, context: CaptureContext?) {
        guard ["vad", "wakeword", "asr", "translation", "router"].contains(slot), let context else { return }
        lock.lock()
        defer { lock.unlock() }
        func record(_ capture: inout FrozenCapture) {
            guard !capture.conflictingModelSlots.contains(slot) else { return }
            if capture.observedModelSlots.contains(slot), capture.modelReferences[slot] != reference {
                capture.modelReferences.removeValue(forKey: slot)
                capture.conflictingModelSlots.insert(slot)
            } else {
                capture.observedModelSlots.insert(slot)
                capture.modelReferences[slot] = reference
            }
        }
        if var capture = current, capture.id == context.id, !capture.terminal {
            record(&capture)
            current = capture
        } else if var entry = terminalRing[context.id] {
            record(&entry.capture)
            terminalRing[context.id] = entry
        }
    }

    /// The ENGINE's own report about a stage it actually evaluated for this capture.
    /// Only the caller that made the decision may report it: receiving frames does not establish a wake
    /// detection, so `appendSamples` must never infer one. A nil `context` means no capture was open and
    /// the report is dropped rather than attached to a successor.
    func engineReported(
        stage: String, outcome: VoiceSharingContributionEncoder.StageOutcome,
        context: CaptureContext?, decision: String? = nil
    ) {
        var outcome = outcome
        if let decision { outcome = outcome.withDecision(decision) }
        // SERVER schema: every OBSERVED execution carries the
        // wire's outcome, in the schema's own enum — not routing's disposition tokens. The mapping
        // is applied HERE so every execution producer gets it by construction; a producer that
        // already stated an outcome keeps its stated value, and an unobserved execution (unknown,
        // or not_run for a reason that is not a refusal) maps to nil and states nothing.
        if stage == "execution", outcome.outcome == nil {
            outcome = outcome.withWireOutcome(
                VoiceSharingContributionEncoder.StageOutcome.wireExecutionOutcome(for: outcome))
        }
        lock.lock()
        defer { lock.unlock() }
        guard let context else { return }
        // The engine's decision can land after segmentation ended but before the completion event is
        // emitted (a late outcome re-emits from the ring). Record it wherever the capture currently
        // lives — open, or ring-resident and not yet emitted — so the record that eventually leaves
        // carries it. A capture already emitted cannot be amended: its record is immutable, which is
        // the point of the digest.
        // A stage can be reported MORE than once (e.g. routing at classification time, then again at
        // settlement with its terminal disposition). But a GENERIC carry-forward is unsafe across
        // state changes: a completed report would inherit a previous reason, and
        // an empty_result would inherit previous text/router_input — contradictions or schema
        // refusals. Nil cannot always mean preserve. So: only routing's classification facts
        // (predicted names and disposition) are intentionally retained for settlement; every other
        // member comes from the new report alone, and a nil CLEARS.
        func merged(_ previous: VoiceSharingContributionEncoder.StageOutcome?,
                    stage: String
        ) -> VoiceSharingContributionEncoder.StageOutcome {
            guard let previous else { return outcome }
            if stage == "routing",
               // Retention is constrained to the intended classification→settlement transition
               // . The only INCOMPATIBLE settlement is not_run: the router
               // declined, so nothing was classified and carrying names would invent a
               // classification that never happened. failed still concerns the classified action
               // (its control/78480a17, asserts a failed turn NAMES its
               // classification), and pending means the classification stands unconcluded.
               VoiceSharingContributionEncoder
                   .routingDispositionCarriesClassification(outcome.routingDisposition) {
                return .init(
                    state: outcome.state,
                    reason: outcome.reason,
                    text: outcome.text,
                    decision: outcome.decision,
                    translatedText: outcome.translatedText,
                    targetLanguage: outcome.targetLanguage,
                    routingDisposition: outcome.routingDisposition,
                    sourceLanguage: outcome.sourceLanguage,
                    routerInput: outcome.routerInput,
                    predictedIntent: outcome.predictedIntent ?? previous.predictedIntent,
                    predictedTool: outcome.predictedTool ?? previous.predictedTool,
                    outcome: outcome.outcome)
            }
            return outcome
        }
        if var c = current, c.id == context.id, !c.terminal, c.sawStart {
            c.reportedStages[stage] = merged(c.reportedStages[stage], stage: stage)
            current = c
            return
        }
        if var rec = terminalRing[context.id] {
            rec.capture.reportedStages[stage] = merged(rec.capture.reportedStages[stage], stage: stage)
            terminalRing[context.id] = rec
        }
    }

    /// Completion matched against the CONTEXT the engine captured, not current state. A nil/unknown context
    /// (no capture was open when the utterance Task launched) refuses outright.
    func speechCompleted(_ samples: [Float], context: CaptureContext?, deferEmission: Bool = false) {
        if let context, deferEmission {
            lock.lock()
            if var rec = terminalRing[context.id] {
                rec.capture.deferEmissionUntilFinalized = true
                terminalRing[context.id] = rec
            }
            if var c = current, c.id == context.id, !c.terminal {
                c.deferEmissionUntilFinalized = true
                current = c
            }
            lock.unlock()
        }
        if emitLateOutcomeIfTerminal(kind: .completed, context: context) { return }
        // A late outcome that CANNOT be emitted yet (downstream stages still to come) leaves the capture
        // ring-resident; the engine finalizes it. Nothing else may be refused by falling through.
        lock.lock()
        guard var c = resolve(context) else { lock.unlock(); return }
        guard !c.terminal, c.sawStart else { lock.unlock(); return }
        guard stillPermitted(for: c) else {
            lock.unlock()
            abandonForGateMove(context: context)
            return
        }
        // FINALIZE only. Every sample of the segment was already delivered by the segmenter's deltas —
        // the confirmation prefix plus one delta per later call. Appending the utterance again would
        // duplicate (and, with an in-flight successor, reorder) the audio. `samples` is used solely to
        // state the original duration.
        c.original = max(c.original ?? 0, samples.count)
        c.terminal = true
        current = nil                       // detach A's completed audio ownership HERE, synchronously,
                                            // before any successor can start; the ring entry and the
                                            // event share it via COW from this point
        markTerminal(c)                     // ring re-registers the (immutable, completed) capture
        if c.deferEmissionUntilFinalized {
            // DOWNSTREAM stages still run: ASR/translation/routing
            // decisions happen after the segment closes, so emitting here would publish a record that can
            // never carry them. The capture stays ring-resident until the engine finalizes it.
            let deadline = registerOutcomeDeadlineLocked(for: c.id)
            lock.unlock()
            if let deadline { scheduleOutcome(deadline.time, deadline.work) }
            return
        }
        releaseEmittedLocked(c.id)
        let event = makeEvent(kind: .completed, from: c)
        lock.unlock()
        submit(event)
    }

    /// The engine's downstream work for this capture is finished. Emit the completion now, carrying every
    /// observation the engine reported in the meantime. A capture that is not ring-resident (already
    /// emitted, or never completed) is a no-op, so a double finalize cannot publish twice.
    func finalizeDeferredCompletion(context: CaptureContext?) {
        guard let context else { return }
        lock.lock()
        guard let rec = terminalRing[context.id] else { lock.unlock(); return }
        // MIRRORS emitLateOutcomeIfTerminal: this is the SAME promotion of a terminal
        // capture into a completed record, so it must honour every safeguard that path applies. Without
        // these checks a late finalize could resurrect a capture that was genuinely cancelled or withdrawn,
        // after a gate/identity move it no longer belongs to, or one that was never a deferred completion.
        guard rec.capture.deferEmissionUntilFinalized else { lock.unlock(); return }
        // The ACCOUNT and live consent decide; the provenance epoch is not consulted.
        let sameConsent = (rec.capture.session == sessionIdentity())
            && isCollectionPermitted()
        guard sameConsent else { lock.unlock(); return }
        cancelOutcomeDeadlineLocked(context.id)
        terminalRing.removeValue(forKey: context.id)
        let event = makeEvent(kind: .completed, from: rec.capture)
        lock.unlock()
        submit(event)
    }

    /// Cancellation carries no context: it fires from the segmenter's own reset for whatever IT has open,
    /// which is exactly one capture by construction.
    func speechCancelled() {
        lock.lock()
        // THE owner of the cancellation is the open capture, and it is decided FIRST.
        // A deferred ring entry belongs to a segment that already closed: if a successor is open, the
        // cancellation is about the SUCCESSOR, and consuming the predecessor instead would discard the
        // wrong capture while leaving the intended one live.
        if let open = current, !open.terminal, open.sawStart {
            var c = open
            c.terminal = true
            current = nil
            markTerminal(c, discarded: true)   // a genuine cancel discards the partial FOREVER
            let event = makeEvent(kind: .cancelled, from: c)
            lock.unlock()
            submit(event)
            return
        }
        // No open capture: the cancellation is about the capture the pipeline is still awaiting a finalize
        // for. Without this a deferred capture would survive and a late finalize could
        // revive it.
        if var deferred = deferredRingEntryAwaitingCancellationLocked(preferring: nil) {
            deferred.capture = consumed(deferred.capture)
            cancelOutcomeDeadlineLocked(deferred.capture.id)
            terminalRing.removeValue(forKey: deferred.capture.id)
            lock.unlock()
            return
        }
        lock.unlock()
    }

    /// Cancellation for a NAMED capture. The engine knows which capture it froze; when it says so, that
    /// binding wins outright and no recency heuristic is consulted.
    func speechCancelled(context: CaptureContext?) {
        guard let context else { speechCancelled()
return }
        lock.lock()
        // The named capture may still be OPEN; cancel it where it lives rather than only looking in the ring.
        if let open = current, open.id == context.id, !open.terminal, open.sawStart {
            var c = open
            c.terminal = true
            current = nil
            markTerminal(c, discarded: true)
            let event = makeEvent(kind: .cancelled, from: c)
            lock.unlock()
            submit(event)
            return
        }
        guard var rec = deferredRingEntryAwaitingCancellationLocked(preferring: context) else {
            lock.unlock()
            return
        }
        rec.capture = consumed(rec.capture)
        cancelOutcomeDeadlineLocked(context.id)
        terminalRing.removeValue(forKey: rec.capture.id)
        lock.unlock()
    }

    /// The capture a cancellation is about. DICTIONARY order is not A BINDING: the ring is
    /// keyed by UUID, so iterating it picks an arbitrary deferred capture. Cancellation has two distinct
    /// meanings and both must bind deterministically:
    /// - an OPEN capture: the cancel is about `current`, exactly as before;
    /// - a captured-but-already-closed one: the engine cancels the capture whose context it froze, which
    /// is the capture it is still awaiting a finalize for.
    /// With several deferred captures the most recent one is the one the pipeline is working on, so recency
    /// — never hashing — decides. A caller with a known context names it explicitly.
    private func deferredRingEntryAwaitingCancellationLocked(preferring context: CaptureContext?) -> TerminalRecord? {
        // A NAMED context is a BINDING, not a hint. Falling through to "most recent
        // unrelated capture" when the named one is stale, already emitted, or ineligible means a
        // cancellation for a capture that no longer exists silently consumes a DIFFERENT one that was
        // never cancelled. Named lookup therefore returns its own entry or nothing at all.
        if let context {
            guard let named = terminalRing[context.id],
                named.capture.deferEmissionUntilFinalized || outcomeDeadlines[context.id] != nil else { return nil }
            return named
        }
        // Unnamed: the caller did not say which capture, so the most recent one is the best available
        // evidence. Recency is an explicit stamp, never dictionary iteration order.
        return terminalRing.values
            .filter { $0.capture.deferEmissionUntilFinalized || outcomeDeadlines[$0.capture.id] != nil }
            .max { $0.deferredOrder < $1.deferredOrder }
    }

    /// Strips audio ownership from a capture that can no longer contribute.
    private func consumed(_ c: FrozenCapture) -> FrozenCapture {
        var identityOnly = c
        cancelOutcomeDeadlineLocked(c.id)
        identityOnly.retained = []
        return identityOnly
    }

    /// Rejection resolved by CONTEXT. The engine's Task captured identity at utterance launch; this call
    /// matches that, so B starting before A's reject arrives cannot make A consume B.
    func segmentRejected(kind: SignalKind, samples: Int, context: CaptureContext?) {
        if emitLateOutcomeIfTerminal(kind: kind, context: context) { return }
        lock.lock()
        guard var c = resolve(context) else { lock.unlock(); return }
        guard !c.terminal, c.sawStart else { lock.unlock(); return }
        guard stillPermitted(for: c) else {
            lock.unlock()
            abandonForGateMove(context: context)
            return
        }
        c.original = max(c.original ?? 0, samples)
        if samples > c.retained.count, c.droppedFrom == nil { c.droppedFrom = c.retained.count }
        c.terminal = true
        // A REJECTION is itself the terminal outcome: bleed/wake rejection carries no downstream
        // stage to wait for, so it is never deferred even when the segment has already ended (which
        // stamps the deferral flag for the ordinary ASR→routing path).
        c.deferEmissionUntilFinalized = false
        current = nil
        markTerminal(c)
        releaseEmittedLocked(c.id)
        // for a bleed-rejected segment the ASR stage did not run because the engine
        // OBSERVED playback bleed and skipped it — a known skip, not an absent observation. The bleed
        // stage keeps its own observed decision from the contract enum (`overlap` here); this fact says
        // only why ASR did not run.
        let event = makeEvent(kind: kind, from: c)
        lock.unlock()
        submit(event)
    }

    /// The pipeline stopped. A partial owned by this collector is released — it can never complete. Completed
    /// contributions are untouched: closing listening is not implicit withdrawal.
    func pipelineStarting() {}

    func pipelineStopped() {
        speechCancelled()
    }

    /// Explicit gate-loss: the sharing decision stopped permitting collection, with identity UNCHANGED
    /// (so the dequeue-time epoch/session check alone would wave the queued work through). Cancels any open
    /// partial IMMEDIATELY — without waiting for the next signal — and purges every queued event: consent is
    /// gone, so nothing already in the FIFO may reach the sink either. Without this, "disable" only took
    /// effect at the next segmentation signal, and a stalled sink could hold stale work for the whole wait.
    func gateLost() {
        lock.lock()
        // WITHDRAWAL disposal. Every retained byte dies here, synchronously:
        // * queued events (each holds a full audio copy) — purged;
        // * the open partial — terminal and identity-only (a discarded partial never enters
        //   the ring), audio emptied;
        // * the terminal ring — emptied outright, so every waiting entry dies with it (no
        //   retained speech survives a withdrawal, and no dead entry blocks later recordings);
        // * the cancellation record itself is CONTENT-FREE: it states that consent ended (identity,
        // counts, truncation metadata) and carries NO audio. GATE-control events still bypass the
        // live dequeue check — their whole point is to report the loss — but they cannot carry old
        // speech, so the bypass cannot deliver withdrawn audio.
        pending.removeAll()
        // The ring is EMPTIED outright: with the shedder gone, entries left in place would
        // stay forever and after re-sign-in every new recording would be dropped as
        // "ring full of waiting records". A removed entry makes a late callback miss by
        // capture ID and be dropped — and disposal of their audio
        // falls out of the removal.
        for key in terminalRing.keys { cancelOutcomeDeadlineLocked(key) }
        terminalRing.removeAll()
        var cancelEvent: SegmentEvent?
        if var c = current, !c.terminal {
            c.terminal = true
            current = nil
            c.retained.removeAll()
            markTerminal(c, discarded: true)
            cancelEvent = makeEvent(kind: .cancelled, from: c)   // audio empty: withdrawal is content-free
        }
        lock.unlock()
        if let cancelEvent { submit(cancelEvent) }
    }

    /// An account or session transition abandons whatever partial is open UNDER the predecessor. Without this,
    /// A's late completion would be finalized under B's identity.
    func invalidateForAccountTransition(expectedSession: String?) {
        speechCancelled()
        _ = expectedSession
    }

    /// Recently-terminal captures, bounded. A late outcome (A's Task finally runs after A was cancelled and
    /// B is open) must still complete UNDER A — attributed to A's frozen identity and A's frozen audio —
    /// rather than being dropped as foreign or, worse, adopted by B. Only records WAITING for their
    /// outcome live here: an emitted entry is removed outright at its emit site, so a duplicate late
    /// outcome misses by capture ID and emits nothing.
    private struct TerminalRecord {
        var capture: FrozenCapture
        /// Monotonic order of entry into the ring, so "the capture the pipeline is working on" is a fact
        /// rather than an artifact of dictionary iteration order.
        var deferredOrder: UInt64 = 0
    }

    private var terminalRing: [UUID: TerminalRecord] = [:]

    /// An emitted record no longer occupies the ring: only records WAITING for their outcome
    /// count toward the bound. The entry is removed outright; late
    /// reports look up by capture ID, miss, and are dropped — a record is immutable once emitted.
    /// Caller holds the observation lock.
    private func releaseEmittedLocked(_ id: UUID) {
        cancelOutcomeDeadlineLocked(id)
        terminalRing.removeValue(forKey: id)
    }

    private func rememberTerminal(_ c: FrozenCapture, noContribution: Bool = false) {
        terminalSequence &+= 1
        // QUEUE-FULL RULE (spec: "when the queue is full… the new recording is
        // dropped and the drop is logged with a count"): the ring holds ONLY records waiting
        // for their outcome. A never-contributing capture (a discarded partial) never enters
        // it at all — it has nothing to wait for, so it is identity bookkeeping only; an
        // emitted record left the ring at its emit site. Nothing but waiting records is ever
        // in the ring, so `count >= 32` alone decides the drop, with no eviction loop at all.
        // Force-emission is gone for good: a record emitted before its outcome uploads with
        // every observation `unknown`, which is the fact-less upload the old pressure path
        // used to produce (the `grace_na` R2 clips).
        guard !noContribution else { return }
        if terminalRing.count >= 32 {
            // Every slot is a waiting record and this contributing capture cannot wait: drop
            // the NEW capture, counted and logged. Prefer dropping a recording over machinery
            // that would save it fact-less.
            ringDropCount += 1
            FileLog.shared.addMessage(
                "[VoiceSharing] capture dropped: ring full of waiting records "
                    + "capture=\(c.id.uuidString) drops=\(ringDropCount)")
            return
        }
        terminalRing[c.id] = TerminalRecord(
            capture: c,
            deferredOrder: terminalSequence)
    }

    /// Caller holds the observation lock. Work retains identity only, never PCM or the collector.
    private func registerOutcomeDeadlineLocked(for id: UUID) -> OutcomeDeadline? {
        guard outcomeDeadlines[id] == nil, let limit = outcomeWaitLimit,
              let record = terminalRing[id] else { return nil }
        let deadline = OutcomeDeadline(
            time: monotonicNow() + .nanoseconds(limit.nanoseconds),
            work: DispatchWorkItem { [weak self] in self?.outcomeDeadlineReached(id) })
        outcomeDeadlines[id] = deadline
        return deadline
    }

    private func cancelOutcomeDeadlineLocked(_ id: UUID) {
        outcomeDeadlines.removeValue(forKey: id)?.work.cancel()
    }

    private func outcomeDeadlineReached(_ id: UUID) {
        lock.lock()
        guard let deadline = outcomeDeadlines[id] else { lock.unlock(); return }
        // An injected scheduler may wake early; expiry is always measured by the monotonic clock.
        guard monotonicNow() >= deadline.time else {
            lock.unlock()
            scheduleOutcome(deadline.time, deadline.work)
            return
        }
        cancelOutcomeDeadlineLocked(id)
        guard var rec = terminalRing[id] else {
            lock.unlock()
            return
        }
        let allowed = stillPermitted(for: rec.capture)
        let event = makeEvent(kind: .completed, from: rec.capture)
        // The immutable event owns any deliverable PCM from here; the timer/ring release theirs.
        rec.capture = consumed(rec.capture)
        // The record leaves the ring on emission: only WAITING records occupy it.
        // A not-permitted capture keeps no audio and contributes nothing, so removal is total.
        terminalRing.removeValue(forKey: id)
        lock.unlock()
        if allowed {
            var expired = event
            expired.outcomeWaitExpired = true
            submit(expired)
        }
    }


    /// Whether a capture id is still owned by this collector.
    func owns(_ captureID: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if obsoleteCaptures.contains(captureID) { return false }
        return current?.id == captureID
    }

    // MARK: - Internals

    /// Matches an engine-captured context against the open capture — or, for a capture that already reached
    /// a terminal state while its Task was still queued, against the terminal ring so the late outcome is
    /// attributed under its OWN identity. Unknown or mismatched = refused.
    private func resolve(_ context: CaptureContext?) -> FrozenCapture? {
        guard let context else { return nil }
        if let c = current, c.id == context.id { return c }
        if let rec = terminalRing[context.id] { return rec.capture }
        return nil
    }

    /// A late outcome for an already-terminal capture: emit its record ONCE under its own identity, without
    /// touching current state. Returns true when handled.
    private func emitLateOutcomeIfTerminal(kind: SignalKind, context: CaptureContext?) -> Bool {
        lock.lock()
        guard let context, var rec = terminalRing[context.id] else {
            lock.unlock()
            return false
        }
        // Late attribution honors the CURRENT gate: if identity moved on (account transition rotated the
        // epoch) the predecessor's completion stays dropped, exactly as before. The reviewer's case — A
        // queued-not-executed while B starts under the SAME consent — is what this path exists for.
        // The ACCOUNT and live consent decide; the provenance epoch is not consulted.
        let sameConsent = (rec.capture.session == sessionIdentity())
            && isCollectionPermitted()
        guard sameConsent else { lock.unlock(); return false }
        // DEFER: the capture's downstream stages (ASR, translation,
        // routing) have not run yet. Emitting now would publish an immutable record that can never carry
        // them — the engine finalizes instead. Reported as "handled" so callers do not fall through into
        // a second emission path.
        if kind == .completed, rec.capture.deferEmissionUntilFinalized {
            lock.unlock()
            return true
        }
        cancelOutcomeDeadlineLocked(context.id)
        terminalRing.removeValue(forKey: context.id)
        let event = makeEvent(kind: kind, from: rec.capture)
        lock.unlock()
        submit(event)
        return true
    }

    private func abandonForGateMove(context: CaptureContext?) {
        lock.lock()
        guard let c = current, c.id == context?.id, !c.terminal else { lock.unlock(); return }
        var abandoned = c
        abandoned.terminal = true
        current = nil
        // Correct the transfer: the open ownership is subtracted and the ring records identity
        // only (discarded), so the move neither double-charges nor strands the partial's bytes.
        markTerminal(abandoned, discarded: true)
        let event = makeEvent(kind: .cancelled, from: abandoned)
        lock.unlock()
        submit(event)
    }

    private func markTerminal(_ c: FrozenCapture, discarded: Bool = false) {
        terminalIDs.insert(c.id)
        obsoleteCaptures.insert(c.id)
        if discarded {
            // A discarded terminal records IDENTITY only: its audio left ownership at the dispose
            // site (the caller subtracted), and the ring never holds it — there is nothing to
            // resurrect and nothing to charge the budget for.
            var identityOnly = c
            identityOnly.retained = []
            rememberTerminal(identityOnly, noContribution: true)
        } else {
            rememberTerminal(c)
        }
        pruneTerminalHistoryIfNeeded()
    }

    /// Bounded refusal history. Without a bound, a long session with thousands of segments grows these sets
    /// forever; the aggregate ceiling must cover them, not just the open buffer and FIFO.
    private func pruneTerminalHistoryIfNeeded() {
        let total = terminalIDs.count + obsoleteCaptures.count
        guard total > Self.maxTerminalHistoryIDs else { return }
        let excess = total - Self.maxTerminalHistoryIDs / 2
        for id in terminalIDs.prefix(excess) { terminalIDs.remove(id) }
        for id in obsoleteCaptures.prefix(excess) { obsoleteCaptures.remove(id) }
    }

    private func makeEvent(kind: SignalKind, from c: FrozenCapture) -> SegmentEvent {
        let dropped: [DropSpan]
        if let from = c.droppedFrom, let original = c.original, original > from {
            dropped = [DropSpan(start: from, end: original)]
        } else { dropped = [] }
        // A cancellation is a content-free DISPOSAL record in every case: a genuinely cancelled partial
        // can never become a contribution, so its record states identity + counts and carries no audio.
        let audio = kind == .cancelled ? [] : c.retained
        var event = SegmentEvent(kind: kind, captureID: c.id, enrollmentEpoch: c.epoch,
                            wakeRequired: c.wakeRequired,
                            authorizationSession: c.session, retainedSamples: c.retained.count,
                            truncated: !dropped.isEmpty, droppedSpans: dropped,
                            originalSampleCount: c.original, audio: audio,
                            isGateControl: kind == .cancelled,
                            reportedStages: c.reportedStages,
                            reportedModels: .init(vad: c.modelReferences["vad"], wakeword: c.modelReferences["wakeword"],
                                                  asr: c.modelReferences["asr"], translation: c.modelReferences["translation"],
                                                  router: c.modelReferences["router"]),
                            metadataByteCeiling: c.metadataByteCeiling)
        Self.applySkipMapping(to: &event, kind: kind)
        return event
    }

    /// Stages a rejection is KNOWN to have prevented, stated as `not_run` with a reason.
    ///
    /// A segment that fails the wake word never reaches recognition, translation, routing or the
    /// executor; a bleed rejection skips recognition alone. The app decided that, so these are facts it
    /// owns. Leaving them to the encoder's default would record `unknown` /
    /// `observation_unavailable` — the opposite claim, that the app could not tell — and would
    /// disagree with the same event recorded by the other client.
    ///
    /// Applied HERE, at the single funnel every emission path builds its event through, because the
    /// same rejection reaches the encoder by two routes: the ordinary one, and the late-outcome path
    /// for a capture already completed with deferred emission. Mapping at a call site covers only the
    /// first.
    private static func applySkipMapping(to event: inout SegmentEvent, kind: SignalKind) {
        switch kind {
        case .rejectedBleed:
            event.reportedStages["asr"] = VoiceSharingContributionEncoder.StageOutcome(
                state: "not_run", reason: bleedSkipReason)
        case .rejectedWake:
            for stage in ["asr", "translation"] {
                event.reportedStages[stage] = VoiceSharingContributionEncoder.StageOutcome(
                    state: "not_run", reason: wakeSkipReason)
            }
            for stage in ["routing", "execution"] {
                event.reportedStages[stage] = VoiceSharingContributionEncoder.StageOutcome(
                    state: "not_run", reason: notDispatchedReason)
            }
        case .started, .completed, .cancelled:
            // Nothing is known to have been skipped: these kinds either run downstream stages or
            // carry no contribution at all, and the engine reports what actually happened.
            break
        }
    }

    // MARK: - Bounded non-blocking handoff

    /// Queues an event and schedules a drain. never blocks the caller. When the bound is reached the NEWEST
    /// contribution work is dropped and counted — dropping the oldest would strand a capture whose later
    /// signals had already been delivered.
    /// The collector OWNS its coordinator gate-loss registration: the token lives exactly as long as
    /// the collector, which — not the engine — is the object a held sink or queued drain can keep
    /// alive. Releasing the engine therefore cannot unregister a collector that still owns audio;
    /// its registration purges it at the next consent loss.
    var gateLostSubscription: AnyObject?

    /// Audio bytes CURRENTLY owned inside an in-sink call: registered before the sink runs,
    /// released when it returns. Part of actual ownership for the whole sink duration.
    private func submit(_ event: SegmentEvent) {
        lock.lock()
        if deliversSynchronouslyForTesting {
            lock.unlock()
            deliverUnderSinkOwnership(event)
            return
        }
        // NO IN-PROCESS cap may discard A CAPTURE. This used to refuse the event
        // when the handoff FIFO or the retained-sample budget filled, and neither maps to an
        // allowed gate: the spec allows a recording to stop being collected when sharing is off,
        // and for no other reason. Both caps are therefore counted as pressure and logged, and the
        // capture is still queued — the durable queue's 32-record limit is the one admission gate,
        // and it is the only place allowed to refuse.
        if pending.count >= Self.maxPendingSignals {
            overflowCount += 1
            let why = "fifo-full"
            logDecisionProgressLocked(force: true)
            FileLog.shared.addMessage(
                "[VoiceSharing] handoff under pressure reason=\(why) "
                    + "capture=\(event.captureID.uuidString) retained=not-dropped")
            FileLog.shared.forceFlush()
        }
        pending.append(event)
        recordHighWaterLocked(capture: event.captureID)
        lock.unlock()
        workQueue.async { [weak self] in self?.drainNext() }
    }

    /// Delivers exactly one event per hop. Before handing an event over, re-check that its authorization is
    /// still the live one: an event produced under epoch/session A must not reach the sink after the account
    /// moved to B, even if it was queued before the transition. Withdrawal and identity change therefore
    /// invalidate QUEUED work — the queued path is the one a stalled sink makes long.
    private func drainNext() {
        lock.lock()
        guard !pending.isEmpty else { lock.unlock(); return }
        let event = pending.removeFirst()
        // Dropped HERE (before the sink) means the bytes leave the budget immediately; delivered means
        // they stay counted IN FLIGHT until the sink returns (subtract after the call below).
        // Live consent check at dequeue. The event's epoch is PROVENANCE and is not compared: an event
        // queued before a re-enrollment carries the epoch it was captured under, and the server — not
        // this hop — decides whether that epoch is still acceptable.
        // A retired record may receive the ordinary server refusal; dropping it here would be silent
        // and would strand audio the user consented to contribute.
        let stillValid = event.isGateControl
            || ((event.authorizationSession == sessionIdentity())
                && isCollectionPermitted())
        lock.unlock()
        guard stillValid else {
            lock.lock()
            // (4): this drop used to be SILENT. It names its bound so the two
            // cases are separable: the account/session moved, or consent closed behind the event.
            let why = event.authorizationSession == sessionIdentity()
                ? "consent-not-permitted" : "session-moved"
            FileLog.shared.addMessage(
                "[VoiceSharing] capture refused reason=dequeue-\(why) "
                    + "capture=\(event.captureID.uuidString)")
            lock.unlock()
            FileLog.shared.forceFlush()
            return
        }
        deliverUnderSinkOwnership(event)
    }

    /// Delivers one event with explicit in-sink ownership: counted from before the call until the
    /// sink RETURNS, then released from the ledger. This is the only place the sink is invoked.
    private func deliverUnderSinkOwnership(_ event: SegmentEvent) {
        let n = event.audio.count
        lock.lock()
        // (4) + 43f457ab finding 3: count CONTRIBUTIONS, not events. The sink
        // ignores `.started`, so counting every non-gate-control event counted one segment twice
        // (start then completion) before a single contribution existed. A COMPLETED segment and a
        // REJECTED one (wake or bleed) both reach the sink as a contribution record — a rejected
        // segment is recorded, not discarded — so both count, exactly once each. `.started` and the
        // cancellation kinds are not contributions and are not counted.
        switch event.kind {
        case .completed, .rejectedWake, .rejectedBleed:
            capturesEmittedCount += 1
            logDecisionProgressLocked()
        case .started, .cancelled:
            break
        }
        lock.unlock()
        sink(event)
        // Ownership ends when the sink RETURNS — not at enqueue.
        lock.lock()
        lock.unlock()
    }

    // MARK: - Test seams (production callers never use these)

    /// Captures a FULL ring of waiting records refused (dropped, counted, logged — never
    /// force-emitted without their facts).
    private(set) var ringDropCount = 0

    /// How many records currently WAIT for their outcome in the ring. Withdrawal must drive
    /// this to 0 even when the ring was full.
    var waitingRingCountForTesting: Int {
        lock.lock(); defer { lock.unlock() }
        return terminalRing.count
    }

    var ringDropCountForTesting: Int {
        lock.lock(); defer { lock.unlock() }
        return ringDropCount
    }

    /// Number of events currently queued in the FIFO.
    var pendingCountForTesting: Int {
        lock.lock(); defer { lock.unlock() }
        return pending.count
    }

    /// What is actually retained right now, walked from the live buffers.
    var actualRetainedAudioBreakdownForTesting: (open: Int, fifo: Int, ring: Int) {
        lock.lock(); defer { lock.unlock() }
        let openCount = current?.retained.count ?? 0
        let fifoCount = pending.reduce(0) { $0 + $1.audio.count }
        let ringCount = terminalRing.values.reduce(0) { $0 + $1.capture.retained.count }
        return (openCount, fifoCount, ringCount)
    }

    /// Samples the collector is ACTUALLY holding for the open capture — reads the buffer, not a counter.
    var retainedSampleCountForTesting: Int {
        lock.lock(); defer { lock.unlock() }
        return current?.retained.count ?? 0
    }

    /// The retained contribution audio itself — the thing the parity control compares against the
    /// segmenter's emitted buffer.
    var retainedCopyForTesting: [Float] {
        lock.lock(); defer { lock.unlock() }
        return current?.retained ?? []
    }

    var currentCaptureIDForTesting: UUID? {
        lock.lock(); defer { lock.unlock() }
        return current?.id
    }

    /// Total identity state: open capture, queued events, refusal sets. The aggregate the ceiling applies to.
    var aggregateIdentityStateForTesting: (openCaptures: Int, queuedEvents: Int, terminalHistory: Int) {
        lock.lock(); defer { lock.unlock() }
        return (current == nil ? 0 : 1, pending.count,
                terminalIDs.count + obsoleteCaptures.count + terminalRing.count)
    }

    /// Test seam: waits until every queued event has been delivered.
    @discardableResult
    func waitForDrain(timeout: TimeInterval = 5.0) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            lock.lock(); let remaining = pending.count; lock.unlock()
            if remaining == 0 {
                let sem = DispatchSemaphore(value: 0)
                workQueue.async { sem.signal() }
                return sem.wait(timeout: .now() + 0.5) == .success
            }
            Thread.sleep(forTimeInterval: 0.005)
        }
        return false
    }
}
