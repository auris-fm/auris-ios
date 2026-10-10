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
        let samples: [Float]
        let sampleRate: Double
        /// The instant the producer rendered this audio, on the shared monotonic basis.
        ///
        /// Carried through the handoff because the handoff delays arrival: placing a
        /// segment against the consumer's arrival time would place it later than the audio
        /// was audible.
        let renderedAt: MonotonicTime?
        /// How far the producer's node had rendered, in ITS OWN frames, when it produced
        /// this block.
        ///
        /// This is the producer's own clock, and it is deliberately not a position in the
        /// reference: a node restarts between turns and counts from zero again, and two
        /// producers count independently. It is meaningful only against the reference range
        /// this block lands in, which is why the handoff records both rather than either.
        let renderedFramesInProducer: Double?
    }

    private let reference: PlaybackEchoReference
    private let capacity: Int
    private let queue: DispatchQueue

    /// Called after a delivery dequeues its block and before it appends, so a test can run
    /// a reset in that window. The window is the one that matters: clearing `pending` cannot
    /// recall a block that has already been removed from it.
    var onDeliveryDequeued: (() -> Void)?

    private let lock = NSLock()
    private var pending: [Block] = []
    private var droppedBlocks = 0
    /// Incremented by `reset`. A delivery records this when it dequeues and compares it
    /// before appending, so a block whose session ended while it was in flight is dropped
    /// instead of landing in the new session's reference.
    private var generation = 0

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
        sampleRate: Double,
        renderedAt: MonotonicTime? = nil,
        renderedFramesInProducer: Double? = nil
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
                samples: samples,
                sampleRate: sampleRate,
                renderedAt: renderedAt,
                renderedFramesInProducer: renderedFramesInProducer
            )
        )
        lock.unlock()

        queue.async { [weak self] in
            self?.deliver()
        }
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
    func submitRenderPosition(_ anchor: PlaybackRenderAnchor?) {
        lock.lock()
        let session = generation
        lock.unlock()
        queue.async { [weak self] in
            self?.record(anchor, generation: session)
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

    /// Applies the oldest pending block.
    ///
    /// A delivery whose block was discarded by a `reset` finds the queue empty or holding a
    /// newer block, and applies that newer block instead — which is correct, because the
    /// blocks are applied in submission order on one serial queue and every submitted block
    /// is applied exactly once. An earlier version tagged each delivery with a session and
    /// refused to apply across a reset boundary; that check could not change any observable
    /// result (both orderings apply each surviving block exactly once, only which delivery
    /// applies it differs), so it was removed rather than kept as protection that cannot be
    /// demonstrated.
    private func record(_ anchor: PlaybackRenderAnchor?, generation submittedGeneration: Int) {
        lock.lock()
        // Same boundary as a block: a position from an ended session must not land in the
        // new session's reference.
        let stillCurrent = submittedGeneration == generation
        lock.unlock()
        guard stillCurrent else { return }
        reference.recordRenderPosition(anchor)
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
        lock.lock()
        let stillCurrent = blockGeneration == generation
        lock.unlock()
        guard stillCurrent else { return }

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
        let anchoredEnd = block.renderedFramesInProducer.map {
            referenceIndexForProducerPosition(
                rangeStart: rangeStart,
                producerFrames: $0,
                producerRate: block.sampleRate,
                blockLength: resampled.count
            )
        } ?? rangeStart

        reference.recordRenderPosition(
            block.renderedAt.map {
                PlaybackRenderAnchor(
                    renderedFrames: Double(anchoredEnd),
                    sourceSampleRate: PlaybackEchoReference.pipelineSampleRate,
                    hostTime: $0
                )
            }
        )
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
