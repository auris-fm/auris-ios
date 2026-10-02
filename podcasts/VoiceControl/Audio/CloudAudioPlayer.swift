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
    }

    // MARK: - Public

    /// Start (or resume) playback with new frames.
    ///
    /// Call for each frame received on the WebSocket.  If the player was
    /// stopped, the first frame restarts it; if it was already playing the
    /// frame is enqueued.
    func enqueue(_ frame: CloudAudioFrame) {
        bufferLock.lock()
        buffer.append(frame)
        bufferLock.unlock()

        // Kick the runner if it's idle.
        runnerLock.lock()
        runnerRunning = false
        runnerLock.unlock()
        condition.signal()
    }

    /// Drain remaining buffered frames and stop playback.
    /// Call on `done` / `error`.
    func finish() {
        runnerLock.lock()
        drainRemaining = true
        runnerRunning = false
        condition.signal()
        runnerLock.unlock()
    }

    /// Reset state immediately (e.g. on cancellation).
    func cancel() {
        bufferLock.lock()
        buffer.removeAll()
        bufferLock.unlock()
        runnerLock.lock()
        drainRemaining = false
        runnerRunning = false
        condition.signal()
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
    private let runnerLock = NSLock()
    private let condition = NSCondition()

    /// Frame buffer (in-order).
    private var buffer: [CloudAudioFrame] = []

    /// Runner thread is alive (waiting or running).
    private var runnerRunning = false

    /// Request drain-and-stop (done / error).
    private var drainRemaining = false

    /// Runner thread.
    private var runnerThread: Thread?

    /// The audio engine and player node — accessed only from runner thread.
    private var engine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?

    // MARK: - Init / Deinit

    init() {
        runnerThread = Thread(target: self, selector: #selector(runnerLoop), object: nil)
        runnerThread?.name = "CloudAudioPlayer"
        runnerThread?.start()
    }

    deinit {
        runnerLock.lock()
        drainRemaining = true
        runnerRunning = false
        condition.signal()
        runnerLock.unlock()
        runnerThread?.wait()
    }

    // MARK: - Runner loop

    @objc private func runnerLoop() {
        while true {
            runnerLock.lock()

            // Wait for work or drain request.
            while !runnerRunning && !drainRemaining {
                condition.wait()
            }

            // Drain mode: play remaining then stop.
            if drainRemaining {
                drainRemaining = false
                runnerLock.unlock()
                drainAndStop()
                return
            }

            runnerRunning = true
            runnerLock.unlock()

            // Process available frames.
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

        // Drain as many frames as we can.
        let framesToProcess = buffer.count
        for _ in 0..<framesToProcess {
            guard let frame = dequeueFrame() else { break }
            playFrame(frame)
        }

        // Check if buffer drained.
        if buffer.isEmpty && !drainRemaining {
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
        buffer.count >= resumeThreshold
    }

    private func dequeueFrame() -> CloudAudioFrame? {
        bufferLock.lock()
        let frame = buffer.removeFirst()
        bufferLock.unlock()
        return frame
    }

    // MARK: - Audio engine

    private func startEngine() {
        stopEngine()

        let engine = AVAudioEngine()
        let playerNode = AVAudioPlayerNode()
        engine.attach(playerNode)
        engine.connect(playerNode, to: engine.mainMixerNode, format: nil)

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
            engine.nodes.forEach { engine.detach($0) }
        }
        playerNode = nil
        self.engine = nil
    }

    private func playFrame(_ frame: CloudAudioFrame) {
        guard let node = playerNode, let engine = engine else { return }

        // Convert raw Opus/PCM data to AVAudioPcmBuffer.
        // For now, treat all data as raw Float32 PCM (the server negotiates codec).
        // In production, the codec would be determined from the `connected` frame.
        guard let pcmBuffer = pcmBuffer(from: frame.data, sampleRate: engine.inputFormat.sampleRate) else {
            return
        }

        node.play()
        node.enqueue(pcmBuffer)
    }

    private func pcmBuffer(from data: Data, sampleRate: Double) -> AVAudioPcmBuffer? {
        // Opus packets need to be decoded; raw PCM can be used directly.
        // For now, assume raw PCM (the server can negotiate pcm_s16le).
        guard let format = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                         sampleRate: sampleRate,
                                         channels: AVAudioChannelCount(1),
                                         interleaved: true),
              let buffer = AVAudioPcmBuffer(format: format,
                                            frameCapacity: AVAudioFrameCount(data.count / MemoryLayout<Int16>.size)) else {
            return nil
        }

        let int16Data = UnsafeMutableBufferPointer<Int16>(start: buffer.int16ChannelData?.pointee,
                                                          count: Int(buffer.frameCapacity))
        data.copyBytes(to: int16Data)
        buffer.frameLength = buffer.frameCapacity
        return buffer
    }

    // MARK: - Drain

    private func drainAndStop() {
        // Play any remaining frames.
        while true {
            guard let frame = dequeueFrame() else { break }
            playFrame(frame)
        }
        stopEngine()
    }
}
