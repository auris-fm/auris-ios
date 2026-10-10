import AVFoundation
import Foundation
import os.log

/// Receives binary audio frames from the cloud and plays them through the
/// shared audio output path with buffering, pause-and-resume on underrun,
/// and duck/restore of existing playback.
///
/// The player owns one continuous playback session per turn.  Frames are
/// buffered in-order; when the buffer drains below a threshold playback is
/// paused and resumed once new frames arrive.  The first frame ducks
/// existing playback; `done`/`error` restores it.
final class CloudAudioPlayer: @unchecked Sendable {

    /// Delegate callbacks for playback state changes.
    @MainActor
    protocol Delegate: AnyObject {
        /// Called when the player has buffered enough to start playing.
        func audioPlayerDidStartPlaying()
        /// Called when the player paused due to buffer underrun.
        func audioPlayerDidPause()
        /// Called when the player has drained and stopped output — the point at
        /// which playback the turn ducked may be restored, so the answer's tail
        /// does not play mixed with the resumed episode.
        func audioPlayerDidStop()
    }

    /// Codecs this player can actually decode and play.
    ///
    /// Frames are copied verbatim into an Int16 PCM buffer — there is no Opus
    /// or Ogg decoder anywhere in this path. `CloudRouteClient.supportedCodecs`
    /// must stay within this set: advertising a codec with no decoder lets the
    /// server negotiate a format we then play as noise. Listed as base codec
    /// names; the advertised form adds a sample rate (`pcm_s16le@24k`).
    static let decodableCodecs: Set<String> = ["pcm_s16le"]

    // MARK: - Public

    /// The codec negotiated for this turn, from the server's `connected` frame.
    /// Frames are decoded at this rate; the output node is connected with it so
    /// the mixer resamples to the hardware instead of the hardware's rate being
    /// assumed for the stream (which plays 24 kHz PCM at double speed on a
    /// 48 kHz device).
    func setNegotiatedCodec(_ codec: CloudAudioCodec) {
        bufferLock.lock()
        negotiatedCodec = codec
        bufferLock.unlock()
    }

    /// Start (or resume) playback with new frames.
    ///
    /// Call for each frame received on the WebSocket.  If the player was
    /// stopped, the first frame restarts it; if it was already playing the
    /// frame is enqueued.
    func enqueue(_ frame: CloudAudioFrame) {
        bufferLock.lock()
        buffer.append(frame)
        bufferLock.unlock()

        // Wake the runner: `runnerRunning` is "there is work to do", and the
        // runner waits until it is true. Clearing it here (the previous
        // behaviour) could never satisfy that wait, so frames buffered and the
        // user heard silence for every turn.
        runnerLock.lock()
        runnerRunning = true
        runnerLock.signal()
        runnerLock.unlock()
    }

    /// Drain remaining buffered frames and stop playback.
    /// Call on `done` / `error`.
    func finish() {
        runnerLock.lock()
        drainRemaining = true
        runnerRunning = true
        runnerLock.signal()
        runnerLock.unlock()
    }

    /// Reset state immediately (e.g. on cancellation).
    ///
    /// Stops the engine as well as dropping the buffered frames: a buffer
    /// already handed to `scheduleBuffer` keeps playing otherwise, so the tail
    /// of an abandoned answer would play over the error feedback and
    /// `isPlaying`/`paused` would stay true into the next turn (whose first
    /// frames are then treated as an underrun). The runner thread owns the
    /// engine, so the stop is done in drain mode.
    func cancel() {
        bufferLock.lock()
        buffer.removeAll()
        bufferLock.unlock()
        runnerLock.lock()
        drainRemaining = false
        stopRequested = true
        runnerRunning = true
        runnerLock.signal()
        runnerLock.unlock()
    }

    // MARK: - Internal

    weak var delegate: Delegate?

    // MARK: - Constants

    /// Maximum buffered frames before backpressure kicks in.
    private static let maxBufferCount = 300

    /// Minimum frames in buffer to resume playback after underrun.
    private static let resumeThreshold = 5

    // MARK: - Private

    private let bufferLock = NSLock()
    /// Guards the runner's state. `NSCondition` is used as *both* the mutex and
    /// the wait primitive: a separate `NSLock` would be held across
    /// `runnerLock.wait()` — which releases only the condition's own lock — so
    /// `enqueue`/`finish`/`cancel` could never acquire it and would deadlock.
    private let runnerLock = NSCondition()

    /// Frame buffer (in-order).
    private var buffer: [CloudAudioFrame] = []

    /// Codec negotiated in the server's `connected` frame (guarded by
    /// `bufferLock`, written on the main actor and read on the runner thread).
    private var negotiatedCodec: CloudAudioCodec?

    /// Sample rate the negotiated codec delivers, defaulting to the advertised
    /// codec's rate when no `connected` frame has been seen yet.
    private var negotiatedSampleRate: Double {
        bufferLock.lock()
        defer { bufferLock.unlock() }
        if let rate = negotiatedCodec?.sampleRateHz { return rate }
        return CloudRouteClient.advertisedPCMasterRateHz
    }

    /// There is work for the runner to do. The runner waits *until this is
    /// true* and clears it before processing; `enqueue` sets it, which is what
    /// wakes the loop (clearing it here — the earlier behaviour — could never
    /// satisfy the wait, so nothing ever played).
    private var runnerRunning = false

    /// The runner has returned from its loop. This is the runner's own final
    /// report, set as its last act before returning and observed by `deinit`
    /// under `runnerLock`.
    private var runnerExited = false

    /// Request drain-and-stop (done / error).
    private var drainRemaining = false

    /// Request an immediate stop without draining (cancel).
    private var stopRequested = false

    /// Teardown only, and reachable in principle rather than in practice: the
    /// runner thread holds the player for the app session, so `deinit` does not
    /// run. Turn ends (`finish`) must never set this — the player is reused.
    private var shutdownRequested = false

    /// Runner thread.
    private var runnerThread: Thread?

    /// The audio engine and player node — accessed only from runner thread.
    private var engine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?

    // MARK: - Init / Deinit

    /// Receives the PCM this player emits, so the echo filter can reference what was
    /// actually sent to the output. Set by the assembly; nil when nothing is listening.
    var emittedPCMReference: PlaybackEchoReference?

    init() {
        runnerThread = Thread(target: self, selector: #selector(runnerLoop), object: nil)
        runnerThread?.name = "CloudAudioPlayer"
        runnerThread?.start()
    }

    /// Lifetime: the player is built once per app session
    /// (`VoiceControlAssembly`) and the runner thread retains it, so this
    /// deinitializer does not run in practice and the shutdown path below
    /// exists for completeness rather than as live teardown. The runner must
    /// therefore survive a drain — `finish()` ends a turn, not the thread, and
    /// returning there is what made every turn after the first silent.
    deinit {
        runnerLock.lock()
        shutdownRequested = true
        runnerRunning = true
        runnerLock.signal()
        // Bounded join: wait for the runner to report that it has exited, but
        // never block teardown indefinitely on a thread that cannot exit. A
        // timeout here logs and proceeds — a teardown that never returns is
        // worse than one that leaves the thread to finish on its own.
        let deadline = Date(timeIntervalSinceNow: 2)
        while !runnerExited {
            if !runnerLock.wait(until: deadline) {
                break
            }
        }
        if !runnerExited {
            os_log(.error, "CloudAudioPlayer: runner did not exit within timeout")
        }
        runnerLock.unlock()
    }

    // MARK: - Runner loop

    @objc private func runnerLoop() {
        while true {
            runnerLock.lock()

            // Wait for work or a request. `enqueue` sets `runnerRunning`, and
            // `finish`/`cancel` set their own flags, so any of the three wakes
            // this loop.
            while !runnerRunning && !drainRemaining && !stopRequested && !shutdownRequested {
                runnerLock.wait()
            }

            if shutdownRequested {
                shutdownRequested = false
                runnerLock.unlock()
                stopEngine()
                isPlaying = false
                paused = false
                runnerLock.lock()
                runnerExited = true
                runnerLock.signal()
                runnerLock.unlock()
                return
            }

            // Cancelled: drop everything and stop the engine, without draining.
            if stopRequested {
                stopRequested = false
                runnerLock.unlock()
                stopEngine()
                isPlaying = false
                paused = false
                notifyDidStop()
                runnerLock.lock()
                runnerExited = false
                runnerLock.signal()
                runnerLock.unlock()
                continue
            }

            // Drain mode: play the rest of this turn, then go back to waiting.
            // Returning here would end the thread at the first answer — the
            // player is built once for the app session, so every later turn
            // would be silent and would leave its hold unreleased.
            if drainRemaining {
                drainRemaining = false
                runnerLock.unlock()
                drainAndStop()
                continue
            }

            // Claim the wake, then release the lock; the flag is cleared
            // *before* processing so an `enqueue` that lands mid-processing is
            // not lost — it sets the flag again and the next iteration runs.
            runnerRunning = false
            runnerLock.unlock()

            processFrames()
        }
    }

    private func processFrames() {
        // Check if we have enough frames to start/resume.
        if hasEnoughFramesToPlay {
            if !isPlaying {
                startEngine()
            }
            isPlaying = true
            paused = false
        } else if isPlaying {
            // Buffer drained below threshold — pause.
            paused = true
            isPlaying = false
            stopEngine()
            if let delegate = delegate {
                DispatchQueue.main.async {
                    delegate.audioPlayerDidPause()
                }
            }
        }

        // If not playing and not enough frames, wait.
        guard isPlaying else { return }

        // Drain as many frames as we can. The count is read under the buffer
        // lock: `cancel()` empties the buffer from another thread (a server
        // error after audio started), so a count taken outside it can outlive
        // the frames it describes.
        //
        // `playFrame` is best-effort (no engine, no output), but the frames are
        // still taken: a player that leaves them queued on an engine failure
        // would report "playing" with nothing coming out.
        let framesToProcess = bufferedFrameCount
        for _ in 0..<framesToProcess {
            guard let frame = dequeueFrame() else { break }
            playFrame(frame)
        }

        // Check if buffer drained.
        if isBufferEmpty && !drainRemaining {
            paused = true
            isPlaying = false
            stopEngine()
            if let delegate = delegate {
                DispatchQueue.main.async {
                    delegate.audioPlayerDidPause()
                }
            }
        }
    }

    private var isPlaying = false
    private var paused = false

    private var hasEnoughFramesToPlay: Bool {
        bufferedFrameCount >= Self.resumeThreshold
    }

    /// Buffered frame count, read under the lock. `buffer` is mutated from the
    /// main actor (`enqueue`/`cancel`) while the runner drains it.
    private var bufferedFrameCount: Int {
        bufferLock.lock()
        defer { bufferLock.unlock() }
        return buffer.count
    }

    private var isBufferEmpty: Bool {
        bufferLock.lock()
        defer { bufferLock.unlock() }
        return buffer.isEmpty
    }

    /// Removes the oldest frame, or `nil` when the buffer was emptied by a
    /// concurrent `cancel()`. `removeFirst()` on an empty array traps, so the
    /// emptiness is decided under the same lock as the removal.
    private func dequeueFrame() -> CloudAudioFrame? {
        bufferLock.lock()
        defer { bufferLock.unlock() }
        guard !buffer.isEmpty else { return nil }
        return buffer.removeFirst()
    }

    // MARK: - Audio engine

    private func startEngine() {
        stopEngine()

        // No output device (a test host, or a detached process): the frames are
        // still consumed by the runner, but nothing is scheduled. Creating the
        // engine in that state trips an assertion inside CoreAudio rather than
        // throwing, so the check has to come first.
        guard Self.audioOutputIsAvailable else {
            os_log(.info, "CloudAudioPlayer: no audio output available; frames will be consumed silently")
            return
        }

        let engine = AVAudioEngine()
        let playerNode = AVAudioPlayerNode()
        engine.attach(playerNode)
        // Connect with the *negotiated* format rather than `nil`: `nil` uses the
        // node's default format, which does not match mono Int16 at the
        // negotiated rate, and nothing ties the buffer to the node's format.
        let format = Self.pcmFormat(sampleRate: negotiatedSampleRate)
        engine.connect(playerNode, to: engine.mainMixerNode, format: format)

        do {
            try engine.start()
        } catch {
            os_log(.error, "CloudAudioPlayer: engine start failed: %@", error.localizedDescription)
            return
        }

        self.engine = engine
        self.playerNode = playerNode

        if let delegate = delegate {
            DispatchQueue.main.async {
                delegate.audioPlayerDidStartPlaying()
            }
        }
    }

    private func stopEngine() {
        if let engine = engine {
            engine.stop()
            engine.reset()
            engine.attachedNodes.forEach { engine.detach($0) }
        }
        playerNode = nil
        self.engine = nil
    }

    /// Appends this frame's audio to the emitted reference and records where the node had
    /// reached, mapped into the reference's own timeline.
    ///
    /// Extracted from `playFrame` so the mapping is reachable by a test: the conversion is
    /// the part that can be wrong, and it was — the node reports a position in its own
    /// played audio, which restarts each turn while the reference keeps growing, so writing
    /// it through unmapped placed second-turn audio against the wrong origin.
    ///
    /// This is the one producer that does not hand off, so it performs the same
    /// range-plus-position conversion the handoff performs for the others.
    func appendToEmittedReference(_ pcmBuffer: AVAudioPCMBuffer, node: AVAudioPlayerNode) {
        guard let reference = emittedPCMReference,
              let channel = pcmBuffer.floatChannelData?[0] else { return }

        let frame = Array(UnsafeBufferPointer(start: channel, count: Int(pcmBuffer.frameLength)))
        let resampled = PlaybackResampler.toPipelineRate(frame, sourceRate: negotiatedSampleRate)

        // Read the range BEFORE the append: this is where the block will land, and it is the
        // only correct origin for a position inside it. An interleaved producer's appends sit
        // between this producer's frames, so no per-producer offset maps them.
        let rangeStart = reference.streamIndex
        reference.append(resampled)

        let anchor = renderPosition(of: node).map { position -> PlaybackRenderAnchor in
            PlaybackRenderAnchor(
                renderedFrames: Double(
                    referenceIndexForProducerPosition(
                        rangeStart: rangeStart,
                        producerFrames: position.renderedFrames,
                        producerRate: position.sourceSampleRate,
                        blockLength: resampled.count
                    )
                ),
                sourceSampleRate: PlaybackEchoReference.pipelineSampleRate,
                hostTime: position.hostTime
            )
        }
        reference.recordRenderPosition(anchor)
    }

    private func playFrame(_ frame: CloudAudioFrame) {
        guard let node = playerNode, let engine = engine else { return }

        // Frames arrive as raw Int16 PCM in the negotiated codec. This client
        // advertises PCM only (see `CloudRouteClient.supportedCodecs`); there is
        // no Opus decoder in this path, so an Opus frame is not handled here.
        // The frame's own rate (negotiated), not `engine.inputNode`'s hardware
        // rate — reading the input node for a playback-only engine is also
        // unreliable, and on a 48 kHz device it played 24 kHz PCM at double speed.
        guard let pcmBuffer = pcmBuffer(from: frame.data, sampleRate: negotiatedSampleRate) else {
            return
        }

        // Publish what is about to be emitted, so the reference holds the audio the
        // microphone can hear. Resampled into the pipeline's rate because the filter
        // correlates in that domain.
        //
        // The node's render position is read here rather than assumed. Scheduling a
        // buffer does not mean it is audible: the node may still be playing earlier
        // audio, so the position that matters is what it has *rendered*, not what has
        // been handed to it. `playerTime(forNodeTime:)` reports that, and using it means
        // a queue lead or a restart shows up as a position jump instead of the reference
        // silently claiming audio is audible before it is.
        // Appends to the reference directly, rather than through `EchoReferenceHandoff`.
        //
        // Checked rather than assumed: this is called from the bounded drain loop above
        // (`for _ in 0..<framesToProcess { dequeueFrame(); playFrame(frame) }`), not from an
        // `AVAudioEngine` tap callback. The handoff's reason is a real-time deadline, and
        // this path has none — the drain loop yields. So this is the one producer that
        // legitimately does not hand off, and it is not an oversight. The producers that do
        // run on a deadline callback (the episode tap and the earcon) both submit instead.
        appendToEmittedReference(pcmBuffer, node: node)
        node.play()
        node.scheduleBuffer(pcmBuffer)
    }

    /// The output node's rendered position, or nil when the node is not rendering.
    ///
    /// `lastRenderTime` is the host instant of the most recent render; converting it
    /// through `playerTime(forNodeTime:)` yields the position in the played audio's own
    /// sample frames. Both are needed: the frames give the mapping onto the reference,
    /// and the host instant places it on the shared monotonic basis. A node that is not
    /// playing reports no render time, which is a discontinuity rather than a position
    /// of zero.
    private func renderPosition(of node: AVAudioPlayerNode) -> PlaybackRenderAnchor? {
        guard let lastRender = node.lastRenderTime,
              lastRender.isSampleTimeValid,
              let playerTime = node.playerTime(forNodeTime: lastRender),
              playerTime.isSampleTimeValid else { return nil }
        return PlaybackRenderAnchor(
            renderedFrames: Double(playerTime.sampleTime),
            sourceSampleRate: playerTime.sampleRate,
            hostTime: lastRender.hostTime > 0
                ? AVAudioTime.seconds(forHostTime: lastRender.hostTime)
                : 0
        )
    }

    /// Whether this process has an audio output to render into. `AVAudioEngine`
    /// asserts (rather than throwing) when a node graph is built without one,
    /// so the player checks before constructing any graph.
    static var audioOutputIsAvailable: Bool {
        #if targetEnvironment(simulator)
        // The simulator's audio unit asserts if a node graph is built before an
        // output device exists, which is the case in the test host.
        return ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil
        #else
        return true
        #endif
    }

    /// Mono Int16 PCM at `sampleRate` — the shape the negotiated `pcm_s16le`
    /// codec delivers.
    static func pcmFormat(sampleRate: Double) -> AVAudioFormat? {
        AVAudioFormat(commonFormat: .pcmFormatInt16,
                      sampleRate: sampleRate,
                      channels: AVAudioChannelCount(1),
                      interleaved: true)
    }

    private func pcmBuffer(from data: Data, sampleRate: Double) -> AVAudioPCMBuffer? {
        // Raw Int16 PCM is copied straight into the buffer. Opus would need a
        // decoder, which this path does not have.
        guard let format = Self.pcmFormat(sampleRate: sampleRate),
              let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(data.count / MemoryLayout<Int16>.size)) else {
            return nil
        }

        let int16Data = UnsafeMutableBufferPointer<Int16>(start: buffer.int16ChannelData?.pointee,
                                                          count: Int(buffer.frameCapacity))
        data.copyBytes(to: int16Data)
        buffer.frameLength = buffer.frameCapacity
        return buffer
    }

    // MARK: - Testing seams

    /// Buffered frame count, for tests that assert the runner actually consumes
    /// frames (a player that buffers forever plays nothing).
    var bufferedFrameCountForTesting: Int { bufferedFrameCount }

    /// Whether this player holds nothing left to play. A turn that produced no
    /// audio can restore immediately; one that is still draining restores when
    /// the drain completes.
    var hasPendingAudio: Bool {
        bufferLock.lock(); defer { bufferLock.unlock() }
        return !buffer.isEmpty
    }

    // MARK: - Drain

    private func drainAndStop() {
        // Play any remaining frames.
        while true {
            guard let frame = dequeueFrame() else { break }
            playFrame(frame)
        }
        stopEngine()
        isPlaying = false
        paused = false
        notifyDidStop()
    }

    /// Report that output has stopped, so the caller can restore what the turn
    /// ducked. Delivered on the main queue like the other delegate callbacks.
    private func notifyDidStop() {
        guard let delegate = delegate else { return }
        DispatchQueue.main.async {
            delegate.audioPlayerDidStop()
        }
    }
}
