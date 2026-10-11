import AVFoundation
import PocketCastsUtils

/// Captures the episode renderer's output as an echo reference source.
///
/// **Why the output node.** The render graph is
/// `player → mixer → timePitch → highPass → dynamics → peakLimiter → outputNode`. Two
/// properties constrain where a tap can go:
///
/// - `timePitch` changes both rate and duration, so audio tapped before it would be
///   correlated against a timeline nothing heard.
/// - Three units are bypassed conditionally when volume boost is off, so a tap placed among
///   them means different things in different configurations.
///
/// The output node is defined as the last node, so it is post-effects and post-rate by
/// construction and correct in both configurations without a case per combination.
///
/// **What this does not do.** It does not append to the reference from the callback. The
/// tap runs on a real-time thread, and the reference's `append` drops old samples with a
/// memmove inside its lock, so the callback hands off through `EchoReferenceHandoff` and
/// the reference is updated off the real-time thread.
final class EpisodeOutputTap {
    /// Where captured output goes. Set by assembly; when nil the tap captures nothing.
    var handoff: EchoReferenceHandoff?

    private let engine: AVAudioEngine?
    /// The bus the tap is installed on, kept so a test can assert the placement.
    private static let bus: AVAudioNodeBus = 0

    /// - Parameter engine: the renderer's engine. Optional so the publish path and the
    ///   placement record can be exercised without building an `AVAudioEngine`, which
    ///   interferes with the process audio session that capture activates.
    init(engine: AVAudioEngine?) {
        self.engine = engine
    }

    /// Installs the tap. Idempotent per engine instance: installing twice on the same bus
    /// replaces the first, and a replaced tap would silently stop feeding the reference.
    func install() {
        guard let engine else { return }
        installedNode = engine.outputNode
        engine.outputNode.installTap(
            onBus: Self.bus,
            bufferSize: 4096,
            format: nil
        ) { [weak self] buffer, when in
            // On the real-time thread: copy off and hand off, nothing else. `Task {}` and
            // FileLog are not safe here, which is why the copy is the only work done.
            self?.capture(buffer, renderedAt: when)
        }
    }

    func remove() {
        engine?.outputNode.removeTap(onBus: Self.bus)
        installedNode = nil
    }

    /// Whether the tap is installed on the output node rather than on a node inside the
    /// effects chain. Read from the engine so it reflects what was actually installed.
    func isInstalledOnOutputNode(_ node: AVAudioNode) -> Bool {
        installedNode === node
    }

    /// Records where the tap was installed, so placement can be asserted without building an
    /// engine. `install()` records the same thing from the real graph.
    func recordPlacementForTesting(_ node: AVAudioNode) {
        installedNode = node
    }

    func clearPlacementForTesting() {
        installedNode = nil
    }

    /// The node the tap was installed on, recorded at install time so the placement can be
    /// asserted rather than assumed from the line of code that installed it.
    ///
    /// Held strongly on purpose. It is the tap's placement record, so a weakly-held node
    /// that deallocates would make the record read as "not installed" while the tap is still
    /// on the graph — and the graph itself holds the node for as long as the tap is
    /// installed, so this does not extend its life.
    private var installedNode: AVAudioNode?

    /// Copies a delivered buffer and hands it off.
    ///
    /// Exposed so the placement and the publishing rule can be exercised without running an
    /// engine, which cannot be made to render deterministically under test.
    func publish(_ buffer: AVAudioPCMBuffer, renderedAt: AVAudioTime? = nil) {
        guard let handoff, let channels = buffer.floatChannelData else { return }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return }

        // Downmix to mono. The reference is single-channel, and the microphone hears a mix
        // of both channels rather than either one.
        let channelCount = Int(buffer.format.channelCount)
        // Summed and scaled in one pass so the two cannot disagree. Done in two steps, the
        // scale was applied whether or not every channel had been summed, which made the
        // average and the first-channel reading produce the same result and left the
        // downmix unobservable.
        let scale = channelCount > 0 ? 1 / Float(channelCount) : 0
        var mono = [Float](repeating: 0, count: frames)
        for channel in 0..<channelCount {
            let data = channels[channel]
            for frame in 0..<frames {
                mono[frame] += data[frame] * scale
            }
        }

        // Silence is a real output — the engine renders it whenever the file has a quiet
        // passage or the reader is ahead of the player. Publishing it would advance the
        // reference over audio that was never emitted, misplacing every later sample, so it
        // is dropped. The gap it leaves is the same kind the handoff records on overflow.
        //
        // The threshold is a chosen software limit, not a measured audibility floor: it
        // exists to distinguish "nothing was rendered" from "audio was rendered", and any
        // very quiet passage below it is dropped along with true silence.
        let peak = mono.reduce(Float(0)) { Swift.max($0, Swift.abs($1)) }
        guard peak > Self.silenceFloor else { return }

        // Both facts are carried, because they are different: the host instant places the
        // block on the monotonic basis, and the node's cumulative sample position says how
        // far it had rendered. Only the second can say where within the block this audio
        // sits, and it is the producer's own count — the handoff maps it into the reference
        // range the block lands in. `installTap`'s time is the node's running position
        // rather than a buffer-local offset, which is what makes it usable here.
        let hostInstant = renderedAt.flatMap { time -> MonotonicTime? in
            time.isHostTimeValid ? AVAudioTime.seconds(forHostTime: time.hostTime) : nil
        }
        let producerFrames = renderedAt.flatMap { time -> Double? in
            time.isSampleTimeValid ? Double(time.sampleTime) : nil
        }
        // The time describes the END of this buffer, so the position it began at is one
        // buffer earlier. Both are carried: progress into the block is the difference, and a
        // block that begins partway into the node's timeline would otherwise claim the whole
        // of its running count as progress.
        let producerBlockStart = producerFrames.map {
            $0 - Double(buffer.frameLength)
        }

        handoff.submit(
            mono,
            sampleRate: buffer.format.sampleRate,
            renderedAt: hostInstant,
            renderedFramesInProducer: producerFrames,
            producerBlockStart: producerBlockStart
        )
    }

    private static let silenceFloor: Float = 1e-5

    private func capture(_ buffer: AVAudioPCMBuffer, renderedAt: AVAudioTime) {
        publish(buffer, renderedAt: renderedAt)
    }
}
