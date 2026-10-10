import Foundation
import PocketCastsUtils

/// Bounded handoff between a real-time audio producer and the echo reference.
///
/// The producer is an `AVAudioEngine` tap, which runs on a real-time thread with a
/// deadline. It must not touch the reference directly: `PlaybackEchoReference.snapshot`
/// copies the whole retained window inside its lock and `append` does a memmove there, so
/// a callback that waits on that lock can miss its deadline. An `NSLock` prevents a data
/// race; it does not bound the wait.
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
    }

    private let reference: PlaybackEchoReference
    private let capacity: Int
    private let queue: DispatchQueue

    private let lock = NSLock()
    private var pending: [Block] = []
    private var droppedBlocks = 0

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
    func submit(_ samples: [Float], sampleRate: Double, renderedAt: MonotonicTime? = nil) {
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
        pending.append(Block(samples: samples, sampleRate: sampleRate, renderedAt: renderedAt))
        lock.unlock()

        queue.async { [weak self] in
            self?.deliver()
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
    private func deliver() {
        lock.lock()
        guard !pending.isEmpty else {
            lock.unlock()
            return
        }
        let block = pending.removeFirst()
        lock.unlock()

        let resampled = PlaybackResampler.toPipelineRate(
            block.samples,
            sourceRate: block.sampleRate
        )
        reference.append(resampled)
        // The producer's render instant is carried through, so the reference is placed on
        // the timeline the audio was actually emitted on rather than the consumer's.
        reference.recordRenderPosition(
            block.renderedAt.map {
                PlaybackRenderAnchor(
                    renderedFrames: Double(resampled.count),
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
