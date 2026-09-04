import XCTest

@testable import podcasts

final class ThreadSafeDictionaryTests: XCTestCase {

    func testThreadSafety() async {
        let dictionary = ThreadSafeDictionary<String, String>()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<1_000_000 {
                group.addTask {
                    let uuid = UUID().uuidString
                    dictionary[uuid] = uuid
                    dictionary[uuid] = nil
                }
            }
        }
    }

    func testRemoveValueReturnsPreviousValue() {
        let dictionary = ThreadSafeDictionary<Int, String>()
        dictionary[7] = "seven"
        XCTAssertEqual(dictionary.removeValue(forKey: 7), "seven")
        XCTAssertNil(dictionary.removeValue(forKey: 7))
        XCTAssertNil(dictionary[7])
    }
}
