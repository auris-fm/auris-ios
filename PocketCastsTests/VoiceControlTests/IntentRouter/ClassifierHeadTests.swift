import XCTest
@testable import podcasts

final class ClassifierHeadTests: XCTestCase {
    func test_loadFixture_andArgmaxKnownVector() {
        let head = LfmcClassifier.load(Self.fixtureBytes, expectedHiddenSize: 3)
        XCTAssertNotNil(head)
        XCTAssertEqual(head?.classify([1, 0, 0]), "playback:pause")
    }

    func test_wrongMagic_failsClosed() {
        var bad = Data((1...12).map { UInt8($0) })
        XCTAssertNil(LfmcClassifier.load(bad, expectedHiddenSize: 3))
        // Keep local mutation visible to the compiler for future fixture edits.
        bad[0] = 0
        _ = bad
    }

    func test_hiddenSizeMismatch_failsClosed() {
        XCTAssertNil(LfmcClassifier.load(Self.fixtureBytes, expectedHiddenSize: 4))
    }

    func test_embeddingSizeMismatch_doesNotClassify() {
        let head = LfmcClassifier.load(Self.fixtureBytes, expectedHiddenSize: 3)
        XCTAssertNil(head?.classify([1, 0]))
    }

    /// Matches Android `lfm_test_classifier.bin` / iOS Fixtures copy.
    private static let fixtureBytes: Data = {
        var data = Data()
        data.append(contentsOf: [UInt8(ascii: "L"), UInt8(ascii: "F"), UInt8(ascii: "M"), UInt8(ascii: "C")])
        data.append(contentsOf: UInt32(2).littleEndianBytes)
        data.append(contentsOf: UInt32(3).littleEndianBytes)
        // weight rows: [1,0,0] and [0,1,0]
        data.append(contentsOf: Float32(1).bitPattern.littleEndianBytes)
        data.append(contentsOf: Float32(0).bitPattern.littleEndianBytes)
        data.append(contentsOf: Float32(0).bitPattern.littleEndianBytes)
        data.append(contentsOf: Float32(0).bitPattern.littleEndianBytes)
        data.append(contentsOf: Float32(1).bitPattern.littleEndianBytes)
        data.append(contentsOf: Float32(0).bitPattern.littleEndianBytes)
        // bias: 0.1, -0.1
        data.append(contentsOf: Float32(0.1).bitPattern.littleEndianBytes)
        data.append(contentsOf: Float32(-0.1).bitPattern.littleEndianBytes)
        return data
    }()
}

private extension FixedWidthInteger {
    var littleEndianBytes: [UInt8] {
        withUnsafeBytes(of: littleEndian, Array.init)
    }
}
