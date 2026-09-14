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

    func testRemoveValueReturnsRemovedValue() {
        let dictionary = ThreadSafeDictionary<String, String>()
        dictionary["key"] = "value"

        XCTAssertEqual(dictionary.removeValue(forKey: "key"), "value")
        XCTAssertNil(dictionary["key"])
    }

    func testRemoveValueReturnsNilForMissingKey() {
        let dictionary = ThreadSafeDictionary<String, String>()

        XCTAssertNil(dictionary.removeValue(forKey: "key"))
    }

    func testRemoveValueTwiceReturnsNil() {
        let dictionary = ThreadSafeDictionary<Int, String>()
        dictionary[7] = "seven"
        XCTAssertEqual(dictionary.removeValue(forKey: 7), "seven")
        XCTAssertNil(dictionary.removeValue(forKey: 7))
        XCTAssertNil(dictionary[7])
    }

    func testConcurrentInsertAndRemoveValue() async {
        let dictionary = ThreadSafeDictionary<Int, String>()

        await withTaskGroup(of: Void.self) { group in
            for index in 0..<10_000 {
                group.addTask {
                    dictionary[index] = "\(index)"
                    dictionary.removeValue(forKey: index)
                }
            }
        }

        XCTAssertFalse(dictionary.contains(where: { _ in true }))
    }
}
