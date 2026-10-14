import AVFoundation
import PocketCastsUtils

/// Captures the episode renderer's output as an echo reference source.
///
/// **Why the node FEEDING the output node, not the output node itself.** The render graph is
/// `player → mixer → timePitch → highPass → dynamics → peakLimiter → outputNode`. Two
/// properties constrain where a tap can go:
///
/// - `timePitch` changes both rate and duration, so audio tapped before it would be
///   correlated against a timeline nothing heard.
/// - Three units are bypassed conditionally when volume boost is off, so a tap placed among
///   them means different things in different configurations.
///
/// Tapping the output node satisfied both because it is last. But the SDK advises AGAINST
/// tapping `AVAudioOutputNode`: "there could be a mismatch between the tap buffer format and
/// `AVAudioOutputNode`'s output format, depending on the underlying physical device. Hence,
/// instead of tapping the `AVAudioOutputNode`, it is advised to tap the node connected to it."
///
/// The node feeding the output node keeps both properties: it is the LAST node before output,
/// so it is still downstream of `timePitch` and of the conditionally-bypassed units. The node
/// is DISCOVERED from the engine rather than named, so a chain that changes still resolves.
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

    /// This producer's clock incarnation, rotated whenever the tap is (re)installed.
    ///
    /// The tap reports positions from the engine's own rendered clock, which returns to zero
    /// when the tap is installed onto a fresh graph. An observation from before that reset
    /// therefore carries the same numbers as one after it while describing different audio, so
    /// the incarnation changes at the install and travels with every block this tap submits.
    private var nodeIncarnation: UInt64 = 0

    /// The identity every submission from this tap carries.
    var producerIdentity: EchoReferenceHandoff.ProducerIdentity {
        EchoReferenceHandoff.ProducerIdentity(kind: .episodeTap, incarnation: nodeIncarnation)
    }

    /// Installs the tap on the node feeding output, on the bus that actually feeds it.
    ///
    /// INSTALLING AGAIN IS SAFE BY CONSTRUCTION, not by claim: any tap this object previously
    /// installed is REMOVED from the node it was actually installed on before a new one goes on, so
    /// a graph replacement cannot leave the prior node tapped and cannot leave two taps competing
    /// for one bus (which CoreAudio refuses outright). The bus is the one the feeder reports as
    /// feeding output, so a chain whose connection is not on bus 0 is still tapped correctly.
    func install() {
        // REMOVE FIRST AND UNCONDITIONALLY, before any early return. An earlier version resolved the
        // feeder before removing, so a guard failure (no engine, or nothing feeding output) returned
        // EARLY and LEFT THE PRIOR TAP INSTALLED on the old node: the reference would keep receiving
        // from the old tap under the old identity while the caller believed a fresh install had
        // happened. Removing first means every exit path leaves at most the tap that was actually
        // installed here, which is the state the object reports.
        remove()
        guard let engine else { return }
        guard let connection = Self.outputFeederConnection(of: engine) else { return }
        nodeIncarnation &+= 1
        handoff?.rotateIncarnation(for: .episodeTap, to: nodeIncarnation)
        // THE ADMITTED IDENTITY, captured HERE so the callback carries the incarnation it was
        // admitted under rather than reading whatever `self` holds when it later fires. A held old
        // callback after a reinstall must submit its OWN identity, not acquire the new one.
        let admitted = producerIdentity
        let node = connection.node
        installedNode = node
        installedBus = connection.bus
        let closure: (AVAudioPCMBuffer, AVAudioTime) -> Void = { [weak self] buffer, when in
            // On the real-time thread: copy off and hand off, nothing else. `Task {}` and
            // FileLog are not safe here, which is why the copy is the only work done.
            self?.onCallbackArrived?(
                when.isSampleTimeValid ? Double(when.sampleTime) : nil,
                when.isHostTimeValid ? AVAudioTime.seconds(forHostTime: when.hostTime) : nil
            )
            self?.capture(buffer, renderedAt: when, producer: admitted)
        }
        // Test-only observer, nil in production: the TEST retains closures it wants to invoke;
        // this object keeps no history.
        onInstalledClosure(closure)
        node.installTap(
            onBus: connection.bus,
            bufferSize: 4096,
            format: nil
        ) { buffer, when in
            closure(buffer, when)
        }
    }

    /// The tap closures each install captured, in install order. Retained so a test can invoke a
    /// PRIOR install's closure after a reinstall — the seam that makes the capture itself
    /// observable: a closure that read the current identity at fire time would acquire the new
    /// incarnation here, where the immutable capture submits its own.
    /// TEST-ONLY observer: receives each install's tap closure at install time. A test retains
    /// the closures it wants to invoke later; production uses the no-op default and stores
    /// nothing, so no closure history exists outside tests.
    var onInstalledClosure: (@escaping (AVAudioPCMBuffer, AVAudioTime) -> Void) -> Void = { _ in }

    /// TEST-ONLY arrival counter hook, no-op in production: fires on the render thread as each tap
    /// callback enters, carrying the callback's own sample time and host instant (either may be nil
    /// when the corresponding field is invalid), so a trace can establish arrival ordering and the
    /// advancing frame/host progression rather than infer them.
    var onCallbackArrived: ((_ sampleTime: Double?, _ hostSeconds: Double?) -> Void)?

    /// TEST-ONLY observer of the buffers this tap PUBLISHES, with the callback's time. It exists so
    /// a control can locate a distinctive marker in the published samples and correlate that
    /// sample's index and host instant, rather than inferring the marker from a proxy.
    var onBuffer: ((AVAudioPCMBuffer, AVAudioTime) -> Void)?

    /// The node whose output bus feeds the engine's output node, or nil when nothing is connected.
    /// Read from the ENGINE rather than from a named unit, so a chain that changes — an added or
    /// removed effect, a bypassed unit — still resolves to whatever actually feeds output.
    static func outputFeederNode(of engine: AVAudioEngine) -> AVAudioNode? {
        outputFeederConnection(of: engine)?.node
    }

    /// The NODE and the BUS whose output feeds the engine's output node, or nil when nothing is
    /// connected. The bus is carried because it is the connection's own: tapping bus 0 regardless
    /// would miss a feeder whose output reaches the output node on another bus.
    static func outputFeederConnection(of engine: AVAudioEngine) -> (node: AVAudioNode, bus: AVAudioNodeBus)? {
        // The lookup is a parameter so a test can supply a controlled connection point whose bus
        // is nonzero; production passes the engine's own.
        let outputNode = engine.outputNode
        return outputFeederConnection(inputBusCount: outputNode.numberOfInputs) { inputBus in
            engine.inputConnectionPoint(for: outputNode, inputBus: inputBus).flatMap { point in
                // Guard the self-reference: tapping the output node is the placement the SDK
                // advises against, and an engine reporting it must not be mistaken for a feeder.
                guard let node = point.node, node !== outputNode else { return nil }
                return (node: node, bus: point.bus)
            }
        }
    }

    /// The core of the search, parameterized over the connection-point lookup. A feeder output
    /// bus can feed ANY of the output node's input buses, so every input bus is searched rather
    /// than assuming bus 0.
    static func outputFeederConnection(
        inputBusCount: Int,
        connectionPoint: (AVAudioNodeBus) -> (node: AVAudioNode, bus: AVAudioNodeBus)?
    ) -> (node: AVAudioNode, bus: AVAudioNodeBus)? {
        for inputBus in 0..<inputBusCount {
            guard let point = connectionPoint(inputBus) else { continue }
            // The connection point's bus is the FEEDER's OUTPUT bus; that is what a tap needs,
            // and it is carried as reported rather than assumed to be zero.
            return (point.node, point.bus)
        }
        return nil
    }

    func remove() {
        // Removed from the node it was actually installed on, not from the output node: after a
        // graph change those differ, and removing from the wrong one leaves a tap behind.
        installedNode?.removeTap(onBus: installedBus)
        installedNode = nil
        installedBus = Self.bus
        nodeIncarnation &+= 1
        handoff?.rotateIncarnation(for: .episodeTap, to: nodeIncarnation)
    }

    /// Whether the tap is installed on `node`. Despite the historical name the placement is the
    /// FEEDER — the node connected to output — so callers assert against
    /// `EpisodeOutputTap.outputFeederNode(of:)`, not against `engine.outputNode`.
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
    /// The bus the tap was installed on, so `remove()` targets the same one.
    private var installedBus: AVAudioNodeBus = 0

    /// Copies a delivered buffer and hands it off.
    ///
    /// Exposed so the placement and the publishing rule can be exercised without running an
    /// engine, which cannot be made to render deterministically under test.
    func publish(
        _ buffer: AVAudioPCMBuffer,
        renderedAt: AVAudioTime? = nil,
        producer: EchoReferenceHandoff.ProducerIdentity? = nil
    ) {
        if let renderedAt { onBuffer?(buffer, renderedAt) }
        // The caller's ADMITTED identity when supplied; the current one otherwise, so existing
        // callers that publish without an admitted identity keep working.
        let producerIdentity = producer ?? self.producerIdentity
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
        // THE TIME IS THE BLOCK'S START. Measured through an explicitly scheduled marker
        // (ExplicitScheduleOriginProbe): the marker's host instant matches H + j/R within ~0.6 ms
        // and misses H + (j-N)/R by a full buffer, so `sampleTime` labels the buffer's FIRST
        // sample. The block therefore spans [sampleTime, sampleTime + frameLength), and the range
        // is submitted in exactly those terms — no backward shift, and the shared half-open
        // containment in the handoff is untouched.
        let producerBlockStart = producerFrames
        let producerBlockEnd = producerFrames.map { $0 + Double(buffer.frameLength) }

        handoff.submit(
            mono,
            producer: producerIdentity,
            sampleRate: buffer.format.sampleRate,
            renderedAt: hostInstant,
            // THE RENDER POSITION IS T, the frame the timestamp describes — NOT the range end.
            // Passing the end here made the handoff publish an automatic anchor pairing the
            // block's last frame with the start's instant, an incoherent pair observable until
            // the later render-position submit corrected it.
            renderedFramesInProducer: producerFrames,
            producerBlockStart: producerBlockStart,
            producerBlockEnd: producerBlockEnd
        )

        // A SECOND submitRenderPosition IS NOT NEEDED: the block above already carries the
        // producer's rendered position (T) and its host instant, and the handoff publishes the
        // anchor from exactly those two fields when it accepts the block. Publishing the same pair
        // again through the render-position queue would leave two operations whose only difference
        // is when they run, which is what let an incoherent intermediate exist.
    }

    private static let silenceFloor: Float = 1e-5

    private func capture(
        _ buffer: AVAudioPCMBuffer,
        renderedAt: AVAudioTime,
        producer: EchoReferenceHandoff.ProducerIdentity
    ) {
        publish(buffer, renderedAt: renderedAt, producer: producer)
    }
}
