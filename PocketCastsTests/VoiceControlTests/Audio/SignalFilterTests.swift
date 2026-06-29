import XCTest
@testable import podcasts

final class SignalFilterTests: XCTestCase {

    func test_identicalSignals_highCorrelation_returnsTrue() {
        let signal = sineWave(frequency: 440, duration: 1.0, sampleRate: 16000)
        let filter = SignalFilter()
        let isBleed = filter.isPlaybackBleed(mic: signal, playback: signal)
        XCTAssertTrue(isBleed)
    }

    func test_differentSignals_lowCorrelation_returnsFalse() {
        let mic = sineWave(frequency: 440, duration: 1.0, sampleRate: 16000)
        let playback = sineWave(frequency: 880, duration: 1.0, sampleRate: 16000)
        let filter = SignalFilter()
        let isBleed = filter.isPlaybackBleed(mic: mic, playback: playback)
        XCTAssertFalse(isBleed)
    }

    func test_micShorterThanPlayback_returnsFalse() {
        let mic = sineWave(frequency: 440, duration: 0.5, sampleRate: 16000)
        let playback = sineWave(frequency: 440, duration: 1.0, sampleRate: 16000)
        let filter = SignalFilter()
        let isBleed = filter.isPlaybackBleed(mic: mic, playback: playback)
        XCTAssertFalse(isBleed)
    }

    // MARK: - Helpers

    private func sineWave(frequency: Float, duration: Float, sampleRate: Int) -> [Float] {
        let count = Int(duration * Float(sampleRate))
        return (0..<count).map { sin(2 * Float.pi * frequency * Float($0) / Float(sampleRate)) }
    }
}
