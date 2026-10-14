import Foundation
import PocketCastsUtils

/// Bounded handoff between a real-time audio producer and the echo reference.
///
/// The producer is an `AVAudioEngine` tap, which runs on a real-time thread with a
/// deadline. It must not touch the reference directly, for two reasons that are not equal
/// in strength and are stated separately because of it:
///
/// - **`append` has a confirmed in-lock cost.** Past capacity it drops the oldest samples
///   with `removeFirst` inside the lock, which is a memmove of the retained window on every
///   append. That is unconditionally inside the lock.
/// - **`snapshot` may wait, by an amount that is not established.** It returns a Swift
///   array under the lock, which is a retain rather than a copy: the buffer's copy is
///   copy-on-write and happens later, possibly outside the lock, depending on the caller.
///   So an earlier claim here that a snapshot copies the whole retained window inside the
///   lock was wrong — that figure is an upper bound on what a caller could pay, not a cost
///   the lock holds.
///
/// Either way a callback that waits on that lock can miss its deadline, and an `NSLock`
/// prevents a data race without bounding the wait. **Whether a tap callback actually waits,
/// and for how long, is unmeasured** — this is the reason to hand off, not a measurement
/// that the handoff is required. The handoff also removes the question: the callback no
/// longer touches the reference at all.
///
/// So the callback submits into a fixed-capacity queue and returns, and a serial queue
/// applies the blocks to the reference off the real-time thread. This is the shape
/// `NativeAudioCapture` already uses for its input tap.
///
/// **Capacity and overflow.** The queue holds at most `capacity` pending blocks. When it
/// is full the incoming block is **dropped** and counted. Dropping leaves a **gap** in the
/// reference rather than closing it: the reference is a timeline, so advancing over audio
/// that was never applied would place every later sample at the wrong offset. A gap makes
/// the consumer see less audio than the producer submitted, which is the visible signal
/// that the two got out of step.
///
/// **Ownership.** `reset()` discards pending blocks, so audio produced before a stop is
/// not delivered after a restart — those blocks describe a timeline that no longer exists.
/// Each submitted block is applied exactly once, in submission order.
final class EchoReferenceHandoff {
    /// A block of emitted audio, with the instant it was rendered and its source rate.
    struct Block {
        /// Which producer's clock the frames below belong to.
        let producer: ProducerIdentity
        let samples: [Float]
        let sampleRate: Double
        /// The instant the producer rendered this audio, on the shared monotonic basis.
        ///
        /// Carried through the handoff because the handoff delays arrival: placing a
        /// segment against the consumer's arrival time would place it later than the audio
        /// was audible.
        let renderedAt: MonotonicTime?
        /// The producer's own frame count when this block began, and when it ended.
        ///
        /// The pair is what makes the count a position rather than progress: a block can
        /// begin partway into the producer's timeline, so progress is the difference between
        /// them. Nil when the producer did not report a position — kept missing rather than
        /// filled in, because a substitution would be indistinguishable from a real
        /// measurement of zero.
        ///
        /// This is the producer's own clock, and it is deliberately not a position in the
        /// reference: a node restarts between turns and counts from zero again, and two
        /// producers count independently. It is meaningful only against the reference range
        /// this block lands in, which is why the handoff records both rather than either.
        let renderedFramesInProducer: Double?
        /// The producer's own frame count when this block began.
        let producerBlockStart: Double?
        /// The producer's own frame count at the END of this block (exclusive). Carried separately
        /// from `renderedFramesInProducer`, which is the RENDER POSITION the timestamp describes:
        /// one field cannot serve as both the range end and the represented position, because the
        /// automatic anchor would then pair the end frame with the start's instant.
        let producerBlockEnd: Double?
    }

    private let reference: PlaybackEchoReference
    private let capacity: Int
    private let queue: DispatchQueue

    /// Called after a delivery dequeues its block and before it appends, so a test can run
    /// a reset in that window. The window is the one that matters: clearing `pending` cannot
    /// recall a block that has already been removed from it.
    var onDeliveryDequeued: (() -> Void)?

    /// TEST-ONLY acknowledgment fired IMMEDIATELY AFTER a block's samples are appended and its
    /// automatic anchor is published, inside the same critical section — i.e. BEFORE any later
    /// queued correction can run. It is the observation point at which a coherent frame/instant
    /// pair must already hold, and it is what makes the end-position mutation detectable.
    var onBlockAccepted: (() -> Void)?

    /// Where an appended block's audio sits, in both clocks it has to be matched in.
    ///
    /// The producer's own frame count says which of that producer's blocks a later position
    /// was observed in; the shared-reference range says where that block's audio landed. A
    /// later position can only be converted by finding the block that CONTAINS it, because the
    /// producer's count runs from its own zero while the reference's runs from the append. The
    /// latest append's origin cannot substitute: later blocks, from this producer or another,
    /// may already be queued behind the one the position belongs to.
    private struct AppendedRange {
        /// WHICH producer's clock the range below is expressed in. Every producer counts from
        /// its own zero, so two blocks can carry overlapping local ranges while describing
        /// different audio; a containing range alone selects the wrong block.
        let producer: ProducerIdentity
        /// Producer-local frames this block spans: `producerStart` inclusive.
        let producerStart: Double
        let producerEnd: Double
        /// The shared-reference index range this block occupies.
        let referenceStart: Int
        let referenceLength: Int
        /// The session it was appended under, so a position from a later session is refused
        /// rather than matched against audio it never described.
        let generation: Int
    }

    /// Identifies the producer that submitted a block or a position: a stable value per
    /// producer node, which is what separates two producers' clocks when their ranges overlap.
    /// Identifies one producer CLOCK, not merely one producer.
    ///
    /// A producer's counter resets when its node restarts, and the old ranges may still be
    /// retained in the same handoff generation. The kind alone therefore cannot separate a
    /// restarted clock from the one it replaced: two blocks of the same kind, from before and
    /// after the restart, would carry overlapping local ranges while describing different
    /// audio. The incarnation changes on exactly that reset, so an observation from a retired
    /// incarnation is refused rather than matched against audio it never described.
    ///
    /// The token is owned by the producer — it changes when that producer's clock resets, and
    /// nothing else resets it. Restarting one producer must not invalidate another's
    /// incarnation, since an unrelated reset would discard positions that are still valid.
    struct ProducerIdentity: Hashable {
        enum Kind: Hashable {
            case earcon
            case cloud
            case episodeTap
        }

        let kind: Kind
        /// Changes when this producer's node restarts and its frame counter returns to zero.
        let incarnation: UInt64
    }

    /// Blocks that have been appended, newest last, so a later render position can be matched
    /// to the block that contains it. Bounded: a position only refers to recent audio, and an
    /// unbounded list would retain every block of the session.
    private var appendedRanges: [AppendedRange] = []
    private let appendedRangeRetention = 32
    private let lock = NSLock()
    private var pending: [Block] = []
    private var droppedBlocks = 0
    /// Incremented by `reset`. A delivery records this when it dequeues and compares it
    /// before appending, so a block whose session ended while it was in flight is dropped
    /// instead of landing in the new session's reference.
    private var generation = 0

    /// The ACTIVE incarnation per producer kind — the clock that positions are currently
    /// being submitted under.
    ///
    /// A producer reports its new identity when its node restarts, and the handoff records it
    /// here. Observations whose identity is not the active one for their kind are refused
    /// BEFORE range lookup: a retired incarnation's numbers are still valid numbers, and its
    /// retained blocks may still be resident, so a range-and-identity match alone would accept
    /// a late observation from a clock that has already been replaced. Refusing on identity is
    /// the boundary; the retained block is kept because its audio is genuinely still resident.
    private var activeIncarnations: [ProducerIdentity.Kind: UInt64] = [:]

    init(
        reference: PlaybackEchoReference,
        capacity: Int,
        queueLabel: String = "fm.auris.echo.reference.handoff"
    ) {
        self.reference = reference
        self.capacity = max(1, capacity)
        self.queue = DispatchQueue(label: queueLabel, qos: .userInitiated)
    }

    /// Number of blocks dropped because the queue was full. A consumer that sees this
    /// climb is behind the producer, and the reference has gaps as a result.
    var droppedBlockCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return droppedBlocks
    }

    /// Submits a block from the producer. Called on the real-time thread, so this must not
    /// block: it takes the lock only long enough to append, and the lock is never held
    /// while the reference is updated.
    ///
    /// - Parameter renderedAt: the instant the producer rendered this audio.
    func submit(
        _ samples: [Float],
        producer: ProducerIdentity,
        sampleRate: Double,
        renderedAt: MonotonicTime? = nil,
        renderedFramesInProducer: Double? = nil,
        producerBlockStart: Double? = nil,
        producerBlockEnd: Double? = nil
    ) {
        guard !samples.isEmpty else { return }

        lock.lock()
        guard pending.count < capacity else {
            // Dropped, not coalesced. Coalescing would close the gap and put every later
            // sample at the wrong offset.
            droppedBlocks += 1
            lock.unlock()
            logDropOnce()
            return
        }
        pending.append(
            Block(
                producer: producer,
                samples: samples,
                sampleRate: sampleRate,
                renderedAt: renderedAt,
                renderedFramesInProducer: renderedFramesInProducer,
                producerBlockStart: producerBlockStart,
                producerBlockEnd: producerBlockEnd
            )
        )
        lock.unlock()

        queue.async { [weak self] in
            self?.deliver()
        }
    }

    /// Records the producer's NEW active incarnation after its clock reset, and retires the
    /// previous one.
    ///
    /// Called by the producer at the reset itself, so the boundary is the reset rather than the
    /// next submission: an observation submitted under the retired incarnation after this call
    /// is refused before range lookup, even though its numbers still fall inside a retained
    /// block. A producer that never calls this keeps submitting under its current identity, and
    /// unrelated producers are untouched — the boundary is per kind, not global.
    func rotateIncarnation(for kind: ProducerIdentity.Kind, to incarnation: UInt64) {
        lock.lock()
        activeIncarnations[kind] = incarnation
        lock.unlock()
    }

    /// Submits a render position to be recorded on the reference, in order with the blocks.
    ///
    /// Producers that learn their position after submitting their samples need both to
    /// travel the same route, or the anchor and the audio can cross: recording the anchor
    /// directly on the reference from the producer while its samples are still queued here
    /// would place the audio at a position it has not reached. Ordered through the same
    /// serial queue so the anchor lands after the block it belongs to.
    ///
    /// - Parameter anchor: the position, or nil when the node is not rendering.
    func submitRenderPosition(_ anchor: PlaybackRenderAnchor?, producer: ProducerIdentity) {
        lock.lock()
        let session = generation
        lock.unlock()
        queue.async { [weak self] in
            self?.record(anchor, producer: producer, generation: session)
        }
    }

    /// Applies every pending block to the reference. Exposed so a test can drive the
    /// handoff deterministically rather than waiting on the queue.
    func drain() {
        queue.sync {}
    }

    /// Ends the session: pending blocks are discarded and later deliveries from before the
    /// reset are refused.
    func reset() {
        lock.lock()
        generation += 1
        pending.removeAll()
        lock.unlock()
    }

    /// Records a producer's render position against the block that contains it.
    ///
    /// The position arrives in the submitting producer's own frame count, so it is converted
    /// through the SHARED-REFERENCE RANGE of the block whose producer-local range contains it
    /// — not through the latest append's origin, which may belong to a later block or to
    /// another producer entirely.
    ///
    /// The generation check and the reference update are in ONE critical section, the same
    /// boundary `deliver()` closes: a check that releases the lock before the act permits a
    /// reset to land in between, and the position then lands in a session that ended. Holding
    /// the lock across both means a reset either happens before the check (the position is
    /// refused) or after the update (the position was already in the old session's reference).
    ///
    /// Lock order is `handoff.lock` -> `reference.lock`; `deliver()` already takes that order
    /// when it reads `reference.streamIndex` under this lock, and nothing in the reference
    /// calls back into the handoff, so the reverse order does not exist.
    private func record(
        _ anchor: PlaybackRenderAnchor?,
        producer: ProducerIdentity,
        generation submittedGeneration: Int
    ) {
        lock.lock()
        defer { lock.unlock() }

        // A position from an ended session must not land in the new session's reference.
        guard submittedGeneration == generation else { return }

        // The position must carry the ACTIVE incarnation for its kind. Identity equality
        // alone is not the boundary: a late observation honestly carrying the RETIRED
        // incarnation still falls inside that incarnation retained block, so a range-and-
        // identity match would accept it and place the window in a clock that has already
        // been replaced. The active-incarnation boundary refuses it before the lookup; a
        // producer that has not reported a reset has no retired incarnation to refuse.
        // An absent entry means this kind has never reported a reset, so there is no retired
        // incarnation to refuse and the observation is accepted.
        if let active = activeIncarnations[producer.kind], active != producer.incarnation {
            return
        }

        guard let anchor else {
            reference.recordRenderPosition(nil)
            return
        }
        let producerFrames = anchor.renderedFrames
        // Matched on the whole IDENTITY (kind AND incarnation) as well as the range. Every
        // producer counts from its own zero, so an earcon block spanning 0..<400 and a cloud
        // block spanning 0..<400 overlap exactly while describing different audio; and a
        // restarted node of the SAME kind reuses those numbers again.
        // The comparison is on the WHOLE identity, so a range recorded by a retired
        // incarnation of this kind does not match: its numbers were reused after the restart.
        // The containing block must ALSO still be resident in the reference. The retained
        // ranges are bounded at 32 entries while the reference ring is bounded at
        // `sampleRate * retainedSeconds` samples, and those two bounds are independent: 32
        // tap blocks can span far more audio than the ring retains, and the ring drops from
        // the front as it fills. A position matched to a range whose samples were trimmed
        // would be recorded as a confident offset against audio the window no longer holds —
        // the stale-anchor failure reached by a different door. Residency is checked against
        // the reference's own retained span rather than assumed from the match.
        let residentStart = reference.retainedStreamStart()
        let containing = appendedRanges.last { range in
            range.producer == producer
                && range.generation == submittedGeneration
                && producerFrames >= range.producerStart
                && producerFrames < range.producerEnd
                && range.referenceStart >= residentStart
        }
        guard let containing else {
            reference.recordRenderPosition(nil)
            return
        }
        let withinProducer = (producerFrames - containing.producerStart)
            / max(1, containing.producerEnd - containing.producerStart)
        reference.recordRenderPosition(
            PlaybackRenderAnchor(
                renderedFrames: Double(
                    containing.referenceStart
                        + Int(withinProducer * Double(containing.referenceLength))
                ),
                sourceSampleRate: PlaybackEchoReference.pipelineSampleRate,
                hostTime: anchor.hostTime
            )
        )
    }

    private func deliver() {
        lock.lock()
        guard !pending.isEmpty else {
            lock.unlock()
            return
        }
        let block = pending.removeFirst()
        let blockGeneration = generation
        lock.unlock()

        // A reset that happened while this block was in flight means it belongs to a
        // session that has ended. Dequeuing removed it from `pending`, so the reset could
        // not discard it — and appending it now would put a previous session's audio into
        // the new reference. Applying each block exactly once is satisfied either way; that
        // is why this boundary needs checking separately from the counting argument.
        onDeliveryDequeued?()

        // The generation is re-checked inside the same critical section that performs the
        // append, not before it. Checking first and appending after leaves a window: `reset()`
        // can land between the two, and the block then lands in a session that ended — the
        // exact boundary a check-then-act sequence cannot close. Holding the lock across the
        // append means a reset either happens before the check (the block is refused) or after
        // the append (the block was already in the old session's audio, which the reset
        // discards), and there is no interleaving in between.
        lock.lock()
        guard blockGeneration == generation else {
            lock.unlock()
            return
        }
        // THE SAME PRODUCER-IDENTITY POLICY THE RENDER-POSITION PATH ENFORCES, applied to SAMPLES
        // and enforced HERE, at the synchronized acceptance boundary rather than at enqueue. A
        // callback retired before its block is delivered must be refused exactly as its position
        // would be: the two halves of one producer's output cannot be policed differently. Checking
        // here -- not in `submit` -- also covers a retirement that happens BETWEEN enqueue and this
        // acceptance, which a check at enqueue could not see.
        //
        // ALREADY-ACCEPTED AUDIO IS UNTOUCHED: this refuses a NEWLY SUBMITTED stale callback and
        // appends nothing; it does not delete blocks that were accepted before the retirement, so
        // the existing retention contract is preserved.
        if let active = activeIncarnations[block.producer.kind],
           active != block.producer.incarnation {
            lock.unlock()
            return
        }
        defer { lock.unlock() }

        let resampled = PlaybackResampler.toPipelineRate(
            block.samples,
            sourceRate: block.sampleRate
        )
        // Where this block will land in the reference, read before the append moves the
        // stream on. This is the producer's own range within the shared timeline, and it is
        // the only correct origin for a position inside the block: an interleaved producer's
        // appends sit between this producer's blocks, so no single per-producer offset maps
        // them and the append tail would be another producer's audio.
        let rangeStart = reference.streamIndex

        reference.append(resampled)

        // Keep this block's two clocks together so a later position can be matched to the
        // block that contains it. Recorded only when the producer reported its own range: a
        // block with no producer-local start or end cannot be matched against, and inventing
        // one would make an unknown position look like a known zero.
        if let start = block.producerBlockStart, let end = block.producerBlockEnd ?? block.renderedFramesInProducer {
            appendedRanges.append(
                AppendedRange(
                    producer: block.producer,
                    producerStart: start,
                    producerEnd: end,
                    referenceStart: rangeStart,
                    referenceLength: resampled.count,
                    generation: blockGeneration
                )
            )
            if appendedRanges.count > appendedRangeRetention {
                appendedRanges.removeFirst(appendedRanges.count - appendedRangeRetention)
            }
        }

        // The anchor is the block's reference range plus how far the producer had actually
        // rendered within it. Two things are deliberately not used here:
        //
        //   * the block's own length, which is a duration rather than a position and was the
        //     original defect — as an offset it falls below a sliding window and the filter
        //     then declines every segment;
        //   * the append tail, which is the newest SUBMITTED sample and runs ahead of what
        //     has been heard by however much audio is still queued in the output node.
        //
        // When the producer reports no position, the block's start is recorded rather than
        // its end: the start is a fact about where the audio is, while the end would claim
        // progress the producer has not reported.
        // A block whose producer reported no position records NO anchor, rather than one at
        // the block's start. Substituting the start made a missing measurement look like a
        // measured zero, and the two mean different things to the filter: the first says the
        // placement is unknown, the second claims it is known and no progress has been made.
        let anchoredEnd = block.renderedFramesInProducer.flatMap { frames in
            block.producerBlockStart.map { start in
                referenceIndexForProducerPosition(
                    rangeStart: rangeStart,
                    producerBlockStart: start,
                    producerFrames: frames,
                    producerRate: block.sampleRate,
                    blockLength: resampled.count
                )
            }
        }

        reference.recordRenderPosition(
            anchoredEnd.flatMap { end in
                block.renderedAt.map { host in
                PlaybackRenderAnchor(
                    renderedFrames: Double(end),
                    sourceSampleRate: PlaybackEchoReference.pipelineSampleRate,
                    hostTime: host
                )
                }
            }
        )
        // FIRED AFTER THE ATOMIC PUBLICATION: the samples are appended and the anchor is written
        // inside this same critical section, so a coherent frame/instant pair already holds here and
        // no later queued operation has yet run.
        onBlockAccepted?()
    }

    private var dropLogged = false

    /// Logged once rather than per drop: a producer that is persistently behind would
    /// otherwise flood the log from a queue that is already saturated.
    private func logDropOnce() {
        lock.lock()
        guard !dropLogged else {
            lock.unlock()
            return
        }
        dropLogged = true
        lock.unlock()
        FileLog.shared.addMessage(
            "[VoicePipeline] Echo reference handoff is full (capacity \(capacity)); dropping emitted blocks. The reference will have gaps until the consumer catches up."
        )
    }
}
