import XCTest
@testable import podcasts

final class WakePhraseNormalizerTests: XCTestCase {

    func test_removesAurisPrefix() {
        XCTAssertEqual(WakePhraseNormalizer.normalize("Auris skip forward"), "skip forward")
    }

    func test_removesHeyAuris_longestFirst() {
        XCTAssertEqual(WakePhraseNormalizer.normalize("Hey Auris play"), "play")
    }

    func test_removesHiAuris() {
        XCTAssertEqual(WakePhraseNormalizer.normalize("Hi Auris pause"), "pause")
    }

    func test_caseAndPunctuationAreIgnoredAroundTokens() {
        XCTAssertEqual(WakePhraseNormalizer.normalize("auris, skip forward."), "skip forward")
        XCTAssertEqual(WakePhraseNormalizer.normalize("HEY AURIS 3x speed"), "3x speed")
    }

    func test_unsupportedPrefix_isNotRemoved() {
        XCTAssertEqual(WakePhraseNormalizer.normalize("hello Auris pause"), "hello Auris pause")
        XCTAssertEqual(WakePhraseNormalizer.normalize("hola Auris pause"), "hola Auris pause")
    }

    func test_nonLeadingOccurrence_isNotRemoved() {
        XCTAssertEqual(WakePhraseNormalizer.normalize("play Auris"), "play Auris")
    }

    func test_wakeOnly_becomesEmpty() {
        XCTAssertEqual(WakePhraseNormalizer.normalize("Auris"), "")
        XCTAssertEqual(WakePhraseNormalizer.normalize("Hey Auris"), "")
    }

    func test_asrOmittedPrefix_passesThroughUnchanged() {
        XCTAssertEqual(WakePhraseNormalizer.normalize("skip forward"), "skip forward")
    }

    func test_whitespaceVariantsCollapse() {
        XCTAssertEqual(WakePhraseNormalizer.normalize("Auris   skip    forward"), "skip forward")
    }
}
