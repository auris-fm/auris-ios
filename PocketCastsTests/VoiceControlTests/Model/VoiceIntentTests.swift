import XCTest
@testable import podcasts

final class VoiceIntentTests: XCTestCase {

    func test_playbackIntent_seekRelative_positive() {
        let intent = PlaybackIntent.seekRelative(deltaSeconds: 30)
        guard case .seekRelative(let delta) = intent else { XCTFail(); return }
        XCTAssertEqual(delta, 30)
    }

    func test_playbackIntent_seekRelative_negative() {
        let intent = PlaybackIntent.seekRelative(deltaSeconds: -15)
        guard case .seekRelative(let delta) = intent else { XCTFail(); return }
        XCTAssertEqual(delta, -15)
    }

    func test_playbackIntent_pause_equality() {
        XCTAssertEqual(PlaybackIntent.pause, PlaybackIntent.pause)
    }

    func test_playbackIntent_seekTo_equality() {
        XCTAssertEqual(
            PlaybackIntent.seekTo(positionSeconds: 120),
            PlaybackIntent.seekTo(positionSeconds: 120)
        )
    }

    func test_effectsIntent_setSpeed() {
        let intent = EffectsIntent.setSpeed(1.5)
        guard case .setSpeed(let speed) = intent else { XCTFail(); return }
        XCTAssertEqual(speed, 1.5)
    }

    func test_effectsIntent_setTrimMode() {
        let intent = EffectsIntent.setTrimMode(.medium)
        guard case .setTrimMode(let mode) = intent else { XCTFail(); return }
        XCTAssertEqual(mode, .medium)
    }

    func test_volumeIntent_setVolume() {
        let intent = VolumeIntent.setVolume(80)
        guard case .setVolume(let vol) = intent else { XCTFail(); return }
        XCTAssertEqual(vol, 80)
    }

    func test_sleepIntent_set() {
        let intent = SleepIntent.set(minutes: 30)
        guard case .set(let minutes) = intent else { XCTFail(); return }
        XCTAssertEqual(minutes, 30)
    }

    func test_sleepIntent_endOfEpisode() {
        XCTAssertEqual(SleepIntent.endOfEpisode, SleepIntent.endOfEpisode)
    }

    func test_chapterIntent_byIndex() {
        let intent = ChapterIntent.byIndex(3)
        guard case .byIndex(let index) = intent else { XCTFail(); return }
        XCTAssertEqual(index, 3)
    }

    func test_chapterIntent_byTitle() {
        let intent = ChapterIntent.byTitle("Introduction")
        guard case .byTitle(let title) = intent else { XCTFail(); return }
        XCTAssertEqual(title, "Introduction")
    }

    func test_bookmarkIntent_add() {
        let intent = BookmarkIntent.add(title: "Interesting point")
        guard case .add(let title) = intent else { XCTFail(); return }
        XCTAssertEqual(title, "Interesting point")
    }

    func test_bookmarkIntent_rename() {
        let intent = BookmarkIntent.rename(ref: "1", title: "Great quote")
        guard case .rename(let ref, let title) = intent else { XCTFail(); return }
        XCTAssertEqual(ref, "1")
        XCTAssertEqual(title, "Great quote")
    }

    func test_queueIntent_addTop() {
        let intent = QueueIntent.addTop(episode: "ep123")
        guard case .addTop(let episode) = intent else { XCTFail(); return }
        XCTAssertEqual(episode, "ep123")
    }

    func test_queueIntent_sort() {
        let intent = QueueIntent.sort(sortOrder: .oldestFirst)
        guard case .sort(let order) = intent else { XCTFail(); return }
        XCTAssertEqual(order, .oldestFirst)
    }

    func test_playbackQueryIntent_whatsPlaying() {
        XCTAssertEqual(PlaybackQueryIntent.whatsPlaying, PlaybackQueryIntent.whatsPlaying)
    }

    func test_statsQueryIntent_listeningTime() {
        let intent = StatsQueryIntent.listeningTime(period: "week")
        guard case .listeningTime(let period) = intent else { XCTFail(); return }
        XCTAssertEqual(period, "week")
    }

    func test_cloudRouteIntent_equality() {
        let context = PlaybackContext(episodeId: "ep1", positionMs: 5000, recentTimestamps: [1000, 2000])
        let intent = CloudRouteIntent(request: "find similar", tier: .premium, context: context)
        XCTAssertEqual(intent.request, "find similar")
        XCTAssertEqual(intent.tier, .premium)
        XCTAssertEqual(intent.context.episodeId, "ep1")
    }

    func test_trimMode_rawValues() {
        XCTAssertEqual(TrimMode.off.rawValue, "off")
        XCTAssertEqual(TrimMode.low.rawValue, "low")
        XCTAssertEqual(TrimMode.medium.rawValue, "medium")
        XCTAssertEqual(TrimMode.high.rawValue, "high")
    }

    func test_sortOrder_rawValues() {
        XCTAssertEqual(SortOrder.newestFirst.rawValue, "newestFirst")
        XCTAssertEqual(SortOrder.oldestFirst.rawValue, "oldestFirst")
    }

    func test_cloudTier_rawValues() {
        XCTAssertEqual(CloudTier.free.rawValue, "free")
        XCTAssertEqual(CloudTier.premium.rawValue, "premium")
        XCTAssertEqual(CloudTier.unknown.rawValue, "unknown")
    }
}
