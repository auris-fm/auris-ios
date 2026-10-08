import XCTest
@testable import podcasts

/// Pins the seam's two optional capabilities so they are exercised rather than
/// merely declared (PR #19 review): implementing **only** the preferred
/// rejected-token form must satisfy conformance, and the convenience no-arg
/// call must forward to it with `nil`.
final class CloudTokenSeamContractTests: XCTestCase {
    private final class PreferredFormOnly: CloudTokenProviding {
        var seen: [String??] = []
        func token() async -> String? { "token" }
        func handleUnauthorized(rejectedToken: String?) async { seen.append(rejectedToken) }
    }

    func testConformanceRequiresOnlyThePreferredForm() async {
        let provider = PreferredFormOnly()
        // Compiles and runs without implementing the legacy no-arg requirement.
        await provider.handleUnauthorized()
        XCTAssertEqual(provider.seen.count, 1, "the convenience form forwards to the preferred one")
        XCTAssertNil(provider.seen[0] ?? nil, "it forwards nil, meaning 'credential unknown'")
    }

    func testConvenienceFormForwardsToThePreferredFormWithTheToken() async {
        let provider = PreferredFormOnly()
        await provider.handleUnauthorized(rejectedToken: "token-that-401d")
        XCTAssertEqual(provider.seen.compactMap { $0 }, ["token-that-401d"])
    }

    func testPrepareDefaultsToANoOp() async {
        let provider = PreferredFormOnly()
        await provider.prepare()  // must not require an implementation
    }
}
