import Foundation
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
///   * **Actual PCM is capped.** The collector appends the REAL samples the segmenter produced (byte-for-byte
///     slices, not counts or placeholders) into its own buffer up to a ceiling, and reports the real retained
///     count, truncation and dropped spans. In memory a Float sample is 4 bytes.
///   * **Association is by argument.** The engine freezes an immutable `CaptureContext` at utterance-launch
///     and every outcome carries it. A successor starting first cannot adopt a predecessor's callback, and
///     "whatever is current inside the collector" is never consulted for matching.
///   * **Handoff is bounded and non-blocking**, and queued work is INVALIDATED at dequeue: an event whose
///     epoch or authorizing session died while waiting in the FIFO never reaches the sink.
///   * **All retained identity state is bounded**: open capture (≤1), FIFO (≤ maxPendingSignals), and the
///     refusal sets (pruned to a floor once they exceed maxTerminalHistoryIDs).
final class VoiceSharingCollector {

    /// Ceiling on retained contribution audio for ONE capture, enforced as samples arrive. 60 s at 16 kHz.
    /// This is a compiled ceiling, NOT an approved activation value — activation limits stay an owner decision.
    static let maxRetainedSamples = 16_000 * 60

    /// In-memory cost per retained sample (mono Float = 4 bytes). Any int16 conversion at queue time is the
    /// queue's concern and is NOT claimed here.
    static let bytesPerInMemorySample = 4

    /// Events may queue before contribution work starts being dropped. FIFO, not fold-per-capture: folding
    /// silently discarded the START event, so a completed contribution could reach the uploader with no
    /// opening record and no frozen epoch.
    static let maxPendingSignals = 64

    /// Refusal-set ceiling. These sets answer one question — "is this callback for a capture I already
    /// finished?" — only for captures recent enough that a late delivery is plausible. Events are delivered
    /// per hop, so anything older than the live window cannot still be in flight; prune to half once exceeded.
    static let maxTerminalHistoryIDs = 512

    /// ONE aggregate ceiling over every float the collector OWNS, across open capture, FIFO events
    /// (INCLUDING the one currently in the sink, counted until the sink call RETURNS — a release at
    /// dequeue would declare still-retained bytes free while the sink is mid-delivery), and the
    /// terminal ring — enforced, not merely documented. At the compiled ceilings this allows
    /// 4 × 960,000 samples = 3.84 M floats = **15.36 MB** (mono Float, 4 bytes): one slot for the open
    /// capture, one for ring-held late-outcome audio, two for FIFO-held event audio (which includes the
    /// one transient COW copy made when a completed capture's buffer is shared between the ring entry
    /// and its event — arrays share storage until mutated, so accounting counts each owner, not raw
    /// uniqueness). EXACT OWNERSHIP BOUNDARIES: a delivered event's bytes leave this budget when the
    /// sink returns — from that point the sink/uploader is the owner and the budget cannot see it;
    /// a dropped event's bytes leave immediately; ring-held bytes stay counted until eviction or
    /// disposal. Exceeding the ceiling drops the NEWEST contribution work (same policy as the FIFO
    /// bound) and counts the drop.
    static let maxAggregateRetainedSamples = 4 * maxRetainedSamples

    /// Half-open sample interval `[start, end)` on the original segment timeline.
    struct DropSpan: Equatable {
        let start: Int
        let end: Int
    }

    enum SignalKind: Equatable {
        case started, completed, cancelled, rejectedBleed, rejectedWake
    }

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
        /// What the ENGINE actually reported while this capture was open (review c48461e6): the stage
        /// observations carried on the event, so downstream claims describe observations that really
        /// happened rather than claims a caller supplied. Empty for legacy/gate-control events.
        var reportedStages: [String: VoiceSharingContributionEncoder.StageOutcome] = [:]
        var outcomeWaitExpired = false
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
    private let monotonicNow: () -> DispatchTime
    private let scheduleOutcome: (DispatchTime, DispatchWorkItem) -> Void

    private struct FrozenCapture {
        let id: UUID
        /// Stage observations the engine reported for THIS capture, accumulated as its signals arrive.
        var reportedStages: [String: VoiceSharingContributionEncoder.StageOutcome] = [:]
        let epoch: String
        let session: String?
        var retained: [Float] = []
        var sawStart = false
        var droppedFrom: Int? = nil
        var original: Int? = nil
        var terminal = false
        /// Held until the engine finalizes the capture (downstream ASR/translation/routing complete).
        /// Without this, the record is emitted at segmentation time and can never carry a downstream stage.
        /// OPT-IN: a consumer that emits directly (and never finalizes) keeps the immediate behaviour.
        var deferEmissionUntilFinalized = false
    }

    private let policy: VoiceSharingPolicy
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

    /// TEST ONLY. Delivery is asynchronous in production — that is the non-blocking property under review —
    /// so content assertions use inline delivery instead of racing a scheduler. The held-sink and
    /// thread-identity controls keep real async delivery; that is where non-blocking is actually proven.
    var deliversSynchronouslyForTesting = false

    init(
        policy: VoiceSharingPolicy,
        outcomeWaitLimit: OutcomeWaitLimit? = nil,
        monotonicNow: @escaping () -> DispatchTime = DispatchTime.now,
        scheduleOutcome: @escaping (DispatchTime, DispatchWorkItem) -> Void = {
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: $0, execute: $1)
        },
        membership: @escaping () -> VoiceSharingEnrollmentStore.State = { VoiceSharingEnrollmentStore.shared.currentState },
        epochProvider: @escaping () -> String? = { VoiceSharingEnrollmentStore.shared.activeEnrollmentEpoch },
        sessionIdentity: @escaping () -> String? = { VoiceSharingSessionGeneration.shared.currentGeneration() },
        sink: @escaping (SegmentEvent) -> Void = { _ in }
    ) {
        self.outcomeWaitLimit = outcomeWaitLimit
        self.monotonicNow = monotonicNow
        self.scheduleOutcome = scheduleOutcome
        self.policy = policy
        self.membership = membership
        self.epochProvider = epochProvider
        self.sessionIdentity = sessionIdentity
        self.sink = sink
    }

    deinit {
        for deadline in outcomeDeadlines.values { deadline.work.cancel() }
    }

    // MARK: - Gate

    /// Re-read at EVERY decision. Cached permission is exactly what the spec forbids.
    /// Called WITHOUT `lock` held. Returns the epoch when collection is permitted, so the value frozen into
    /// the capture is the same one that authorized it.
    private func permittedEpoch() -> String? {
        guard outcomeWaitLimit != nil, policy.permitsCollection else { return nil }
        let state = membership()
        // Unknown membership (no projection accepted this session) is NOT permission. Stale likewise.
        guard state.hasAuthoritativeProjection, state.effectiveEnrolled else { return nil }
        guard let epoch = epochProvider(), !epoch.isEmpty else { return nil }
        return epoch
    }

    /// The gate rule that stops an ALREADY-OPEN capture: "Unknown/stale must stop before another SEGMENT" is
    /// necessary but not sufficient — an open partial must also stop when the gate moves under it. Every
    /// non-start signal passes through here. Does NOT take `lock`; callers hold it.
    private func stillPermitted(for c: FrozenCapture) -> Bool {
        guard let epoch = permittedEpoch() else { return false }
        return epoch == c.epoch && sessionIdentity() == c.session
    }

    // MARK: - Pipeline signals

    /// Confirmed speech start. Assigns `capture_id` here and returns the immutable context the engine must
    /// freeze into its utterance Task — or opens nothing (returns nil) when the gate is closed.
    @discardableResult
    func speechStarted(confirmationFrameSamples: Int) -> CaptureContext? {
        guard let epoch = permittedEpoch() else {
            lock.lock(); current = nil; lock.unlock()
            return nil
        }
        let frozen = FrozenCapture(id: UUID(), epoch: epoch, session: sessionIdentity(),
                                   retained: [], sawStart: true, original: confirmationFrameSamples)
        lock.lock()
        // The segmenter owns one capture at a time, so a confirmed start while a partial still lingers
        // means the partial can never complete. Record it (bounded ring + cancellation record) instead of
        // silently overwriting it — a silent overwrite would strand its audio with no terminal record.
        var staleEvent: SegmentEvent?
        if let stale = current, !stale.terminal {
            var abandoned = stale
            abandoned.terminal = true
            current = nil
            aggregateAudioSamples -= abandoned.retained.count
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

    /// SYNCHRONOUS segmentation endpoint, called by the engine's onUtterance closure BEFORE it creates
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
        current = nil
        aggregateAudioSamples -= done.retained.count
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

    /// Appends the REAL PCM the segmenter just produced. `samples` is authoritative; `reportedTotal` only
    /// documents the segmenter's buffer size so the original duration can be stated.
    func appendSamples(_ samples: [Float], reportedTotal: Int? = nil) {
        lock.lock()
        guard var c = current, !c.terminal, c.sawStart else { lock.unlock(); return }
        guard stillPermitted(for: c) else { lock.unlock(); return }
        // Release the `current` reference while mutating: with both `current` and `c` holding the array,
        // every append would trigger a copy-on-write of the WHOLE buffer (O(n²) per segment). With `c`
        // uniquely owned, `append` writes in place. Restored before unlock.
        current = nil
        // Reserve BEFORE growth: the open capture may not push the aggregate over budget even though
        // its own per-capture cap still has room — otherwise open growth could exceed the budget and
        // wait for a later submit/evict to notice.
        let perCaptureRoom = Self.maxRetainedSamples - c.retained.count
        let aggregateRoom = Self.maxAggregateRetainedSamples - aggregateAudioSamples
        let take = min(samples.count, max(perCaptureRoom, 0), max(aggregateRoom, 0))
        if take > 0 { c.retained.append(contentsOf: samples.prefix(take)) }
        c.original = max(c.original ?? 0, reportedTotal ?? c.retained.count)
        if take < samples.count, c.droppedFrom == nil {
            c.droppedFrom = c.retained.count
        }
        aggregateAudioSamples += take
        current = c
        lock.unlock()
    }

    /// The ENGINE's own report about a stage it actually evaluated for this capture (review bc692f91).
    /// Only the caller that made the decision may report it: receiving frames does NOT establish a wake
    /// detection, so `appendSamples` must never infer one. A nil `context` means no capture was open and
    /// the report is dropped rather than attached to a successor.
    func engineReported(
        stage: String, outcome: VoiceSharingContributionEncoder.StageOutcome,
        context: CaptureContext?, decision: String? = nil
    ) {
        var outcome = outcome
        if let decision { outcome = outcome.withDecision(decision) }
        lock.lock()
        defer { lock.unlock() }
        guard let context else { return }
        // The engine's decision can land AFTER segmentation ended but BEFORE the completion event is
        // emitted (a late outcome re-emits from the ring). Record it wherever the capture currently
        // lives — open, or ring-resident and not yet emitted — so the record that eventually leaves
        // carries it. A capture already emitted cannot be amended: its record is immutable, which is
        // the point of the digest.
        // A stage can be reported MORE THAN ONCE (e.g. routing at classification time, then again at
        // settlement with its terminal disposition). But a GENERIC carry-forward is unsafe across
        // state changes (review 5f42fb0c): a completed report would inherit a previous reason, and
        // an empty_result would inherit previous text/router_input — contradictions or schema
        // refusals. Nil cannot always mean preserve. So: ONLY routing's classification facts
        // (predicted names and disposition) are intentionally retained for settlement; every other
        // member comes from the new report alone, and a nil CLEARS.
        func merged(_ previous: VoiceSharingContributionEncoder.StageOutcome?,
                    stage: String
        ) -> VoiceSharingContributionEncoder.StageOutcome {
            guard let previous else { return outcome }
            if stage == "routing",
               // Retention is constrained to the intended classification→settlement transition
               // (review 83e0177b). The only INCOMPATIBLE settlement is not_run: the router
               // declined, so nothing was classified and carrying names would invent a
               // classification that never happened. failed still concerns the classified action
               // (its control, spec 012b19dd/78480a17, asserts a failed turn NAMES its
               // classification), and pending means the classification stands unconcluded.
               VoiceSharingRecordBinding
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
        if var rec = terminalRing[context.id], !rec.emitted, !rec.noContribution {
            rec.capture.reportedStages[stage] = merged(rec.capture.reportedStages[stage], stage: stage)
            terminalRing[context.id] = rec
        }
    }

    /// Completion matched against the CONTEXT THE ENGINE CAPTURED, not current state. A nil/unknown context
    /// (no capture was open when the utterance Task launched) refuses outright.
    func speechCompleted(_ samples: [Float], context: CaptureContext?, deferEmission: Bool = false) {
        if let context, deferEmission {
            lock.lock()
            if var rec = terminalRing[context.id], !rec.emitted, !rec.noContribution {
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
        // FINALIZE ONLY. Every sample of the segment was already delivered by the segmenter's deltas —
        // the confirmation prefix plus one delta per later call. Appending the utterance again would
        // duplicate (and, with an in-flight successor, reorder) the audio. `samples` is used solely to
        // state the original duration.
        c.original = max(c.original ?? 0, samples.count)
        c.terminal = true
        current = nil                       // detach A's completed audio ownership HERE, synchronously,
                                            // before any successor can start; the ring entry and the
                                            // event share it via COW from this point
        aggregateAudioSamples -= c.retained.count
        markTerminal(c)                     // ring re-registers the (immutable, completed) capture
        if c.deferEmissionUntilFinalized {
            // DOWNSTREAM STAGES STILL RUN (spec 2dcf8c5b, review 6fe6d773): ASR/translation/routing
            // decisions happen AFTER the segment closes, so emitting here would publish a record that can
            // never carry them. The capture stays ring-resident until the engine finalizes it.
            let deadline = registerOutcomeDeadlineLocked(for: c.id)
            lock.unlock()
            if let deadline { scheduleOutcome(deadline.time, deadline.work) }
            return
        }
        terminalRing[c.id]?.emitted = true
        cancelOutcomeDeadlineLocked(c.id)
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
        guard var rec = terminalRing[context.id], !rec.emitted else { lock.unlock(); return }
        // MIRRORS emitLateOutcomeIfTerminal (review 859dac4c): this is the SAME promotion of a terminal
        // capture into a completed record, so it must honour every safeguard that path applies. Without
        // these checks a late finalize could resurrect a capture that was genuinely cancelled or withdrawn,
        // after a gate/identity move it no longer belongs to, or one that was never a deferred completion.
        guard rec.capture.deferEmissionUntilFinalized else { lock.unlock(); return }
        if rec.noContribution {
            // A capture that can never contribute is CONSUMED, never resurrected.
            cancelOutcomeDeadlineLocked(context.id)
            rec.emitted = true
            terminalRing[context.id] = rec
            lock.unlock()
            return
        }
        let sameConsent = (rec.capture.epoch == epochProvider())
            && (rec.capture.session == sessionIdentity())
            && policy.permitsCollection
            && membership().effectiveEnrolled
        guard sameConsent else { lock.unlock(); return }
        cancelOutcomeDeadlineLocked(context.id)
        rec.emitted = true
        terminalRing[context.id] = rec
        let event = makeEvent(kind: .completed, from: rec.capture)
        lock.unlock()
        submit(event)
    }

    /// Cancellation carries no context: it fires from the segmenter's own reset for whatever IT has open,
    /// which is exactly one capture by construction.
    func speechCancelled() {
        lock.lock()
        // THE OWNER OF THE CANCELLATION IS THE OPEN CAPTURE, and it is decided FIRST (review d3c39ae5).
        // A deferred ring entry belongs to a segment that already closed: if a successor is open, the
        // cancellation is about the SUCCESSOR, and consuming the predecessor instead would discard the
        // wrong capture while leaving the intended one live.
        if let open = current, !open.terminal, open.sawStart {
            var c = open
            c.terminal = true
            current = nil
            aggregateAudioSamples -= c.retained.count
            markTerminal(c, discarded: true)   // a genuine cancel discards the partial FOREVER
            let event = makeEvent(kind: .cancelled, from: c)
            lock.unlock()
            submit(event)
            return
        }
        // No open capture: the cancellation is about the capture the pipeline is still awaiting a finalize
        // for (spec 2dcf8c5b). Without this a deferred capture would survive and a late finalize could
        // revive it (review 859dac4c).
        if var deferred = deferredRingEntryAwaitingCancellationLocked(preferring: nil) {
            deferred.capture = consumed(deferred.capture)
            cancelOutcomeDeadlineLocked(deferred.capture.id)
            deferred.emitted = true
            deferred.noContribution = true
            terminalRing[deferred.capture.id] = deferred
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
            aggregateAudioSamples -= c.retained.count
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
        rec.emitted = true
        rec.noContribution = true
        terminalRing[rec.capture.id] = rec
        lock.unlock()
    }

    /// The capture a cancellation is about. DICTIONARY ORDER IS NOT A BINDING (review 15900665): the ring is
    /// keyed by UUID, so iterating it picks an arbitrary deferred capture. Cancellation has two distinct
    /// meanings and both must bind deterministically:
    ///   - an OPEN capture: the cancel is about `current`, exactly as before;
    ///   - a captured-but-already-closed one: the engine cancels the capture whose context it froze, which
    ///     is the capture it is still awaiting a finalize for.
    /// With several deferred captures the most recent one is the one the pipeline is working on, so recency
    /// — never hashing — decides. A caller with a known context names it explicitly.
    private func deferredRingEntryAwaitingCancellationLocked(preferring context: CaptureContext?) -> TerminalRecord? {
        // A NAMED context is a BINDING, not a hint (review bb404153). Falling through to "most recent
        // unrelated capture" when the named one is stale, already emitted, or ineligible means a
        // cancellation for a capture that no longer exists silently consumes a DIFFERENT one that was
        // never cancelled. Named lookup therefore returns its own entry or nothing at all.
        if let context {
            guard let named = terminalRing[context.id],
                named.capture.deferEmissionUntilFinalized || outcomeDeadlines[context.id] != nil, !named.emitted else { return nil }
            return named
        }
        // Unnamed: the caller did not say which capture, so the most recent one is the best available
        // evidence. Recency is an explicit stamp, never dictionary iteration order.
        return terminalRing.values
            .filter { ($0.capture.deferEmissionUntilFinalized || outcomeDeadlines[$0.capture.id] != nil) && !$0.emitted }
            .max { $0.deferredOrder < $1.deferredOrder }
    }

    /// Strips audio ownership from a capture that can no longer contribute.
    private func consumed(_ c: FrozenCapture) -> FrozenCapture {
        var identityOnly = c
        cancelOutcomeDeadlineLocked(c.id)
        aggregateAudioSamples -= identityOnly.retained.count
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
        current = nil
        aggregateAudioSamples -= c.retained.count
        markTerminal(c)
        terminalRing[c.id]?.emitted = true
        cancelOutcomeDeadlineLocked(c.id)
        let event = makeEvent(kind: kind, from: c)
        lock.unlock()
        submit(event)
    }

    /// The pipeline stopped. A partial owned by this collector is released — it can never complete. Completed
    /// contributions are untouched: closing listening is not implicit withdrawal.
    func pipelineStopped() { speechCancelled() }

    /// Explicit gate-loss: remote switch off, lease expired, or permission withdrawn, with identity UNCHANGED
    /// (so the dequeue-time epoch/session check alone would wave the queued work through). Cancels any open
    /// partial IMMEDIATELY — without waiting for the next signal — and purges every queued event: consent is
    /// gone, so nothing already in the FIFO may reach the sink either. Without this, "disable" only took
    /// effect at the next segmentation signal, and a stalled sink could hold stale work for the whole wait.
    func gateLost() {
        lock.lock()
        // WITHDRAWAL DISPOSAL. Every retained byte dies here, synchronously:
        //   * queued events (each holds a full audio copy) — purged;
        //   * the open partial — terminal, ring-remembered for identity only, audio emptied;
        //   * terminal-ring history — audio emptied (no retained speech survives a withdrawal);
        //   * the cancellation record itself is CONTENT-FREE: it states that consent ended (identity,
        //     counts, truncation metadata) and carries NO audio. GATE-control events still bypass the
        //     live dequeue check — their whole point is to report the loss — but they cannot carry old
        //     speech, so the bypass cannot deliver withdrawn audio.
        for i in pending.indices { aggregateAudioSamples -= pending[i].audio.count }
        pending.removeAll()
        disposeRingAudio()
        for key in terminalRing.keys { terminalRing[key]?.noContribution = true }
        var cancelEvent: SegmentEvent?
        if var c = current, !c.terminal {
            c.terminal = true
            current = nil
            aggregateAudioSamples -= c.retained.count
            c.retained.removeAll()
            markTerminal(c, discarded: true)
            cancelEvent = makeEvent(kind: .cancelled, from: c)   // audio empty: withdrawal is content-free
        }
        lock.unlock()
        if let cancelEvent { submit(cancelEvent) }
    }

    /// An account or session transition abandons whatever partial is open UNDER THE PREDECESSOR. Without this,
    /// A's late completion would be finalized under B's identity.
    func invalidateForAccountTransition(expectedSession: String?) {
        speechCancelled()
        _ = expectedSession
    }

    /// Recently-terminal captures, bounded. A late outcome (A's Task finally runs after A was cancelled and
    /// B is open) must still complete UNDER A — attributed to A's frozen identity and A's frozen audio —
    /// rather than being dropped as foreign or, worse, adopted by B. Each entry records whether its terminal
    /// record was already emitted, so a duplicate late outcome emits nothing.
    private struct TerminalRecord {
        var capture: FrozenCapture
        var emitted: Bool
        /// A capture that can never become a contribution — genuinely cancelled partials AND
        /// consent-revoked (gate-loss) captures — is remembered for identity bookkeeping only. Its
        /// late outcomes are CONSUMED silently: never resurrected as deliverable records, never
        /// emitted twice.
        var noContribution: Bool = false
        /// Monotonic order of entry into the ring, so "the capture the pipeline is working on" is a fact
        /// rather than an artifact of dictionary iteration order.
        var deferredOrder: UInt64 = 0
    }

    private var terminalRing: [UUID: TerminalRecord] = [:]

    /// Live count of audio floats the collector owns right now (open + FIFO + ring). Mutated only under
    /// `lock`. Enforced against `maxAggregateRetainedSamples` at every growth point.
    private var aggregateAudioSamples = 0

    private func rememberTerminal(_ c: FrozenCapture, noContribution: Bool = false) {
        aggregateAudioSamples += c.retained.count
        terminalSequence &+= 1
        terminalRing[c.id] = TerminalRecord(
            capture: c, emitted: false, noContribution: noContribution,
            deferredOrder: terminalSequence)
        while terminalRing.count > 32 || aggregateAudioSamples > Self.maxAggregateRetainedSamples {
            guard let oldest = terminalRing.first else { break }
            aggregateAudioSamples -= oldest.value.capture.retained.count
            cancelOutcomeDeadlineLocked(oldest.key)
            terminalRing.removeValue(forKey: oldest.key)
        }
    }

    /// Caller holds the observation lock. Work retains identity only, never PCM or the collector.
    private func registerOutcomeDeadlineLocked(for id: UUID) -> OutcomeDeadline? {
        guard outcomeDeadlines[id] == nil, let limit = outcomeWaitLimit,
              let record = terminalRing[id], !record.emitted, !record.noContribution else { return nil }
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
        guard var rec = terminalRing[id], !rec.emitted, !rec.noContribution else {
            lock.unlock()
            return
        }
        rec.emitted = true
        let allowed = stillPermitted(for: rec.capture)
        let event = makeEvent(kind: .completed, from: rec.capture)
        // The immutable event owns any deliverable PCM from here; the timer/ring release theirs.
        rec.capture = consumed(rec.capture)
        rec.noContribution = !allowed
        terminalRing[id] = rec
        lock.unlock()
        if allowed {
            var expired = event
            expired.outcomeWaitExpired = true
            submit(expired)
        }
    }

    /// Disposes ALL retained audio in the ring (withdrawal path). Identity bookkeeping stays; bytes go.
    private func disposeRingAudio() {
        for deadline in outcomeDeadlines.values { deadline.work.cancel() }
        outcomeDeadlines.removeAll()
        for key in terminalRing.keys {
            guard var rec = terminalRing[key] else { continue }
            aggregateAudioSamples -= rec.capture.retained.count
            var disposed = rec.capture
            disposed.retained.removeAll()
            rec.capture = disposed
            terminalRing[key] = rec
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
        if let rec = terminalRing[context.id], !rec.emitted { return rec.capture }
        return nil
    }

    /// A late outcome for an already-terminal capture: emit its record ONCE under its own identity, without
    /// touching current state. Returns true when handled.
    private func emitLateOutcomeIfTerminal(kind: SignalKind, context: CaptureContext?) -> Bool {
        lock.lock()
        guard let context, var rec = terminalRing[context.id], !rec.emitted else {
            lock.unlock()
            return false
        }
        // A capture that can never contribute (genuine cancel, withdrawal) is consumed, never
        // resurrected: no late callback may turn it back into a deliverable record.
        if rec.noContribution {
            cancelOutcomeDeadlineLocked(context.id)
            rec.emitted = true
            terminalRing[context.id] = rec
            lock.unlock()
            return true
        }
        // Late attribution honors the CURRENT gate: if identity moved on (account transition rotated the
        // epoch) the predecessor's completion stays dropped, exactly as before. The reviewer's case — A
        // queued-not-executed while B starts under the SAME consent — is what this path exists for.
        let sameConsent = (rec.capture.epoch == epochProvider())
            && (rec.capture.session == sessionIdentity())
            && policy.permitsCollection
            && membership().effectiveEnrolled
        guard sameConsent else { lock.unlock(); return false }
        // DEFER (spec 2dcf8c5b, review 6fe6d773): the capture's downstream stages (ASR, translation,
        // routing) have not run yet. Emitting now would publish an immutable record that can never carry
        // them — the engine finalizes instead. Reported as "handled" so callers do not fall through into
        // a second emission path.
        if kind == .completed, rec.capture.deferEmissionUntilFinalized {
            lock.unlock()
            return true
        }
        cancelOutcomeDeadlineLocked(context.id)
        rec.emitted = true
        terminalRing[context.id] = rec
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
        // ONLY (discarded), so the move neither double-charges nor strands the partial's bytes.
        aggregateAudioSamples -= c.retained.count
        markTerminal(abandoned, discarded: true)
        let event = makeEvent(kind: .cancelled, from: abandoned)
        lock.unlock()
        submit(event)
    }

    private func markTerminal(_ c: FrozenCapture, discarded: Bool = false) {
        terminalIDs.insert(c.id)
        obsoleteCaptures.insert(c.id)
        if discarded {
            // A discarded terminal records IDENTITY ONLY: its audio left ownership at the dispose
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
        return SegmentEvent(kind: kind, captureID: c.id, enrollmentEpoch: c.epoch,
                            authorizationSession: c.session, retainedSamples: c.retained.count,
                            truncated: !dropped.isEmpty, droppedSpans: dropped,
                            originalSampleCount: c.original, audio: audio,
                            isGateControl: kind == .cancelled,
                            reportedStages: c.reportedStages)
    }

    // MARK: - Bounded non-blocking handoff

    /// Queues an event and schedules a drain. NEVER blocks the caller. When the bound is reached the NEWEST
    /// contribution work is dropped and counted — dropping the oldest would strand a capture whose later
    /// signals had already been delivered.
    /// The collector OWNS its coordinator gate-loss registration: the token lives exactly as long as
    /// the collector, which — not the engine — is the object a held sink or queued drain can keep
    /// alive. Releasing the engine therefore cannot unregister a collector that still owns audio;
    /// its registration purges it at the next consent loss.
    var gateLostSubscription: AnyObject?

    /// Audio bytes CURRENTLY owned inside an in-sink call: registered before the sink runs,
    /// released when it returns. Part of actual ownership for the whole sink duration.
    private var inFlightSinkAudioSamples = 0

    private func submit(_ event: SegmentEvent) {
        lock.lock()
        if deliversSynchronouslyForTesting {
            aggregateAudioSamples += event.audio.count
            lock.unlock()
            deliverUnderSinkOwnership(event)
            return
        }
        if pending.count >= Self.maxPendingSignals
            || aggregateAudioSamples + event.audio.count > Self.maxAggregateRetainedSamples {
            overflowCount += 1
            lock.unlock()
            return
        }
        aggregateAudioSamples += event.audio.count
        pending.append(event)
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
        // Live consent check at dequeue: identity AND the policy gate. Epoch/session equality alone would
        // deliver work queued before a switch-off or lease expiry, because a disable does not change either.
        let stillValid = event.isGateControl
            || ((event.enrollmentEpoch == epochProvider())
                && (event.authorizationSession == sessionIdentity())
                && policy.permitsCollection
                && membership().effectiveEnrolled)
        lock.unlock()
        guard stillValid else {
            lock.lock(); aggregateAudioSamples -= event.audio.count; lock.unlock()
            return   // drop silently: its consent moved on while it waited
        }
        deliverUnderSinkOwnership(event)
    }

    /// Delivers one event with explicit in-sink ownership: counted from before the call until the
    /// sink RETURNS, then released from the ledger. This is the ONLY place the sink is invoked.
    private func deliverUnderSinkOwnership(_ event: SegmentEvent) {
        let n = event.audio.count
        lock.lock(); inFlightSinkAudioSamples += n; lock.unlock()
        sink(event)
        // Ownership ends when the sink RETURNS — not at enqueue.
        lock.lock()
        inFlightSinkAudioSamples -= n
        aggregateAudioSamples -= n
        lock.unlock()
    }

    // MARK: - Test seams (production callers never use these)

    /// Samples the collector is ACTUALLY holding for the open capture — reads the buffer, not a counter.
    /// Number of events currently queued in the FIFO.
    var pendingCountForTesting: Int {
        lock.lock(); defer { lock.unlock() }
        return pending.count
    }

    /// Live aggregate owned-audio count (open + FIFO + ring) — the value the byte budget enforces.
    var aggregateAudioSamplesForTesting: Int {
        lock.lock(); defer { lock.unlock() }
        return aggregateAudioSamples
    }

    /// The ledger AUDITED against the live buffers: actually walks what is retained (open buffer,
    /// every queued event's audio, every ring entry's audio, plus the bytes of any event currently
    /// INSIDE a sink call). A budget that only trusts its own counter could drift from reality;
    /// this is the control that catches that.
    var actualRetainedAudioBreakdownForTesting: (open: Int, fifo: Int, ring: Int, inFlight: Int) {
        lock.lock(); defer { lock.unlock() }
        let openCount = current?.retained.count ?? 0
        let fifoCount = pending.reduce(0) { $0 + $1.audio.count }
        let ringCount = terminalRing.values.reduce(0) { $0 + $1.capture.retained.count }
        return (openCount, fifoCount, ringCount, inFlightSinkAudioSamples)
    }

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
