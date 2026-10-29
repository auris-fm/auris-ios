import AVFoundation
import Foundation
import PocketCastsUtils
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
        /// `drainEpoch` is the identity of the drain this notification belongs to, pinned when the
        /// drain was SCHEDULED. Delivery is asynchronous, so an identity taken at delivery time
        /// would belong to whichever drain is current then.
        func audioPlayerDidStop(drainEpoch: Int)
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
        if timingEnabled {
            timingQueuedBytes += frame.data.count
            if let trace = frame.timingReceipt?.trace { timingLastQueued = trace }
        }
        let timingQueue = (timingQueuedBytes, buffer.count)
        // A CUMULATIVE record of every frame this player was actually handed. `bufferedFrameCount`
        // is a current depth that drains, so after a turn ends it cannot distinguish "audio was
        // delivered and played" from "audio never arrived" — which made an output assertion
        // vacuous. This counts arrivals and never decreases.
        framesEnqueued += 1
        bufferLock.unlock()

        frame.timingReceipt?.trace.observe("enqueue", receipt: frame.timingReceipt) {
            CloudPlaybackTiming.Snapshot(queuedBytes: timingQueue.0, queuedFrames: timingQueue.1)
        }

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
    /// Schedule the drain and RETURN the identity it allocated. The caller must record that
    /// returned value rather than re-reading `currentDrainEpoch`: a re-read can observe a LATER
    /// schedule, so the deferral would wait on an identity that is not its own.
    @discardableResult
    func finish() -> Int {
        finishWithStopBinding().requestEpoch
    }

    struct DrainRequest {
        let requestEpoch: Int
        /// A physical stop at or after this epoch quiesces this request. A later cancel may
        /// supersede that owner; the request itself still settles separately as superseded.
        let stopEpoch: Int
    }

    /// Publishes the request and captures its notifiable stop binding under the SAME lock.
    /// If a physical stop has already claimed/cleared its owner, this schedules a new drain,
    /// rather than binding to zero or borrowing an older pending notification.
    func finishWithStopBinding() -> DrainRequest {
        runnerLock.lock()
        // Same atomic coalescing as cancel(): the check and the publication share one
        // critical section, so the runner cannot complete a decrement before the increment.
        let sharesNotification = stopRequested || drainRemaining || drainClaimInFlight
        drainEpoch += 1
        let allocated = drainEpoch
        // OWNERSHIP: a finish queued while a stop is already requested can never perform its
        // own physical stop — the pending stop (whose owner is earlier) supersedes it at the
        // queue level, so it is recorded as superseded rather than left ambiguous.
        if stopRequested || drainClaimInFlight {
            supersededStopRequests.insert(allocated)
        } else if drainRemaining {
            // A drain is already pending/claimed: this finish COALESCES onto that drain's
            // single physical stop (the owner keeps its identity — review dc70303d: a newer
            // queued finish is not "stopped" for being newer). It settles as superseded when
            // that stop lands, satisfying its waiter without a second stop.
            supersededStopRequests.insert(allocated)
        } else {
            stopOwnerEpoch = allocated
        }
        // Re-queue work ONLY when this finish is the one that will be physically served. A
        // coalesced finish (stop requested or a claim in flight) must not re-arm the runner:
        // the pending/in-flight stop is the quiescent end for it too, and a re-queued drain
        // would produce a SECOND physical stop after the coalescing that was supposed to
        // make this request settled — exactly the second-stop bug the ownership design bans.
        if !stopRequested && !drainClaimInFlight {
            drainRemaining = true
        }
        runnerRunning = true
        if !sharesNotification { pendingStopNotifications += 1 }
        let request = DrainRequest(requestEpoch: allocated, stopEpoch: stopOwnerEpoch)
        runnerLock.signal()
        runnerLock.unlock()
        return request
    }

    /// Reset state immediately (e.g. on cancellation).
    ///
    /// Stops the engine as well as dropping the buffered frames: a buffer
    /// already handed to `scheduleBuffer` keeps playing otherwise, so the tail
    /// of an abandoned answer would play over the error feedback and
    /// `isPlaying`/`paused` would stay true into the next turn (whose first
    /// frames are then treated as an underrun). The runner thread owns the
    /// engine, so the stop is done in drain mode.
    /// Cancels output and returns the identity whose stop notification will follow the ACTUAL
    /// engine stop. Callers that must release a grace hold / resume host playback only after the
    /// real stop await this epoch's confirmation (`awaitActualStop(after:)`) — `cancel` only
    /// REQUESTS the stop; it does not report one.
    /// TEST-ONLY observation: how many times `cancel()` was requested on this shared player.
    /// Lets a control pin "this path never touches the shared player" without depending on
    /// epoch arithmetic (which races concurrent finish/drain scheduling).
    private(set) var cancelRequestCountForTesting = 0
    @discardableResult
    func cancel() -> Int {
        cancelRequestCountForTesting += 1
        bufferLock.lock()
        buffer.removeAll()
        if timingEnabled { timingQueuedBytes = 0 }
        bufferClearCountForTesting += 1
        bufferLock.unlock()
        runnerLock.lock()
        // COALESCED ACCOUNTING (review 4fc59e2c): cancel/finish coalesce through the runner's
        // boolean flags — several requests can share ONE processed stop and ONE notification.
        // An increment per REQUEST would strand the counter positive forever (a successor would
        // then be refused on every admission). Increment only when this request transitions the
        // runner from not-queued to queued; the single notification settles it.
        // COALESCED ACCOUNTING, ATOMIC (review 8eb9fb44): cancel/finish coalesce through the
        // runner's boolean flags — several requests can share ONE processed stop and ONE
        // notification. The pending-notification count is incremented INSIDE the same critical
        // section that signals the runner: the runner can never observe the signal and complete
        // its decrement before the increment is published (that race stranded the counter
        // positive forever).
        let sharesNotification = stopRequested || drainRemaining || drainClaimInFlight
        drainEpoch += 1
        let requestedEpoch = drainEpoch
        // OWNERSHIP: this cancel's stop SUPERSEDES whatever drain/finish was queued — the
        // queued request never performs its own physical stop (review dc70303d: settle only
        // cancellation requests actually satisfied by this physical stop; a superseded
        // finish is not marked stopped for being sequence-newer — it is settled as superseded).
        if stopRequested || drainRemaining || drainClaimInFlight {
            // The in-flight claim counts too: its owner's identity must be EXPLICITLY
            // recorded as displaced, never left to be satisfied incidentally by a sweep.
            let displacedOwner = stopOwnerEpoch
            if displacedOwner != 0 { supersededStopRequests.insert(displacedOwner) }
        }
        stopOwnerEpoch = requestedEpoch
        drainRemaining = false
        stopRequested = true
        runnerRunning = true
        if !sharesNotification { pendingStopNotifications += 1 }
        runnerLock.signal()
        runnerLock.unlock()
        return requestedEpoch
    }

    /// The identity of the most recent CONFIRMED stop (the engine actually stopped and the stop
    /// notification was issued). Guarded by the buffer lock; written from the runner/main paths.
    func confirmedStopEpoch() -> Int {
        bufferLock.lock()
        defer { bufferLock.unlock() }
        return lastConfirmedStopEpoch
    }

    /// Waits (bounded) for the ACTUAL stop of `epoch` — the identity-bound completion a caller
    /// needs before releasing a grace hold or resuming host playback. Each await gets its OWN
    /// ticket (a UUID, not an epoch key), created BEFORE the cancellation handler is installed,
    /// so a cancellation that races registration can never strand a later-registered waiter:
    /// the ticket's cancel state is observable at registration time. Tickets are removed on
    /// every exit path — confirmation, timeout, and cancellation — so the registry holds only
    /// genuinely parked waiters. The caller's actor is never polled: the confirmation resumes
    /// the waiter directly.
    func awaitActualStop(after epoch: Int, timeout: TimeInterval = 2) async -> Bool {
        bufferLock.lock()
        let preSettled = settledDisplacedIdentities.contains(epoch)
        bufferLock.unlock()
        if preSettled || confirmedStopEpoch() >= epoch { return true }
        // PRECREATE the ticket before the handler: cancel-before-register flips this flag, and
        // registration observes it instead of parking.
        let ticket = StopWaiterTicket(epoch: epoch)
        return await withTaskCancellationHandler {
            await withTaskGroup(of: Bool.self) { group in
                group.addTask { await self.waitAsStopWaiter(ticket) }
                group.addTask {
                    try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    if Task.isCancelled { return false }
                    let confirmed = await self.confirmStopForBoundWaiter(ticket)
                    if confirmed { self.removeStopTicket(ticket) }
                    return confirmed
                }
                let first = await group.next() ?? false
                group.cancelAll()
                // FORCE-CLEAN the ticket before awaiting the loser: if the loser child is the
                // registration child and it parks after a post-handler cancellation was missed,
                // this removal resumes it false — the sweep can never strand on its own waiter.
                if let continuation = self.forceRemoveStopTicket(ticket) {
                    continuation.resume(returning: false)
                }
                _ = await group.next()
                self.removeStopTicket(ticket)
                return first
            }
        } onCancel: {
            self.cancelStopTicket(ticket)
        }
    }

    /// One await's registration state. A class so the cancellation handler and the registration
    /// closure share the SAME object identity; the flag is the cancel-before-register marker.
    private final class StopWaiterTicket: @unchecked Sendable {
        let epoch: Int
        let id = UUID()
        var continuation: CheckedContinuation<Bool, Never>?
        var cancelled = false
        private let lock = NSLock()
        init(epoch: Int) { self.epoch = epoch }
        func setContinuation(_ c: CheckedContinuation<Bool, Never>) -> Bool {
            lock.lock(); defer { lock.unlock() }
            if cancelled { return false }
            continuation = c
            return true
        }
        func takeContinuation() -> CheckedContinuation<Bool, Never>? {
            lock.lock(); defer { lock.unlock() }
            let c = continuation
            continuation = nil
            return c
        }
        func markCancelled() -> CheckedContinuation<Bool, Never>? {
            lock.lock(); defer { lock.unlock() }
            cancelled = true
            let c = continuation
            continuation = nil
            return c
        }
    }

    // Registry, guarded by the buffer lock. Keyed by the ticket's UUID — NEVER by epoch, so two
    // concurrent waiters on one identity cannot overwrite each other and a cancellation can
    // never resume the WRONG waiter.
    private var stopWaiters: [UUID: StopWaiterTicket] = [:]

    private func waitAsStopWaiter(_ ticket: StopWaiterTicket) async -> Bool {
        // The GROUP cancels this child on sweep; the child must clean up its OWN ticket —
        // withCheckedContinuation alone would strand the parked continuation and hang the sweep.
        await withTaskCancellationHandler {
            await waitAsStopWaiterBody(ticket)
        } onCancel: {
            cancelStopTicket(ticket)
        }
    }

    /// TEST-ONLY, NON-CANCELLATION-SENSITIVE latch run immediately BEFORE ticket registration.
    /// A control parks here, cancels the owning task (so the cancellation handler runs BEFORE
    /// registration), then releases — making the cancel-before-register ordering DETERMINISTIC
    /// instead of a scheduling race (review fa03b7f9/3b2d4386). Never installed in production.
    var preRegistrationLatchForTesting: (() async -> Void)?

    private func waitAsStopWaiterBody(_ ticket: StopWaiterTicket) async -> Bool {
        if let latch = preRegistrationLatchForTesting { await latch() }
        let registered: Bool = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) -> Void in
            bufferLock.lock()
            // Confirmed while we were registering? Resume immediately.
            if lastConfirmedStopEpoch >= ticket.epoch
                || settledDisplacedIdentities.contains(ticket.epoch) {
                bufferLock.unlock()
                continuation.resume(returning: true)
                return
            }
            guard ticket.setContinuation(continuation) else {
                // Cancelled before we registered: the handler already ran; do not park.
                bufferLock.unlock()
                continuation.resume(returning: false)
                return
            }
            stopWaiters[ticket.id] = ticket
            bufferLock.unlock()
        }
        return registered
    }

    private func cancelStopTicket(_ ticket: StopWaiterTicket) {
        bufferLock.lock()
        stopWaiters.removeValue(forKey: ticket.id)
        bufferLock.unlock()
        if let continuation = ticket.markCancelled() {
            continuation.resume(returning: false)
        }
    }

    private func removeStopTicket(_ ticket: StopWaiterTicket) {
        bufferLock.lock()
        stopWaiters.removeValue(forKey: ticket.id)
        bufferLock.unlock()
    }

    /// Removes the ticket AND takes its continuation (if registered) for the caller to resume.
    private func forceRemoveStopTicket(_ ticket: StopWaiterTicket) -> CheckedContinuation<Bool, Never>? {
        bufferLock.lock()
        stopWaiters.removeValue(forKey: ticket.id)
        bufferLock.unlock()
        return ticket.takeContinuation()
    }

    private func resumeStopWaiters(upTo epoch: Int) {
        bufferLock.lock()
        var resumed: [CheckedContinuation<Bool, Never>] = []
        for (id, ticket) in stopWaiters where ticket.epoch <= epoch {
            stopWaiters.removeValue(forKey: id)
            if let continuation = ticket.takeContinuation() {
                resumed.append(continuation)
            }
        }
        bufferLock.unlock()
        for continuation in resumed { continuation.resume(returning: true) }
    }

    private func confirmStopForBoundWaiter(_ ticket: StopWaiterTicket) async -> Bool {
        bufferLock.lock()
        let settled = settledDisplacedIdentities.contains(ticket.epoch)
        bufferLock.unlock()
        return settled || confirmedStopEpoch() >= ticket.epoch
    }

    private func confirmStopForBoundWaiter(_ epoch: Int) async -> Bool {
        bufferLock.lock()
        let settled = settledDisplacedIdentities.contains(epoch)
        bufferLock.unlock()
        return settled || confirmedStopEpoch() >= epoch
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
    // Queue metadata is guarded by bufferLock. Runner metadata is touched only on the runner.
    private var timingQueuedBytes = 0
    private var timingLastQueued: CloudPlaybackTiming?
    private var timingActive: CloudPlaybackTiming?
    private var timingScheduledFrames = 0.0
    var onNaturalCatchUpForTesting: ((Double) -> Void)?
    private(set) var timingSnapshotsForTesting = 0
    var timingQueuedBytesForTesting: Int {
        bufferLock.lock(); defer { bufferLock.unlock() }
        return timingQueuedBytes
    }
    private let timingEnabled: Bool
    private let timingPlayerID: String?

    private func observeTiming(_ stage: String, reason: String? = nil, terminal: Bool = false) {
        guard timingEnabled else { return }
        bufferLock.lock()
        let queue = (timingQueuedBytes, buffer.count)
        let trace = timingActive ?? timingLastQueued
        bufferLock.unlock()
        trace?.observe(stage, terminal: terminal) {
            self.timingSnapshotsForTesting += 1
            return CloudPlaybackTiming.Snapshot(player: self.timingPlayerID, generation: self.nodeIncarnation,
                queuedBytes: queue.0, queuedFrames: queue.1, scheduledFrames: stage == "stopped" ? nil : self.timingScheduledFrames,
                renderedFrames: self.playerNode.flatMap { self.renderPosition(of: $0)?.renderedFrames },
                sampleRate: self.negotiatedSampleRate, reason: reason)
        }
        if terminal { timingActive = nil }
    }

    /// Codec negotiated in the server's `connected` frame (guarded by
    /// `bufferLock`, written on the main actor and read on the runner thread).
    private var negotiatedCodec: CloudAudioCodec?

    /// Sample rate the negotiated codec delivers, defaulting to the advertised
    /// codec's rate when no `connected` frame has been seen yet.
    var negotiatedSampleRateForTesting: Double { negotiatedSampleRate }
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

    /// Identity of the drain most recently SCHEDULED, incremented in `finish()`/`cancel()`.
    private var drainEpoch = 0

    /// Request an immediate stop without draining (cancel).
    private var stopRequested = false

    /// OWNED-STOP RECORD (spec a9e27935 / review dc70303d): which REQUESTED identity physically
    /// owns the next stop the runner performs, and which requested identities that single
    /// physical stop SUPERSEDES. `cancel()`/`finish()` publish ownership under `runnerLock` at
    /// request time; the runner consumes it AT the physical stop and confirms exactly the
    /// owner's identity once. A superseded request settles through its own terminal path —
    /// it is never relabelled onto another operation's stop, and never promoted by a later
    /// stop it did not perform.
    private var stopOwnerEpoch: Int = 0
    /// Requested identities superseded by the CURRENT stop owner (guard: runnerLock).
    private var supersededStopRequests: Set<Int> = []
    /// A claimed drain is IN FLIGHT (claim made, physical stop not yet performed). The claim
    /// consumed `drainRemaining`, so request sites can no longer see it — this flag keeps the
    /// ownership record honest until the stop consumes it (guard: runnerLock).
    private var drainClaimInFlight = false
    /// Explicitly settled displaced identities (guard: bufferLock). Retained so a waiter that
    /// registers AFTER its settlement can still resolve from the retained fact — settlement is
    /// terminal for exactly these identities, and no max/upTo shortcut is restored.
    private var settledDisplacedIdentities: Set<Int> = []
    /// TEST-ONLY RESCUE: resumes EVERY registered waiter false and clears the registry. A
    /// control uses this to reap a (mutant-)stranded waiter after its bounded completion probe
    /// failed, so the test process never hangs on a leaked continuation.
    func rescueStopWaitersForTesting() {
        bufferLock.lock()
        let tickets = Array(stopWaiters.values)
        stopWaiters.removeAll()
        bufferLock.unlock()
        for ticket in tickets {
            if let continuation = ticket.takeContinuation() {
                continuation.resume(returning: false)
            }
        }
    }

    /// TEST OBSERVABILITY: the registry must hold ZERO tickets after every exit path
    /// (confirmation, timeout, cancellation) — a stranded ticket is a leaked continuation.
    var stopWaiterCountForTesting: Int {
        bufferLock.lock()
        defer { bufferLock.unlock() }
        return stopWaiters.count
    }

    /// The most recent stop the engine CONFIRMED (see `notifyDidStop`).
    private var lastConfirmedStopEpoch = 0

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

    /// The shared handoff that records block ranges for every OTHER producer (earcon, episode
    /// tap). The cloud producer appends its own audio directly (it is not on a real-time
    /// callback), but it publishes its render positions THROUGH the handoff, so a position is
    /// mapped against the block that contains it rather than assumed to equal one block
    /// (PR #49 review comment 4305981528). Nil in builds/tests without a handoff, where the
    /// player falls back to its own last-appended range.
    weak var echoReferenceHandoff: EchoReferenceHandoff?
    /// Test-visible view of the wiring above. The handoff is `weak` because the assembly owns it
    /// for the session, so a case that wants to drive or drain it needs the same object rather
    /// than a locally constructed stand-in — two mappings would each see part of the stream.
    var echoReferenceHandoffForTesting: EchoReferenceHandoff? { echoReferenceHandoff }

    /// This producer's clock identity within the shared reference. `nodeIncarnation` advances
    /// every time the engine is rebuilt — each turn gets a fresh `AVAudioPlayerNode` whose frame
    /// counter returns to zero — so a position from a retired node is refused by the handoff's
    /// active-incarnation boundary instead of matching a previous turn's blocks.
    private var nodeIncarnation: UInt64 = 0
    var producerIdentityForTesting: EchoReferenceHandoff.ProducerIdentity {
        EchoReferenceHandoff.ProducerIdentity(kind: .cloud, incarnation: nodeIncarnation)
    }

    init(timingEnabled: Bool = CloudPlaybackTiming.isEnabled(environment: ProcessInfo.processInfo.environment)) {
        self.timingEnabled = timingEnabled
        timingPlayerID = timingEnabled ? UUID().uuidString : nil
        runnerThread = Thread(target: self, selector: #selector(runnerLoop), object: nil)
        runnerThread?.name = "CloudAudioPlayer"
        runnerThread?.start()
    }

    /// Tests must join this session-long worker rather than leave diagnostic callbacks live.
    func shutdownForTimingTesting() -> Bool {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil else { return false }
        runnerLock.lock()
        defer { runnerLock.unlock() }
        if runnerExited { return true }
        shutdownRequested = true
        runnerRunning = true
        runnerLock.signal()
        let deadline = Date().addingTimeInterval(2)
        while !runnerExited {
            if !runnerLock.wait(until: deadline) { break }
        }
        return runnerExited
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
            // `finish`/`cancel` set their own flags, so any of the three wake
            // this loop.
            //
            // Render catch-up (@spec contract, PR #49): when the buffer emptied but the node
            // still has scheduled-unrendered audio, the engine stays alive and the wait is
            // BOUNDED by the pending audio's duration, so the runner re-enters processFrames
            // to re-check measured render progress — queue emptiness alone must not stop or
            // rotate away still-pending audible work.
            while !runnerRunning && !drainRemaining && !stopRequested && !shutdownRequested {
                // A timer expiry is work too: recheck rendered output without waiting for
                // another socket frame. Reusing the expired date here spins under runnerLock.
                if !runnerLock.wait(until: renderCatchUpWake ?? .distantFuture) { break }
            }
            renderCatchUpWake = nil

            if shutdownRequested {
                shutdownRequested = false
                runnerLock.unlock()
                stopEngine(reason: "shutdown", terminal: true)
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
                // CANONICAL QUIESCENCE (review 9a093876/d2561f9b): a cancel stop SUPERSEDES any
                // queued drain — a finish that landed after the cancel re-queued
                // `drainRemaining` while `stopRequested` was still true; leaving it set would
                // make the runner run a SECOND stop after this one, and a successor admitted on
                // this stop's confirmation would be shed by that second stop. The cancel's stop
                // IS the quiescent end of everything queued before it.
                drainRemaining = false
                // OWNED-STOP: consume the published owner + superseded set under runnerLock.
                let scheduledEpoch = stopOwnerEpoch
                let displaced = supersededStopRequests
                supersededStopRequests = []
                stopOwnerEpoch = 0
                runnerLock.unlock()
                physicalStopGateWait()
                stopEngine(reason: "cancel", terminal: true)
                isPlaying = false
                paused = false
                notifyDidStop(epoch: scheduledEpoch)
                settleSupersededRequests(displaced)
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
                // SNAPSHOT AT THE CLAIM, then RELEASE THE LOCK BEFORE any barrier. Holding
                // `runnerLock` across `claimRelease.wait()` would block the test's own `finish()`,
                // which needs the same lock — a lock must never span a barrier.
                let claimedEpoch = drainEpoch
                drainClaimInFlight = true
                runnerLock.unlock()
                claimReached?.signal()
                // BOUNDED: a setup error must fail promptly, not consume the runner forever.
                // The release outcome is RECORDED, not discarded: a bound alone does not make a
                // timeout a failure, so the case asserts this value.
                if let release = claimRelease {
                    // FALSIFICATION: a much shorter bound, and the test's signal is too late.
                    claimReleaseOutcome = (release.wait(timeout: .now() + 5) == .success) ? .released : .timedOut
                }
                drainAndStop(claimedEpoch: claimedEpoch)
                continue
            }

            // Claim the wake, then release the lock; the flag is cleared
            // *before* processing so an `enqueue` that lands mid-processing is
            // not lost — it sets the flag again and the next iteration runs.
            runnerRunning = false
            let recheck = renderCatchUpRecheckForTesting
            renderCatchUpRecheckForTesting = nil
            runnerLock.unlock()

            processFrames()
            recheck?()
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
            renderStopDeadline = nil
        } else if isPlaying && pendingAudibleOrUnverified {
            // Buffer drained below threshold, but scheduled audio may still be rendering (or the
            // node has not reported progress yet). Pausing here rotated the incarnation away from
            // ranges whose audio had not been heard — the defect under review. Stay playing; the
            // drain check below owns the bounded catch-up stop.
        } else if isPlaying {
            // Buffer drained below threshold with nothing audible pending — pause.
            paused = true
            isPlaying = false
            renderStopDeadline = nil
            stopEngine(reason: "underrun", terminal: false)
            if let delegate {
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
        parkIfHeld()
        let framesToProcess = bufferedFrameCount
        for _ in 0..<framesToProcess {
            guard let frame = dequeueFrame() else { break }
            playFrame(frame)
        }

        // Check if buffer drained.
        //
        // Queue emptiness is NOT proof that the scheduled audio finished rendering (@spec
        // contract, PR #49 review round): stopping here discarded still-pending audible work
        // and rotated the incarnation away from ranges whose audio had not been heard yet.
        // Stop only when MEASURED render progress has caught up with what was scheduled;
        // otherwise keep the engine alive and wake the runner when catch-up is due.
        if isBufferEmpty && !drainRemaining {
            // No engine: nothing can be pending.
            if playerNode == nil {
                paused = true
                isPlaying = false
                if let delegate {
                    DispatchQueue.main.async {
                        delegate.audioPlayerDidPause()
                    }
                }
                return
            }
            // Measured progress, if the node reports one yet. Just after a scheduling burst the
            // node has not rendered its first quantum, so an UNREADABLE position is UNKNOWN, not
            // finished — treating it as finished is what discarded audible work. Unknown keeps
            // the engine alive, bounded: if no reading appears within twice the scheduled span
            // (a degraded engine), stop anyway rather than leak the engine forever.
            let scheduled = nodeIncarnationFrames
            let deadline = renderStopDeadline ?? Date().addingTimeInterval(
                scheduled / negotiatedSampleRate * 2.0 + 1.0
            )
            if let position = renderPosition(of: playerNode!)?.renderedFrames,
               position >= scheduled {
                paused = true
                isPlaying = false
                renderStopDeadline = nil
                stopEngine(reason: "render_caught_up", terminal: false)
                if let delegate {
                    DispatchQueue.main.async {
                        delegate.audioPlayerDidPause()
                    }
                }
            } else if Date() >= deadline {
                paused = true
                isPlaying = false
                renderStopDeadline = nil
                stopEngine(reason: "render_timeout", terminal: false)
                if let delegate {
                    DispatchQueue.main.async {
                        delegate.audioPlayerDidPause()
                    }
                }
            } else {
                renderStopDeadline = deadline
                runnerLock.lock()
                renderCatchUpWake = Date().addingTimeInterval(0.05)
                runnerLock.unlock()
            }
        }
    }

    /// Whether audible work may still be in flight: either the node reports unrendered scheduled
    /// audio, or it has not reported progress at all yet (unknown — conservatively pending).
    private var pendingAudibleOrUnverified: Bool {
        guard let node = playerNode else { return false }
        guard let position = renderPosition(of: node)?.renderedFrames else {
            return nodeIncarnationFrames > 0
        }
        return position < nodeIncarnationFrames
    }

    /// When the runner should wake to re-check render catch-up. Guarded by runnerLock; nil means
    /// wait for the next event.
    private var renderCatchUpWake: Date?

    /// Hard bound for keeping an engine alive on unverified pending audio. Runner-thread only.
    private var renderStopDeadline: Date?

    /// Authoritative playback-active state under the RUNNER lock: every writer (runner loop,
    /// processFrames) and every admission-gating reader synchronize here (review 8eb9fb44).
    /// No write site holds the lock (the runner unlocks before engine operations), so the
    /// computed accessor's own locking is safe everywhere.
    private var playbackActiveStorage = false
    private(set) var isPlaying: Bool {
        get { runnerLock.lock(); defer { runnerLock.unlock() }; return playbackActiveStorage }
        set { runnerLock.lock(); playbackActiveStorage = newValue; runnerLock.unlock() }
    }
    /// Stop requests queued but not yet processed by the runner (review 14f66b72/05d27ddb):
    /// a queued stop is INVISIBLE to buffer/isPlaying once the buffer is cleared but before the
    /// runner acts — a successor that skips its quiescence wait on that window would be shed by
    /// the queued stop. Incremented by every cancel/finish (each is followed by exactly one
    /// stop notification); decremented when that notification is issued.
    /// Pending stop NOTIFICATIONS, owned by the RUNNER lock together with the queued flags:
    /// request publication and runner completion can never interleave across two locks
    /// (review 8eb9fb44). Incremented at request time in the same critical section that
    /// signals the runner; decremented when the stop notification is issued.
    private var pendingStopNotifications = 0
    /// Test-only: how many times cancel() cleared the buffer (each retire shed buffered audio).
    private(set) var bufferClearCountForTesting = 0
    var hasQueuedStop: Bool {
        runnerLock.lock()
        defer { runnerLock.unlock() }
        return stopRequested || drainRemaining || pendingStopNotifications > 0
    }
    private func stopRequestSettled() {
        runnerLock.lock()
        pendingStopNotifications = max(0, pendingStopNotifications - 1)
        runnerLock.unlock()
    }
    /// Outstanding-output signal for admission gating (review 14f66b72): frames buffered OR the
    /// engine still up — a queued-but-unprocessed stop keeps `isPlaying` true until the runner
    /// processes it, so a successor can detect "a stop is still in flight" and must not skip
    /// its quiescence await.
    var hasOutstandingOutput: Bool {
        hasPendingAudio || isPlaying || hasQueuedStop
    }
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
        let frame = buffer.removeFirst()
        if timingEnabled { timingQueuedBytes -= frame.data.count }
        return frame
    }

    /// TEST-ONLY: park the drain runner until released, WITHOUT returning an exhaustion sentinel.
    ///
    /// An earlier version returned `nil` from `dequeueFrame` while held. That is indistinguishable
    /// from "the buffer is empty", so the drain loop treated a deliberately-held player as an
    /// underrun and took its exhaustion path — which is why a resume appeared while audio was
    /// nominally pending. Parking here leaves the buffer intact and simply does not consume.
    private func parkIfHeld() {
        // ONE synchronization domain for the flag: `runnerLock` guards `drainHoldRequested` for
        // every read and write, including the condition wait that releases the park.
        //
        // An earlier version read the flag under `bufferLock` for its first check and then RE-READ
        // it under `runnerLock`, so the same variable had two domains and the two reads could
        // disagree. (It did release `bufferLock` before waiting; the second flag read under the
        // wrong lock was the defect.)
        runnerLock.lock()
        while drainHoldRequested {
            runnerLock.wait(until: Date().addingTimeInterval(0.01))
        }
        runnerLock.unlock()
    }

    // MARK: - Audio engine

    private func startEngine() {
        stopEngine(reason: "restart", terminal: false)
        if timingEnabled {
            bufferLock.lock()
            timingActive = buffer.first?.timingReceipt?.trace
            bufferLock.unlock()
        }

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
            // A test can supply an offline output while retaining this real engine/node graph.
            if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
                try Self.configureEngineForTesting?(engine)
            }
            try engine.start()
        } catch {
            os_log(.error, "CloudAudioPlayer: engine start failed: %@", error.localizedDescription)
            return
        }

        self.engine = engine
        self.playerNode = playerNode
        observeTiming("start")

        if let delegate {
            DispatchQueue.main.async {
                delegate.audioPlayerDidStartPlaying()
            }
        }
    }

    private func stopEngine(reason: String, terminal: Bool = false) {
        // Either natural branch can observe catch-up: the early underrun check can win
        // before the later render_caught_up check. Capture the actual position before either
        // resets the node; production has no hook and performs no extra progress read.
        if let onNaturalCatchUpForTesting,
           reason == "underrun" || reason == "render_caught_up",
           ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil,
           let node = playerNode, let position = renderPosition(of: node)?.renderedFrames,
           position >= nodeIncarnationFrames {
            onNaturalCatchUpForTesting(position)
        }
        // Capture readable progress before resetting the node; no player lock is held here.
        if engine != nil { observeTiming("stop_requested", reason: reason) }
        if let engine {
            engine.stop()
            engine.reset()
            // Detach only the nodes THIS class attached. `attachedNodes` also reports the
            // mixer and the output node, which are the engine's own internal graph: detaching
            // an internal node raises `!IsInternalNode(node)` once the engine has rendered
            // through them (observed under offline rendering; a real-time-only teardown
            // happened to tolerate it), so blanket-detaching every attached node crashes
            // teardown instead of just releasing the graph.
            if let playerNode {
                engine.detach(playerNode)
            }
        }
        playerNode = nil
        self.engine = nil
        if timingEnabled {
            observeTiming("stopped", reason: reason, terminal: terminal)
            timingScheduledFrames = 0
        }
        // The next start builds a NEW node whose frame count restarts at zero, so this
        // producer's clock identity rotates here — at the point the counter actually resets —
        // and the handoff refuses positions from the retired incarnation. The running block
        // count returns to zero with it.
        nodeIncarnation &+= 1
        nodeIncarnationFrames = 0
        echoReferenceHandoff?.rotateIncarnation(for: .cloud, to: nodeIncarnation)
    }

    /// Appends this frame's audio to the emitted reference and publishes where the node has
    /// rendered, mapped through the block that CONTAINS that position.
    ///
    /// Extracted from `playFrame` so the mapping is reachable by a test: the conversion is
    /// the part that can be wrong, and it was — the node reports a position in its own
    /// played audio, which restarts each turn while the reference keeps growing, so writing
    /// it through unmapped placed second-turn audio against the wrong origin.
    ///
    /// This producer appends its samples directly (it runs on the runner thread, not a
    /// real-time deadline callback), but it records its block ranges with the shared handoff
    /// and submits positions THROUGH the handoff, like every other producer. The previous
    /// version assumed the just-appended block was the one being rendered —
    /// `progressInProducer ≡ one block` — which fails under queue lead: the append happens
    /// BEFORE `scheduleBuffer`, and the node is still rendering an earlier block, so the anchor
    /// ran ahead of the emitted audio and bleed could not correlate (PR #49 review comment
    /// 4305981528). Mapping through the containing block is what the handoff already does for
    /// the tap and earcon producers; using it here makes all three use one mapping.
    func appendToEmittedReference(_ pcmBuffer: AVAudioPCMBuffer, node: AVAudioPlayerNode) {
        guard let reference = emittedPCMReference else { return }

        // The player's own buffers are Int16 (see `pcmFormat`), whose `floatChannelData` is nil.
        // Read whichever channel layout the buffer carries: playFrame produces Int16, and the
        // tap-shaped float buffers some callers pass are read as before. A nil on BOTH means the
        // buffer carries no readable channel and there is nothing to append.
        let frame: [Float]
        if let channel = pcmBuffer.floatChannelData?[0] {
            frame = Array(UnsafeBufferPointer(start: channel, count: Int(pcmBuffer.frameLength)))
        } else if let channel = pcmBuffer.int16ChannelData?.pointee {
            frame = UnsafeBufferPointer(start: channel, count: Int(pcmBuffer.frameLength)).map {
                Float($0) / Float(Int16.max)
            }
        } else {
            return
        }
        let resampled = PlaybackResampler.toPipelineRate(frame, sourceRate: negotiatedSampleRate)

        // Read the origin and append in ONE critical section: this is where the block lands,
        // and it is the only correct origin for a position inside it. An interleaved producer's
        // appends sit between this producer's frames, so no per-producer offset maps them — and
        // reading `streamIndex` before a separate `append` let an interleaved append shift the
        // recorded origin after the read (PR #49 review comment 4305981485).
        let rangeStart = reference.appendReturningOrigin(resampled)

        // Publishes the position through the shared handoff when one is wired, so it is matched
        // against the appended block that contains it — including THIS producer's earlier
        // blocks, which is what queue lead means. The producer's frame counter counts scheduled
        // blocks (a node reports its render position as the end of everything it has taken), so
        // the block's local range is [counter-before-append, counter-after) at the rate the
        // counter runs at — the node's own rendering rate.
        if let handoff = echoReferenceHandoff {
            let producerFrames = Double(resampled.count)
                / PlaybackEchoReference.pipelineSampleRate * negotiatedSampleRate
            handoff.recordCloudBlockRange(
                referenceStart: rangeStart,
                referenceLength: resampled.count,
                producer: producerIdentityForTesting,
                producerStart: Double(nodeIncarnationFrames),
                producerEnd: Double(nodeIncarnationFrames) + producerFrames,
                sampleRate: negotiatedSampleRate
            )
            nodeIncarnationFrames += producerFrames
            // Read the node's ACTUAL rendered position rather than assuming anything about it:
            // scheduling a buffer does not mean it is audible, and what the filter needs is
            // where the node has RENDERED. A node that reports no valid render time publishes
            // nil — the position is unknown, and the handoff clears the anchor instead of
            // guessing one.
            handoff.submitRenderPosition(renderPosition(of: node), producer: producerIdentityForTesting)
            return
        }

        // No handoff wired (unit-test hosts, degraded builds): the fallback maps through the
        // blocks THIS producer recorded, so a position that has not reached any of them is
        // refused rather than anchored at a guessed offset. Without a handoff there is no range
        // store to consult, so this path keeps its own single-block view: correct only when this
        // producer's blocks are contiguous, which is the assumption the queue-lead defect broke.
        // Production always wires the handoff (VoiceControlAssembly), and the controls below pin
        // the handoff path; this branch exists so a host without one cannot crash.
        let anchor = renderPosition(of: node).map { position -> PlaybackRenderAnchor in
            PlaybackRenderAnchor(
                renderedFrames: Double(
                    referenceIndexForProducerPosition(
                        rangeStart: rangeStart,
                        // `playerTime.sampleTime` is the position at the END of what has been
                        // rendered, so this block began one block earlier.
                        producerBlockStart: position.renderedFrames - Double(resampled.count)
                            / PlaybackEchoReference.pipelineSampleRate * position.sourceSampleRate,
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

    /// This incarnation's running count of blocks handed to the node, in the producer's own
    /// frames. It advances on every append and returns to zero when the node is rebuilt
    /// (`stopEngine` rotates the incarnation), which is precisely the reset the incarnation
    /// boundary exists to catch.
    private var nodeIncarnationFrames: Double = 0

    private func playFrame(_ frame: CloudAudioFrame) {
        if timingEnabled { timingActive = frame.timingReceipt?.trace }
        guard let node = playerNode, let engine else {
            observeTiming("schedule_refused", reason: "no_engine")
            return
        }

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
        // this path has none — the drain loop yields. So its SAMPLES are appended here, while
        // its render positions travel through the handoff's mapping like every other
        // producer's. The producers that run on a deadline callback (the episode tap and the
        // earcon) submit both halves instead.
        appendToEmittedReference(pcmBuffer, node: node)
        // SCHEDULE AFTER the publish, deliberately (PR #49 review comment 4305981528): the
        // position published above is the node's ACTUAL rendered state — it excludes this
        // buffer if the node has not reached it yet. That is the honest anchor, and it is what
        // keeps the reference aligned with what the microphone can hear rather than with what
        // has merely been handed to the output node. A queue of scheduled-but-unrendered audio
        // therefore shows up as an anchor BEHIND the appended stream, which the containing-block
        // mapping resolves; appending first would have the reference claim audio before it is
        // audible.
        node.play()
        node.scheduleBuffer(pcmBuffer)
        if timingEnabled { timingScheduledFrames += Double(pcmBuffer.frameLength) }
        observeTiming("schedule")
    }

    /// The output node's rendered position, or nil when the node is not rendering.
    ///
    /// `lastRenderTime` is the host instant of the most recent render; converting it
    /// through `playerTime(forNodeTime:)` yields the position in the played audio's own
    /// sample frames. Both are needed: the frames give the mapping onto the reference,
    /// and the host instant places it on the shared monotonic basis. A node that is not
    /// playing reports no render time, which is a discontinuity rather than a position
    /// of zero.
    ///
    /// **A counter that has not started is not a position.** Measured on this host: an attached
    /// node reports `lastRenderTime.sampleTime == 0` with BOTH validity flags false before its
    /// first render, and `playerTime(forNodeTime:)` throws an `AVFAudio` exception for a node time
    /// that carries neither a valid sample time nor a valid host time. So the pre-start reading is
    /// refused here — as unknown — rather than converted, because zero is indistinguishable from
    /// "rendered exactly one frame" once the first block is in flight, and mapping it would anchor
    /// the first observation at the start of whichever block happens to cover zero.
    ///
    /// Internal but test-visible: the deterministic queue-lead control drives a real node whose
    /// counter advances without hardware, and asserts THIS function's reading of it.
    func renderPosition(of node: AVAudioPlayerNode) -> PlaybackRenderAnchor? {
        guard let lastRender = node.lastRenderTime,
              lastRender.isSampleTimeValid || lastRender.isHostTimeValid else { return nil }
        // The precondition above is what keeps the conversion safe: `playerTime(forNodeTime:)`
        // raises rather than returning nil for an invalid node time, so an unvalidated call is a
        // crash in the producer's own path.
        guard let playerTime = node.playerTime(forNodeTime: lastRender),
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
        // A test host may supply an output by other means (an offline-rendering engine); the seam
        // is consulted first so the decision point stays in one place. See the override's note for
        // why this exists instead of node injection.
        let isTestHost = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        CloudAudioPlayer.observedTestHostForTesting = isTestHost
        if isTestHost, let override = audioOutputAvailabilityOverrideForTesting {
            CloudAudioPlayer.observedOutputAvailableForTesting = override
            return override
        }
        #if targetEnvironment(simulator)
        // The simulator's audio unit asserts if a node graph is built before an
        // output device exists, which is the case in the test host.
        return ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil
        #else
        return true
        #endif
    }

    /// Seam for the availability decision above, consulted only when the process reports itself as
    /// running under a test configuration.
    ///
    /// Why this exists rather than a direct node injection: the queue-lead controls must drive the
    /// producer's REAL path — `enqueue` → runner → `processFrames` → `playFrame` — because that is
    /// where the node's position is read and published. A test that called `appendToEmittedReference`
    /// with its own node would be supplying the very position the review comment disputes, so it
    /// could not fail for the reason the fix cares about. What a test host genuinely cannot provide
    /// is an output device, so the seam replaces exactly that judgement and nothing else: the graph
    /// still comes from `startEngine`, the buffer still goes through `scheduleBuffer`, and the
    /// position still comes from `renderPosition(of:)`. Production never sets it, so production
    /// behaviour is unchanged.
    static var audioOutputAvailabilityOverrideForTesting: Bool? = nil

    /// Test-host-only output setup, applied to the real graph before starting it.
    static var configureEngineForTesting: ((AVAudioEngine) throws -> Void)?
    /// TEST-ONLY observation of the availability decision as the PRODUCTION call site sees it:
    /// whether the process reported itself as a test host at all (the override is consulted only
    /// then) and what availability was decided. A control asserts this instead of assuming the
    /// override took effect.
    private(set) static var observedTestHostForTesting = false
    private(set) static var observedOutputAvailableForTesting = false

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

    // Guarded by runnerLock. Observes a real runner pass without requiring an audio device.
    private var renderCatchUpRecheckForTesting: (() -> Void)?

    /// Arm the same deadline that pending render progress sets, without publishing new work.
    /// The callback fires only after the runner returns through processFrames.
    func scheduleRenderCatchUpForTesting(after delay: TimeInterval, recheck: @escaping () -> Void) {
        runnerLock.lock()
        renderCatchUpRecheckForTesting = recheck
        renderCatchUpWake = Date().addingTimeInterval(delay)
        runnerLock.signal()
        runnerLock.unlock()
    }

    /// Buffered frame count, for tests that assert the runner actually consumes
    /// frames (a player that buffers forever plays nothing).
    var bufferedFrameCountForTesting: Int { bufferedFrameCount }

    /// The engine and node the runner thread built, or nil before a turn has started one.
    ///
    /// Exposed so a test host can render this graph offline and advance ITS OWN counter. The point
    /// of the queue-lead controls is that the position comes from a real node rather than from the
    /// test's arithmetic, and reading the player's own node is what preserves that: the alternative
    /// — handing the player a node the test made — reintroduces the assumption under review.
    /// Reading is racy by construction (the runner owns these), which is acceptable for a seam used
    /// after the runner has been observed idle; production does not consult it.
    var engineForTesting: AVAudioEngine? { engine }
    var playerNodeForTesting: AVAudioPlayerNode? { playerNode }

    /// TEST-ONLY drain hold. Guarded by `runnerLock` — the single domain for every read and write,
    /// including the condition wait in `parkIfHeld`.
    private var drainHoldRequested = false

    /// TEST-ONLY claim signals. See the drainRemaining branch.
    var claimReached: DispatchSemaphore?
    var claimRelease: DispatchSemaphore?

    /// TEST-ONLY: how the runner's bounded wait on `claimRelease` ended, so a case can ASSERT the
    /// release succeeded rather than a bound merely preventing an infinite block.
    enum ClaimReleaseOutcome { case released, timedOut }

    /// Guarded by `runnerLock`: the runner publishes and a test reads, so the value needs one
    /// synchronization domain rather than a plain stored property.
    private var storedClaimReleaseOutcome: ClaimReleaseOutcome?
    var claimReleaseOutcome: ClaimReleaseOutcome? {
        get { runnerLock.lock(); defer { runnerLock.unlock() }; return storedClaimReleaseOutcome }
        set { runnerLock.lock(); storedClaimReleaseOutcome = newValue; runnerLock.unlock() }
    }
    var capturedStopNotification: ((Int, @escaping () -> Void) -> Void)?

    /// TEST-ONLY: the coalesced pending-stop-notification counter. A stranded positive value
    /// refuses every future admission, so controls assert it returns to zero.
    /// TEST-ONLY: the retained settled-displaced identities (bounded-retirement probe).
    var settledDisplacedIdentitiesForTesting: Set<Int> {
        bufferLock.lock(); defer { bufferLock.unlock() }
        return settledDisplacedIdentities
    }

    /// TEST-ONLY: the last PHYSICALLY confirmed stop identity (excludes displaced settlements).
    var confirmedStopEpochForTesting: Int { confirmedStopEpoch() }

    var pendingStopNotificationsForTesting: Int {
        runnerLock.lock(); defer { runnerLock.unlock() }
        return pendingStopNotifications
    }

    /// TEST-ONLY: hold the drain, or release it. Releasing re-arms the runner's work predicate so
    /// the same drain loop continues.
    func setDrainHoldForTesting(_ hold: Bool) {
        runnerLock.lock()
        drainHoldRequested = hold
        // Re-arm the runner's own work predicate so a RELEASE is acted on rather than waiting for
        // an unrelated signal.
        runnerRunning = true
        runnerLock.signal()
        runnerLock.unlock()
    }

    /// Cumulative count of frames handed to this player, for asserting that audio actually
    /// ARRIVED rather than merely that nothing is pending at the end.
    var framesEnqueuedForTesting: Int {
        bufferLock.lock()
        defer { bufferLock.unlock() }
        return framesEnqueued
    }

    private var framesEnqueued = 0

    /// Whether this player holds nothing left to play. A turn that produced no
    /// audio can restore immediately; one that is still draining restores when
    /// the drain completes.
    var hasPendingAudio: Bool {
        bufferLock.lock(); defer { bufferLock.unlock() }
        return !buffer.isEmpty
    }

    /// Test-only diagnostic: best-effort read of the runner-owned engine state. Used by the
    /// truncation control to prove owned output was STOPPED, not merely dequeued.
    var isPlayingForTesting: Bool { isPlaying }

    /// The identity of the drain most recently SCHEDULED.
    var currentDrainEpoch: Int {
        runnerLock.lock(); defer { runnerLock.unlock() }
        return drainEpoch
    }

    // MARK: - Drain

    private func drainAndStop(claimedEpoch: Int) {
        parkIfHeld()
        // Play any remaining frames.
        while true {
            guard let frame = dequeueFrame() else { break }
            playFrame(frame)
        }
        // Scheduling the last buffer is not playback completion. Keep this node alive until
        // its measured position reaches the scheduled end. A stalled/unreadable engine is
        // bounded, and cancel/shutdown can wake this wait and take ownership of the stop.
        let renderDeadline = Date().addingTimeInterval(nodeIncarnationFrames / negotiatedSampleRate * 2 + 1)
        while pendingAudibleOrUnverified && Date() < renderDeadline {
            runnerLock.lock()
            if stopRequested || shutdownRequested {
                runnerLock.unlock()
                break
            }
            _ = runnerLock.wait(until: min(renderDeadline, Date().addingTimeInterval(0.05)))
            let interrupted = stopRequested || shutdownRequested
            runnerLock.unlock()
            if interrupted { break }
        }
        // OWNED-STOP (spec a9e27935): the stop's identity is the CURRENT OWNER published at
        // request time — the drain claim when nothing displaced it, the cancel that landed
        // mid-window otherwise. Never a fresh re-read of `drainEpoch` (that let a successor's
        // unscheduled request steal the stop's identity) and never the stale claim once a
        // cancel superseded it. The displaced requests settle as superseded.
        runnerLock.lock()
        let stoppedEpoch = stopOwnerEpoch
        let displaced = supersededStopRequests
        supersededStopRequests = []
        stopOwnerEpoch = 0
        drainClaimInFlight = false
        // CANONICAL QUIESCENCE AT THE DRAIN END (review 0585959a): a cancel that landed while
        // this drain was claimed/playing bumped the identity and queued `stopRequested`. The
        // physical stop below IS that cancel's stop — the epoch snapshot proves it — so the
        // queued flag is consumed HERE. Leaving it set would run a SECOND physical stop after
        // this one, shedding a successor admitted on this stop's confirmation.
        stopRequested = false
        runnerLock.unlock()
        physicalStopGateWait()
        stopEngine(reason: stoppedEpoch == claimedEpoch ? "finish" : "cancel_during_finish", terminal: true)
        isPlaying = false
        paused = false
        notifyDidStop(epoch: stoppedEpoch)
        settleSupersededRequests(displaced)
    }

    /// Terminal settlement for requests this physical stop SUPERSEDED: their waiters resolve
    /// through their OWN record, never by relabelling them onto the owner's stop identity
    /// (review dc70303d: exactly-once, only-after-actual-stop settlement).
    private func settleSupersededRequests(_ displaced: Set<Int>) {
        guard !displaced.isEmpty else { return }
        // EXACT-SET settlement (review 47f67d4d): resume ONLY waiters whose epoch is in the
        // displaced record — never a lower identity that this stop did not satisfy. The
        // `upTo` sweep is for CONFIRMED identities (a physical stop of E satisfies every
        // request ≤ E); a displaced record is a SETTLEMENT of specific requests, and folding
        // them into the monotonic record would let a lower identity ride along unproven.
        bufferLock.lock()
        var resumed: [CheckedContinuation<Bool, Never>] = []
        for (id, ticket) in stopWaiters where displaced.contains(ticket.epoch) {
            stopWaiters.removeValue(forKey: id)
            if let continuation = ticket.takeContinuation() { resumed.append(continuation) }
        }
        // RETAIN the settlement fact (review 82714c29): a waiter registering after settlement
        // must resolve from this retained set. NO floor fold into `lastConfirmedStopEpoch` —
        // that would implicitly satisfy any lower identity; the set proves exactly these.
        settledDisplacedIdentities.formUnion(displaced)
        // Retire redundancies HERE as well (review 20ec6eaa): the physical stop that owns this
        // settlement raised the floor synchronously via notifyDidStop's record when delivery is
        // synchronous; when delivery is queued, this settlement path is the one that observably
        // runs — retire anything at or below the current floor under the same lock so the set
        // stays bounded regardless of main-queue timing.
        settledDisplacedIdentities = settledDisplacedIdentities.filter { $0 > lastConfirmedStopEpoch }
        bufferLock.unlock()
        for continuation in resumed { continuation.resume(returning: true) }
    }

    /// Snapshots what a control cannot read from the test thread while the runner is parked:
    /// the frames handed to the output node and whether an output node exists (i.e. the engine
    /// is up for THIS incarnation). Called by the runner at the gate's arrival — the moment the
    /// control needs the parked state — and by the control itself for the settled state.
    // TEST-ONLY (physical engine-stop evidence): when armed, the runner's physical stop
    // operation passes the first `allow` stops and PARKS each subsequent one until the gate
    // is opened. Lets a control hold the actual stop operation — not a notification — and
    // prove what may and may not happen while it is pending.
    //
    // ONE NSCondition owns BOTH the predicate (`allow`) and the waiting: arm/open mutate the
    // predicate under the condition's lock and broadcast; the waiter checks and waits on the
    // SAME lock — no lost-wake window between a predicate write and a parked waiter. Arrival
    // is published BEFORE waiting so a control can assert a real stop is actually parked;
    // the wait is bounded so the runner can never wedge past the bound.
    private let physicalStopGate = NSCondition()
    private var physicalStopGateAllow = -1 // unarmed: every stop passes
    private var physicalStopGateArrivals = 0 // stops that reached an ARMED gate
    /// How the gate wait ENDED: `released` is the only outcome that proves a stop parked and
    /// then actually ran; a bound expiry (`timedOut`) must be observable, never silently treated
    /// as "a stop ran".
    enum PhysicalStopGateOutcome { case unarmed, admitted, released, timedOut }
    private var physicalStopGateOutcome: PhysicalStopGateOutcome = .unarmed

    /// TEST-ONLY: the gate predicate, so a control can see whether the gate is still armed
    /// (`0` = parking) or has been opened (Int.max).
    var physicalStopGateAllowProbeForTesting: Int {
        physicalStopGate.lock()
        defer { physicalStopGate.unlock() }
        return physicalStopGateAllow
    }

    /// How the most recent armed gate wait ended.
    var physicalStopGateOutcomeForTesting: PhysicalStopGateOutcome {
        physicalStopGate.lock()
        defer { physicalStopGate.unlock() }
        return physicalStopGateOutcome
    }

    func armPhysicalStopGateForTesting(allow: Int) {
        physicalStopGate.lock()
        physicalStopGateAllow = allow
        physicalStopGate.broadcast()
        physicalStopGate.unlock()
    }

    func openPhysicalStopGateForTesting() {
        physicalStopGate.lock()
        physicalStopGateAllow = Int.max
        physicalStopGate.broadcast()
        physicalStopGate.unlock()
    }

    /// Stops that reached an ARMED gate (parked or admitted). A control asserts this grew
    /// BEFORE checking successor state, so the premise "a real stop is held" is measured,
    /// not assumed.
    var physicalStopGateArrivalsForTesting: Int {
        physicalStopGate.lock()
        defer { physicalStopGate.unlock() }
        return physicalStopGateArrivals
    }

    private func physicalStopGateWait() {
        let deadline = Date().addingTimeInterval(5)
        physicalStopGate.lock()
        if physicalStopGateAllow < 0 {
            // Only an armed gate's outcome is reportable: an unarmed call must not overwrite the
            // evidence of an EARLIER armed park (the runner passes the gate again on B's own
            // stop, which would erase the released/timedOut record the control asserts).
            if physicalStopGateArrivals == 0 { physicalStopGateOutcome = .unarmed }
            physicalStopGate.unlock()
            return
        }
        physicalStopGateArrivals += 1
        if physicalStopGateAllow > 0 {
            // Admitted immediately. An OPENED gate (Int.max) must NOT restamp the outcome: the
            // record of the park that the control released would be overwritten by a later stop
            // taking this fast path, erasing the `released`/`timedOut` evidence.
            if physicalStopGateAllow < Int.max {
                physicalStopGateAllow -= 1
                physicalStopGateOutcome = .admitted
            }
            physicalStopGate.unlock()
            return
        }
        while physicalStopGateAllow <= 0 {
            if !physicalStopGate.wait(until: deadline) { break } // bounded: never wedge the runner
        }
        // An OPENED gate is Int.max (never decremented); a timed-out park keeps allow 0.
        // Only record an outcome if we actually SAT on a parked wait — a stop that arrived at an
        // already-opened gate returned above and must not restamp this record.
        physicalStopGateOutcome = physicalStopGateAllow > 0 ? .released : .timedOut
        physicalStopGate.unlock()
    }

    /// Report that output has stopped, so the caller can restore what the turn
    /// ducked. Delivered on the main queue like the other delegate callbacks.
    private func notifyDidStop(epoch: Int) {
        stopRequestSettled()
        guard delegate != nil || capturedStopNotification != nil else { return }
        DispatchQueue.main.async {
            // TEST-ONLY CAPTURE: a test can intercept the REAL notification instead of invoking
            // the delegate itself, so a delayed notification can be delivered at a chosen moment
            // while another turn owns the hold.
            if let capture = self.capturedStopNotification {
                capture(epoch) {
                    self.recordConfirmedStop(epoch)
                    self.delegate?.audioPlayerDidStop(drainEpoch: epoch)
                }
                return
            }
            self.recordConfirmedStop(epoch)
            self.delegate?.audioPlayerDidStop(drainEpoch: epoch)
        }
    }

    /// CONFIRMATION: the stop for `epoch` completed — the engine actually stopped (output
    /// quiescent) and the stop notification was issued. EXACTLY this identity is confirmed,
    /// never a later one: a delayed stop of A must not promote a cancel-bumped B identity that
    /// was never physically stopped (review 5295572f).
    private func recordConfirmedStop(_ epoch: Int) {
        bufferLock.lock()
        // Monotonic over CONFIRMED identities only: a delayed stop of A (older identity) must
        // not regress the record — but it also must never PROMOTE an identity that was not
        // physically stopped (the banned `max(epoch, drainEpoch)` folded the REQUESTED identity;
        // this max folds only identities that actually fired).
        lastConfirmedStopEpoch = max(lastConfirmedStopEpoch, epoch)
        // BOUNDED RETIREMENT (review 20ec6eaa): a PHYSICALLY confirmed identity makes every
        // retained settlement at or below it redundant — the floor itself proves them — so
        // retire those entries here, under the same lock. The set therefore tracks only
        // outstanding settlements ABOVE the confirmed floor and returns to empty in steady
        // state; it is never an append-only request journal.
        if !settledDisplacedIdentities.isEmpty {
            settledDisplacedIdentities = settledDisplacedIdentities.filter { $0 > lastConfirmedStopEpoch }
        }
        bufferLock.unlock()
        resumeStopWaiters(upTo: epoch)
    }


    func setCapturedStopNotificationForTesting(_ capture: ((Int, @escaping () -> Void) -> Void)?) {
        bufferLock.lock()
        capturedStopNotification = capture
        bufferLock.unlock()
    }
}
