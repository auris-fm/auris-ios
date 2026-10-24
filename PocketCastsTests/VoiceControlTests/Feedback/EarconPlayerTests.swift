import XCTest
import AVFoundation
@testable import podcasts

final class EarconPlayerTests: XCTestCase {

    func test_init_preloadsAssets() {
    let engine = AVAudioEngine()
    let player = EarconPlayer(engine: engine)
    // Player initializes without crashing; preloadAll runs in init
    XCTAssertNotNil(player)
    }

    func test_play_validEarcon_doesNotCrash() {
    let engine = AVAudioEngine()
    let player = EarconPlayer(engine: engine)
    // Should not crash even if asset is missing
    player.play(.success)
    player.play(.error)
    player.play(.wakeWord)
    }

    func test_stop_doesNotCrash() {
    let engine = AVAudioEngine()
    let player = EarconPlayer(engine: engine)
    player.play(.success)
    player.stop()
    // Should not crash
    }

    func test_release_preventsFurtherPlay() {
    let engine = AVAudioEngine()
    let player = EarconPlayer(engine: engine)
    player.release()
    // Should not crash when playing after release
    player.play(.success)
    player.play(.error)
    }

    func test_allEarconIds_attemptToPlay() {
    let engine = AVAudioEngine()
    let player = EarconPlayer(engine: engine)
    for id in EarconId.allCases {
        player.play(id)
    }
    // Should not crash for any earcon
    }

    func test_missingAsset_degradesGracefully() {
    let engine = AVAudioEngine()
    let player = EarconPlayer(engine: engine)
    // Play all IDs multiple times — missing assets should not crash
    for _ in 0..<3 {
        for id in EarconId.allCases {
            player.play(id)
        }
    }
    }



    // MARK: - Rate split (review thread 4237185302, follow-up S5)

    /// **The graph connects at the assets' authored rate, not the echo pipeline's.**
    ///
    /// The shipped earcons are mono 16-bit at 44.1 kHz. Connecting the node at 16 kHz made
    /// every `scheduleBuffer` resample DOWN to 16 kHz before the mixer upsampled for the
    /// hardware — a double conversion capping what the user hears at an 8 kHz band, with no
    /// purpose: the filter's 16 kHz copy is produced separately by `publishForEchoReference`.
    /// This case pins the listener-side half of that split through the REAL path: scheduling
    /// a buffer whose format does not match the connection format fails the graph's own
    /// check, so a fixture built at the negotiated rate exercises the same contract.
    func test_connectionUsesTheAssetRate_notThePipelineRate() throws {
        let engine = AVAudioEngine()
        let player = EarconPlayer(engine: engine)

        // The expected rate is the AUTHORED rate, not a value read back from loaded assets.
        // `preloadAll` reads `Bundle.main`, and the earcon assets belong to the app target, so
        // under this test host NONE load (`[VoicePipeline] Missing asset: *.wav` for all six in
        // the run log) and `assetSampleRateForTesting` is nil. Requiring it was an impossible
        // precondition asserted against my own helper's documented behaviour. What this case
        // must pin is that the graph is connected at 44.1 kHz rather than the pipeline rate —
        // which is exactly what the empty-cache fallback exists to guarantee.
        let expectedRate = EarconPlayer.authoredAssetSampleRate

        // The value we INTENDED to connect with.
        XCTAssertEqual(
            player.chosenSampleRateForTesting, expectedRate,
            "the chosen rate is not the assets' authored rate — the fallback derivation regressed"
        )
        // AND the graph's actual connection format, read back from the node itself. Asserting
        // only the stored value would stay green if `engine.connect(...)` were deleted or given
        // a different format, because choice and graph would silently disagree (review
        // follow-up).
        //
        // The node must be SCHEDULED-FROM a live graph first: AVAudioEngine resolves a node's
        // bus format when the engine starts, so querying an attached-but-unstarted node answers
        // "not connected" (nil here, NSRangeException in an earlier attempt). Production starts
        // the engine lazily inside `play`, so the fixture drives that same path rather than
        // inventing a second start sequence.
        let fixtureRate = try XCTUnwrap(EarconPlayer.earconFormat(sampleRate: expectedRate).sampleRate)
        let fixture = try XCTUnwrap(
            AVAudioPCMBuffer(pcmFormat: EarconPlayer.earconFormat(sampleRate: fixtureRate), frameCapacity: 441)
        )
        fixture.frameLength = 441
        player.loadForTesting(.wakeWord, buffer: fixture)
        player.play(.wakeWord)

        XCTAssertEqual(
            player.negotiatedSampleRateForTesting, expectedRate,
            "the node is ACTUALLY connected at a rate other than the authored one — the "
                + "double-conversion defect is back, or the connect call was dropped"
        )
        XCTAssertNotEqual(
            player.negotiatedSampleRateForTesting, PlaybackEchoReference.pipelineSampleRate,
            "connecting at the echo pipeline rate downsamples everything the USER hears"
        )



        // Scheduling a buffer whose format does not match the connection format fails the
        // graph's own check, so the fact that `play` above accepted a 44.1 kHz fixture IS the
        // listener-side proof. A 16 kHz fixture would have been rejected here.
        player.stop()
    }

    /// **The reference still receives 16 kHz audio with the correct duration** after the
    /// producer-side conversion moved into `publishForEchoReference`: N seconds of chime at
    /// the asset rate must occupy N seconds of the reference's timeline, whatever the graph
    /// does on the listener side.
    func test_publishedSamplesAreConvertedToThePipelineRate() throws {
        let reference = PlaybackEchoReference()
        let handoff = EchoReferenceHandoff(reference: reference, capacity: 4)
        let player = EarconPlayer(engine: nil)
        player.handoff = handoff

        let sourceRate = 44_100.0
        let frames = 4_410  // 100 ms at 44.1 kHz
        let format = try XCTUnwrap(EarconPlayer.earconFormat(sampleRate: sourceRate))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
        buffer.frameLength = AVAudioFrameCount(frames)
        if let channel = buffer.floatChannelData?[0] {
            for i in 0..<frames { channel[i] = Float(sin(Double(i) * 0.05) * 0.3) }
        }

        player.publishForEchoReference(buffer)
        handoff.drain()

        let retained = reference.snapshot()
        XCTAssertEqual(
            retained.count, 1_600,
            "100 ms of earcon must occupy 100 ms (1 600 samples) of the 16 kHz reference"
        )
        XCTAssertFalse(retained.allSatisfy { $0 == 0 }, "only silence reached the reference")
    }
}
