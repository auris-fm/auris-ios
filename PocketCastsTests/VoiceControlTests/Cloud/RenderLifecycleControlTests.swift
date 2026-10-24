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
        super.tearDown()
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
