import XCTest
import AVFoundation
@testable import podcasts

/// Contract (@spec, 2026-10-18): queue emptiness is NOT proof that scheduled audio finished
/// rendering, and must not trigger a stop/rotation that discards still-pending audible work. The
/// rendering incarnation stays alive until MEASURED render progress drains its scheduled frames —
/// or an explicit stop/reset. Recorded emitted ranges are historical evidence for THAT incarnation;
/// a reset retires the current mapping, and a late position from a retired clock establishes no
/// new anchor.
final class RenderLifecycleControlTests: XCTestCase {

    override func tearDown() {
        CloudAudioPlayer.audioOutputAvailabilityOverrideForTesting = nil
        CloudAudioPlayer.configureEngineForTesting = nil
        super.tearDown()
    }

    /// `done` ends network delivery, not scheduled playback. The real engine renders offline so
    /// its counter advances only when this fixture renders actual scheduled PCM, without hardware.
    @MainActor
    func testServerDoneWaitsForScheduledAudioBeforeStoppingTheEngine() throws {
        try withPendingOfflineAudio { player, engine, node, output, scheduledSamples in
            player.armPhysicalStopGateForTesting(allow: 0)
            let drainClaimed = DispatchSemaphore(value: 0)
            player.claimReached = drainClaimed
            player.finish()
            XCTAssertEqual(drainClaimed.wait(timeout: .now() + 2), .success, "premise: the runner claimed this finish")
            let pendingDeadline = Date().addingTimeInterval(0.1)
            while Date() < pendingDeadline && player.physicalStopGateArrivalsForTesting == 0 {
                RunLoop.current.run(until: Date().addingTimeInterval(0.005))
            }
            XCTAssertEqual(player.physicalStopGateArrivalsForTesting, 0,
                           "server done attempted to stop with scheduled audio still unheard")
            // Advance the SAME production node through its remaining PCM, not a synthetic counter.
            let renderDeadline = Date().addingTimeInterval(2)
            while (player.renderPosition(of: node)?.renderedFrames ?? 0) < Double(scheduledSamples)
                && Date() < renderDeadline {
                XCTAssertEqual(try engine.renderOffline(1_024, to: output), .success)
            }
            let stopDeadline = Date().addingTimeInterval(2)
            while player.physicalStopGateArrivalsForTesting == 0 && Date() < stopDeadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.005))
            }
            XCTAssertEqual(player.physicalStopGateArrivalsForTesting, 1, "the completed render must reach a physical stop")
            let atStop = try XCTUnwrap(player.renderPosition(of: node))
            XCTAssertGreaterThanOrEqual(atStop.renderedFrames, Double(scheduledSamples))
            player.openPhysicalStopGateForTesting()
        }
    }

    @MainActor
    func testCancelPreemptsFinishWhileScheduledAudioHasNotRendered() throws {
        try withPendingOfflineAudio { player, _, _, _, _ in
            player.armPhysicalStopGateForTesting(allow: 0)
            let claimed = DispatchSemaphore(value: 0)
            player.claimReached = claimed
            let finished = player.finish()
            XCTAssertEqual(claimed.wait(timeout: .now() + 2), .success)
            let cancelled = player.cancel()
            let deadline = Date().addingTimeInterval(1)
            while player.physicalStopGateArrivalsForTesting == 0 && Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.005))
            }
            XCTAssertEqual(player.physicalStopGateArrivalsForTesting, 1, "cancel must preempt held render progress promptly")
            player.openPhysicalStopGateForTesting()
            while player.confirmedStopEpochForTesting < cancelled && Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.005))
            }
            XCTAssertGreaterThan(cancelled, finished)
            XCTAssertEqual(player.confirmedStopEpochForTesting, cancelled, "cancel arriving during catch-up owns the actual stop")
            XCTAssertEqual(player.pendingStopNotificationsForTesting, 0)
        }
    }

    @MainActor
    func testFinishHasAFiniteDeadlineWhenTheRendererMakesNoProgress() throws {
        try withPendingOfflineAudio { player, _, node, _, scheduledSamples in
            player.armPhysicalStopGateForTesting(allow: 0)
            let claimed = DispatchSemaphore(value: 0)
            player.claimReached = claimed
            player.finish()
            XCTAssertEqual(claimed.wait(timeout: .now() + 2), .success)
            let deadline = Date().addingTimeInterval(4.5)
            while player.physicalStopGateArrivalsForTesting == 0 && Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.005))
            }
            XCTAssertEqual(player.physicalStopGateArrivalsForTesting, 1, "a renderer with no progress must not retain the drain forever")
            XCTAssertLessThan(try XCTUnwrap(player.renderPosition(of: node)).renderedFrames, Double(scheduledSamples),
                              "the fixture must genuinely leave render progress held")
            player.openPhysicalStopGateForTesting()
        }
    }

    @MainActor
    func testTimingSeparatesEmptyQueueFromUnrenderedAudioAtCancel() throws {
        let lock = NSLock()
        var summary: CloudPlaybackTiming.Event?
        let timing = CloudPlaybackTiming(turn: "synthetic", enabled: true, minimumInterval: 0, emit: { event in
            if event.stage == "stop_requested" { lock.lock(); summary = event; lock.unlock() }
        })
        try withPendingOfflineAudio(timing: timing) { player, _, _, _, scheduledSamples in
            let cancelled = player.cancel()
            let deadline = Date().addingTimeInterval(2)
            while player.confirmedStopEpochForTesting < cancelled && Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.005))
            }
            lock.lock()
            let captured = summary
            lock.unlock()
            let event = try XCTUnwrap(captured)
            XCTAssertEqual(event.state.queuedBytes, 0)
            XCTAssertEqual(event.state.queuedFrames, 0)
            XCTAssertEqual(event.state.scheduledFrames, Double(scheduledSamples))
            XCTAssertLessThan(try XCTUnwrap(event.state.renderedFrames), Double(scheduledSamples))
            XCTAssertEqual(event.state.reason, "cancel")
        }
    }

    @MainActor
    private func withPendingOfflineAudio(
        timing: CloudPlaybackTiming? = nil,
        _ body: (CloudAudioPlayer, AVAudioEngine, AVAudioPlayerNode, AVAudioPCMBuffer, Int) throws -> Void
    ) throws {
        CloudAudioPlayer.audioOutputAvailabilityOverrideForTesting = true
        let outputFormat = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        CloudAudioPlayer.configureEngineForTesting = { engine in
            try engine.enableManualRenderingMode(.offline, format: outputFormat, maximumFrameCount: 4_096)
        }
        let reference = PlaybackEchoReference()
        let handoff = EchoReferenceHandoff(reference: reference, capacity: 16)
        defer { withExtendedLifetime(handoff) {} }
        let player = CloudAudioPlayer(timingEnabled: timing != nil)
        player.emittedPCMReference = reference
        player.echoReferenceHandoff = handoff // Production assembly retains and wires both halves.
        // Retain the actual stop notification path so confirmation is observable without a sink.
        player.capturedStopNotification = { _, confirm in confirm() }
        player.setNegotiatedCodec(CloudAudioCodec(name: "pcm_s16le@16k")!)
        defer {
            player.openPhysicalStopGateForTesting()
            let cancelled = player.cancel()
            let cleanupDeadline = Date().addingTimeInterval(2)
            while player.confirmedStopEpochForTesting < cancelled && Date() < cleanupDeadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.005))
            }
            XCTAssertGreaterThanOrEqual(player.confirmedStopEpochForTesting, cancelled, "cleanup must settle before shared hooks reset")
            XCTAssertTrue(player.shutdownForTimingTesting())
        }
        let scheduledSamples = 22_400
        var data = Data()
        withUnsafeBytes(of: Int16(2_000)) { raw in
            for _ in 0..<3_200 { data.append(contentsOf: raw) }
        }
        for _ in 0..<7 {
            player.enqueue(CloudAudioFrame(data: data, timingReceipt: timing?.received(byteCount: data.count)))
        }
        let scheduledDeadline = Date().addingTimeInterval(3)
        while Date() < scheduledDeadline && reference.streamIndex < scheduledSamples {
            RunLoop.current.run(until: Date().addingTimeInterval(0.005))
        }
        XCTAssertEqual(reference.streamIndex, scheduledSamples, "premise: the real runner scheduled every sample")
        let engine = try XCTUnwrap(player.engineForTesting)
        let node = try XCTUnwrap(player.playerNodeForTesting)
        XCTAssertEqual(engine.manualRenderingMode, .offline)
        let output = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 4_096))
        XCTAssertEqual(try engine.renderOffline(128, to: output), .success)
        let initial = try XCTUnwrap(player.renderPosition(of: node), "premise: the real node rendered the initial quantum")
        XCTAssertLessThan(initial.renderedFrames, Double(scheduledSamples - 8_000),
                          "premise: scheduled audio remains at done")
        try body(player, engine, node, output, scheduledSamples)
    }

    /// Queue emptiness must preserve the current clock while measured scheduled audio remains.
    /// After real catch-up retires that clock, its old observations must be refused.
    @MainActor
    func testQueueEmptinessDoesNotRetireRangesWithPendingAudibleWork() throws {
        try withPendingOfflineAudio { player, engine, node, output, scheduledSamples in
            let identity = player.producerIdentityForTesting
            let handoff = try XCTUnwrap(player.echoReferenceHandoffForTesting)
            let reference = try XCTUnwrap(player.emittedPCMReference)
            let pending = try XCTUnwrap(player.renderPosition(of: node))
            XCTAssertLessThan(pending.renderedFrames, Double(scheduledSamples))
            XCTAssertEqual(player.bufferedFrameCountForTesting, 0)
            XCTAssertEqual(player.producerIdentityForTesting, identity)
            handoff.submitRenderPosition(pending, producer: identity)
            handoff.drain()
            XCTAssertNotNil(reference.currentRenderAnchor, "the current clock's measured position must map")

            let naturalStopEntered = DispatchSemaphore(value: 0)
            let releaseNaturalStop = DispatchSemaphore(value: 0)
            var measuredCatchUp: Double?
            var holdReleased = false
            player.onNaturalCatchUpForTesting = { position in
                measuredCatchUp = position
                naturalStopEntered.signal()
                holdReleased = releaseNaturalStop.wait(timeout: .now() + 2) == .success
            }
            defer { releaseNaturalStop.signal() }
            var caughtUp = pending.renderedFrames
            let renderDeadline = Date().addingTimeInterval(1)
            while caughtUp < Double(scheduledSamples)
                && Date() < renderDeadline {
                XCTAssertEqual(try engine.renderOffline(1_024, to: output), .success)
                caughtUp = try XCTUnwrap(player.renderPosition(of: node)).renderedFrames
            }
            XCTAssertEqual(naturalStopEntered.wait(timeout: .now() + 1), .success,
                           "premise: the natural catch-up path actually entered the pre-reset hold")
            XCTAssertGreaterThanOrEqual(try XCTUnwrap(measuredCatchUp), Double(scheduledSamples))
            releaseNaturalStop.signal()
            let retirementDeadline = Date().addingTimeInterval(2)
            while player.producerIdentityForTesting == identity && Date() < retirementDeadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.005))
            }
            XCTAssertNotEqual(player.producerIdentityForTesting, identity)
            XCTAssertTrue(holdReleased, "the measured natural stop must be released, not time out")
            reference.recordRenderPosition(nil)
            handoff.submitRenderPosition(pending, producer: identity)
            handoff.drain()
            XCTAssertNil(reference.currentRenderAnchor, "a retired clock must not reuse its old ranges")
        }
    }
}
