import Foundation
import PocketCastsUtils

/// Opt-in scalar diagnostics. Never retains audio/text and never runs on the render callback.
final class CloudPlaybackTiming: Equatable {
    static func == (lhs: CloudPlaybackTiming, rhs: CloudPlaybackTiming) -> Bool { lhs === rhs }

    struct Receipt: Equatable {
        let trace: CloudPlaybackTiming
        let receivedAt: UInt64
    }

    struct Snapshot: Codable {
        var player: String?
        var generation: UInt64?
        var queuedBytes: Int?
        var queuedFrames: Int?
        var scheduledFrames: Double?
        var renderedFrames: Double?
        var sampleRate: Double?
        var reason: String?
    }

    struct Event: Codable {
        let turn: String
        let stage: String
        let at: UInt64
        let receivedBytes: Int
        let receivedFrames: Int
        let lastReceive: UInt64?
        let lastEnqueue: UInt64?
        let lastSchedule: UInt64?
        let lastStart: UInt64?
        let lastStop: UInt64?
        let maxReceiveGapMs: Double
        let maxEnqueueLagMs: Double
        let droppedEvents: Int
        let capped: Bool
        let summary: Bool
        let state: Snapshot
    }

    static func isEnabled(environment: [String: String]) -> Bool {
        #if DEBUG
        return environment["AURIS_PLAYBACK_TIMING"] == "1"
        #else
        return false
        #endif
    }

    static func make(turn: String) -> CloudPlaybackTiming? {
        guard isEnabled(environment: ProcessInfo.processInfo.environment) else { return nil }
        // A request UUID is ephemeral per turn; never accept arbitrary text into diagnostic identity.
        guard let id = UUID(uuidString: turn) else { return nil }
        return CloudPlaybackTiming(turn: id.uuidString, enabled: true, emit: { event in
            guard let data = try? JSONEncoder().encode(event), let json = String(data: data, encoding: .utf8) else { return }
            FileLog.shared.console("[CloudPlaybackTiming] " + json)
        })
    }

    private let turn: String
    private let enabled: Bool
    private let clock: () -> UInt64
    private let emit: (Event) -> Void
    private let lock = NSLock()
    private let maximumEvents: Int
    private let minimumInterval: UInt64
    private var emitted = 0
    private var dropped = 0
    private var lastEmission: UInt64?
    private var finished = false
    private var receiverFinished = false
    private var bytes = 0
    private var frames = 0
    private var lastReceive: UInt64?
    private var lastEnqueue: UInt64?
    private var lastSchedule: UInt64?
    private var lastStart: UInt64?
    private var lastStop: UInt64?
    private var maxReceiveGapMs = 0.0
    private var maxEnqueueLagMs = 0.0

    init(turn: String, enabled: Bool, maximumEvents: Int = 256, minimumInterval: UInt64 = 250_000_000,
         clock: @escaping () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }, emit: @escaping (Event) -> Void) {
        self.turn = turn
        self.enabled = enabled
        self.maximumEvents = max(3, maximumEvents)
        self.minimumInterval = minimumInterval
        self.clock = clock
        self.emit = emit
    }

    func received(byteCount: Int) -> Receipt? {
        guard enabled else { return nil }
        let now = clock()
        record("receive", at: now, byteCount: byteCount)
        return Receipt(trace: self, receivedAt: now)
    }

    func observe(_ stage: String, receipt: Receipt? = nil, terminal: Bool = false,
                 state: () -> Snapshot = { Snapshot() }) {
        guard enabled else { return } // No diagnostic clock or progress reads while disabled.
        record(stage, at: clock(), receipt: receipt, terminal: terminal, state: state)
    }

    /// One transport summary even when no player ever receives a frame. This does not end
    /// playback observation: server completion can precede the last audible sample.
    func receiverEnded() {
        guard enabled else { return }
        lock.lock()
        let first = !receiverFinished
        receiverFinished = true
        lock.unlock()
        if first { record("receiver_end", at: clock(), summary: true) }
    }

    private func record(_ stage: String, at now: UInt64, byteCount: Int = 0, receipt: Receipt? = nil,
                        terminal: Bool = false, summary: Bool = false, state: () -> Snapshot = { Snapshot() }) {
        lock.lock()
        guard !finished || summary else { lock.unlock(); return }
        if stage == "receive" {
            if let prior = lastReceive { maxReceiveGapMs = max(maxReceiveGapMs, Self.milliseconds(now, after: prior)) }
            lastReceive = now
            bytes = Self.add(bytes, max(0, byteCount))
            frames = Self.add(frames, 1)
        }
        if stage == "enqueue" {
            lastEnqueue = now
            if let receipt { maxEnqueueLagMs = max(maxEnqueueLagMs, Self.milliseconds(now, after: receipt.receivedAt)) }
        }
        if stage == "schedule" { lastSchedule = now }
        if stage == "start" { lastStart = now }
        if stage == "stopped" { lastStop = now }
        let transition = ["start", "stop_requested", "stopped", "schedule_refused", "server_done", "receiver_end"].contains(stage)
        let rateAllowed = transition || (lastEmission.map { now >= $0 && now - $0 >= minimumInterval } ?? true)
        // Reserve one transport and one final playback summary so caps cannot hide the total dropped-event count.
        guard terminal || summary || (emitted < maximumEvents - 2 && rateAllowed) else {
            dropped = Self.add(dropped, 1)
            lock.unlock()
            return
        }
        if terminal { finished = true }
        emitted += 1
        if !transition { lastEmission = now }
        let counts = (bytes, frames, lastReceive, lastEnqueue, lastSchedule, lastStart, lastStop,
                      maxReceiveGapMs, maxEnqueueLagMs, dropped, emitted >= maximumEvents - 2)
        lock.unlock()
        // Progress polling, formatting and logging are outside this lock and every caller's audio lock.
        let snapshot = state()
        let event = Event(turn: turn, stage: stage, at: now, receivedBytes: counts.0, receivedFrames: counts.1,
            lastReceive: counts.2, lastEnqueue: counts.3, lastSchedule: counts.4, lastStart: counts.5,
            lastStop: counts.6, maxReceiveGapMs: counts.7, maxEnqueueLagMs: counts.8,
            droppedEvents: counts.9, capped: counts.10, summary: terminal || summary, state: snapshot)
        emit(event)
    }

    private static func add(_ lhs: Int, _ rhs: Int) -> Int {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? Int.max : sum
    }

    private static func milliseconds(_ now: UInt64, after prior: UInt64) -> Double {
        now >= prior ? Double(now - prior) / 1_000_000 : 0
    }
}
