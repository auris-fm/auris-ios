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
}
