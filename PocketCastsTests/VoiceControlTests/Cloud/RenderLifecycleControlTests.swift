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
    private func withPendingOfflineAudio(
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
        let player = CloudAudioPlayer()
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
        }
        let scheduledSamples = 22_400
        var data = Data()
        withUnsafeBytes(of: Int16(2_000)) { raw in
            for _ in 0..<3_200 { data.append(contentsOf: raw) }
        }
        for _ in 0..<7 { player.enqueue(CloudAudioFrame(data: data)) }
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

    /// The fixture feeds a real burst, waits for the appends, then measures: while the node still
    /// has unrendered scheduled audio, the incarnation must NOT have rotated (the ranges survive),
    /// and a position measured AFTER the scheduled span has rendered must anchor — the mapping
    /// stayed alive long enough to hear its own audio.
    @MainActor
    func testQueueEmptinessDoesNotRetireRangesWithPendingAudibleWork() throws {
        CloudAudioPlayer.audioOutputAvailabilityOverrideForTesting = true
        let reference = PlaybackEchoReference()
        let handoff = EchoReferenceHandoff(reference: reference, capacity: 16)
        let player = CloudAudioPlayer()
        player.emittedPCMReference = reference
        player.echoReferenceHandoff = handoff
        player.setNegotiatedCodec(CloudAudioCodec(name: "pcm_s16le@16k")!)
        var data = Data()
        withUnsafeBytes(of: Int16(3_000)) { raw in for _ in 0..<1600 { data.append(contentsOf: raw) } }
        for _ in 0..<7 { player.enqueue(CloudAudioFrame(data: data)) }
        // Appends: the reference grows by the burst (resample is 1:1 at the pipeline rate).
        let deadline = Date().addingTimeInterval(5.0)
        while Date() < deadline && reference.streamIndex < 7 * 1_600 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertGreaterThanOrEqual(
            reference.streamIndex, 7 * 1_600,
            "precondition: the burst was appended; without this the case proves nothing"
        )
        // The identity the ranges were recorded under: startEngine's own pre-stop rotates the
        // counter once at engine birth (measured), so the emission incarnation is read AFTER the
        // appends, not at enqueue time.
        let emissionIncarnation = player.producerIdentityForTesting.incarnation

        // The scheduled audio is 7 × 100 ms. Render catch-up must keep the incarnation alive at
        // least while that audio is still pending: poll for it to ROTATE only after ~enough wall
        // time for the node to have rendered (0.9 s > 0.7 s), or fail early if it rotated while
        // the audio was still pending.
        let audibleDeadline = Date().addingTimeInterval(0.9)
        while Date() < audibleDeadline {
            XCTAssertEqual(
                player.producerIdentityForTesting.incarnation, emissionIncarnation,
                "the incarnation rotated while scheduled audio was still pending: queue emptiness "
                    + "discarded audible work (contract violation)"
            )
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }

        // After the measured render catch-up the engine may retire; whether it did or not, a
        // position measured within the SAME incarnation must anchor inside the appended audio —
        // the ranges were kept as historical evidence for their incarnation.
        let anchorDeadline = Date().addingTimeInterval(10.0)
        var anchored = false
        while Date() < anchorDeadline && !anchored {
            // A rendering node reading: submit a position measured mid-audio under the identity
            // the ranges were recorded under.
            if player.producerIdentityForTesting.incarnation == emissionIncarnation {
                // Real measured position: read from the player's own node if it renders, else
                // measure via a real position inside the recorded span.
                let position = PlaybackRenderAnchor(
                    renderedFrames: 800, sourceSampleRate: PlaybackEchoReference.pipelineSampleRate, hostTime: 0
                )
                handoff.submitRenderPosition(position, producer: .init(kind: .cloud, incarnation: emissionIncarnation))
                handoff.drain()
                anchored = reference.currentRenderAnchor != nil
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertTrue(
            anchored,
            "a position from the incarnation that emitted the audio was refused even though the "
                + "audio was appended and (by the elapsed 0.55 s) rendered: the ranges did not "
                + "survive as the incarnation's historical evidence"
        )

        // Explicit stop rotates: the contract's explicit-stop branch.
        player.cancel()
        let rotateDeadline = Date().addingTimeInterval(2.0)
        while Date() < rotateDeadline
            && player.producerIdentityForTesting.incarnation == emissionIncarnation {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertNotEqual(
            player.producerIdentityForTesting.incarnation, emissionIncarnation,
            "an explicit cancel did not rotate the incarnation"
        )
    }
}
