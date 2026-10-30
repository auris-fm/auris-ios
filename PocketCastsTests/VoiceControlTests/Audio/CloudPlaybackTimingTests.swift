import XCTest
@testable import podcasts

final class CloudPlaybackTimingTests: XCTestCase {
    func testDisabledDoesNotReadClockProgressOrEmit() {
        var clockReads = 0
        var progressReads = 0
        var events = 0
        let trace = CloudPlaybackTiming(turn: "synthetic", enabled: false, clock: {
            clockReads += 1
            return 0
        }, emit: { _ in events += 1 })
        XCTAssertNil(trace.received(byteCount: 480))
        trace.observe("schedule") {
            progressReads += 1
            return CloudPlaybackTiming.Snapshot()
        }
        XCTAssertEqual(clockReads, 0)
        XCTAssertEqual(progressReads, 0)
        XCTAssertEqual(events, 0)
    }

    func testReceiptGapAndConsumptionLagAreIndependent() throws {
        var now: UInt64 = 0
        var events: [CloudPlaybackTiming.Event] = []
        let trace = CloudPlaybackTiming(turn: "synthetic", enabled: true, minimumInterval: 0,
            clock: { now }, emit: { events.append($0) })
        let first = try XCTUnwrap(trace.received(byteCount: 480))
        now = 4_000_000_000
        trace.observe("enqueue", receipt: first)
        XCTAssertEqual(events.last?.maxReceiveGapMs, 0)
        XCTAssertEqual(events.last?.maxEnqueueLagMs, 4_000)
        now = 7_000_000_000
        _ = trace.received(byteCount: 960)
        XCTAssertEqual(events.last?.maxReceiveGapMs, 7_000)
        XCTAssertEqual(events.last?.maxEnqueueLagMs, 4_000)
        XCTAssertEqual(events.last?.receivedBytes, 1_440)
    }

    func testRateAndTotalCapsReserveOneSummaryAndSkipProgressReads() {
        var now: UInt64 = 0
        var events: [CloudPlaybackTiming.Event] = []
        var progressReads = 0
        let trace = CloudPlaybackTiming(turn: "synthetic", enabled: true, maximumEvents: 4,
            minimumInterval: 100, clock: { now }, emit: { events.append($0) })
        _ = trace.received(byteCount: 480)
        trace.observe("schedule") { progressReads += 1; return CloudPlaybackTiming.Snapshot() }
        now = 100
        trace.observe("enqueue")
        now = 200
        trace.observe("schedule") { progressReads += 1; return CloudPlaybackTiming.Snapshot() }
        trace.observe("stop", terminal: true)
        trace.observe("stop", terminal: true)
        XCTAssertEqual(events.count, 3)
        XCTAssertEqual(events.last?.droppedEvents, 2)
        XCTAssertEqual(events.last?.lastSchedule, 200)
        XCTAssertEqual(events.last?.summary, true)
        XCTAssertEqual(events.last?.capped, true)
        XCTAssertEqual(progressReads, 0)
    }

    func testChunkImmediatelyBeforeStopDoesNotHideTransitionOrEndPlaybackAtTransportEnd() {
        var events: [CloudPlaybackTiming.Event] = []
        let trace = CloudPlaybackTiming(turn: "synthetic", enabled: true,
            clock: { 1 }, emit: { events.append($0) })
        _ = trace.received(byteCount: 480)
        trace.observe("stop_requested") {
            CloudPlaybackTiming.Snapshot(queuedBytes: 0, scheduledFrames: 240, renderedFrames: 120, reason: "underrun")
        }
        trace.receiverEnded()
        trace.receiverEnded()
        trace.observe("stopped", terminal: true)
        XCTAssertEqual(events.map(\.stage), ["receive", "stop_requested", "receiver_end", "stopped"])
        XCTAssertEqual(events[1].state.renderedFrames, 120)
        XCTAssertEqual(events[1].state.scheduledFrames, 240)
        XCTAssertEqual(events.filter(\.summary).count, 2)
    }

    func testBothSummaryOrdersAtCapAndDuplicatesStayBounded() {
        for receiverFirst in [false, true] {
            var events: [CloudPlaybackTiming.Event] = []
            let trace = CloudPlaybackTiming(turn: "synthetic", enabled: true, maximumEvents: 3,
                minimumInterval: 0, emit: { events.append($0) })
            _ = trace.received(byteCount: 480)
            trace.observe("schedule")
            if receiverFirst { trace.receiverEnded() }
            trace.observe("stopped", terminal: true)
            trace.observe("stopped", terminal: true)
            trace.observe("schedule")
            trace.receiverEnded()
            trace.receiverEnded()
            XCTAssertEqual(events.count, 3)
            XCTAssertEqual(events.filter { $0.stage == "receiver_end" }.count, 1)
            XCTAssertEqual(events.filter { $0.stage == "stopped" }.count, 1)
            XCTAssertEqual(events.last?.droppedEvents, 1)
        }
    }

    @MainActor
    func testDisabledRealPlayerDoesNotMaintainDiagnosticState() async {
        let player = CloudAudioPlayer(timingEnabled: false)
        defer { XCTAssertTrue(player.shutdownForTimingTesting()) }
        player.capturedStopNotification = { _, confirm in confirm() }
        player.enqueue(CloudAudioFrame(data: Data(repeating: 0, count: 480)))
        XCTAssertEqual(player.timingQueuedBytesForTesting, 0)
        let cancelled = player.cancel()
        let stopped = await player.awaitActualStop(after: cancelled, timeout: 2)
        XCTAssertTrue(stopped)
        XCTAssertEqual(player.timingSnapshotsForTesting, 0)
    }

    @MainActor
    func testRealPlayerReportsQueuedBytesAndCancelledPhysicalStop() async throws {
        let enqueued = expectation(description: "actual player enqueue")
        let stopped = expectation(description: "actual runner stop")
        let trace = CloudPlaybackTiming(turn: "synthetic", enabled: true, minimumInterval: 0, emit: { event in
            if event.stage == "enqueue" {
                XCTAssertEqual(event.state.queuedBytes, 480)
                XCTAssertEqual(event.state.queuedFrames, 1)
                XCTAssertNil(event.state.scheduledFrames)
                enqueued.fulfill()
            }
            if event.stage == "stopped" {
                XCTAssertEqual(event.state.reason, "cancel")
                XCTAssertEqual(event.state.queuedBytes, 0)
                XCTAssertNil(event.state.scheduledFrames)
                stopped.fulfill()
            }
        })
        let player = CloudAudioPlayer(timingEnabled: true)
        defer { XCTAssertTrue(player.shutdownForTimingTesting()) }
        player.capturedStopNotification = { _, confirm in confirm() }
        let receipt = try XCTUnwrap(trace.received(byteCount: 480))
        player.enqueue(CloudAudioFrame(data: Data(repeating: 0, count: 480), timingReceipt: receipt))
        let cancelled = player.cancel()
        await fulfillment(of: [enqueued, stopped], timeout: 2)
        let confirmed = await player.awaitActualStop(after: cancelled, timeout: 2)
        XCTAssertTrue(confirmed)
    }
}
