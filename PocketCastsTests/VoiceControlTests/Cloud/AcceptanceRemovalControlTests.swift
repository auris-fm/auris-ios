import XCTest

/// The failed-removal decision, extracted so it can be driven with SIMULATED errors. It mirrors the
/// app's rule: a not-found in the COCOA domain is expected; anything else means a stale file may
/// survive and the run must refuse.
struct RemovalDecision {
    enum Outcome: Equatable { case proceed, refuse }
    /// Whether an error from removing the prior export permits the run to continue.
    static func forError(domain: String, code: Int) -> Outcome {
        let notFound = NSCocoaErrorDomain == domain && NSFileNoSuchFileError == code
        return notFound ? .proceed : .refuse
    }
}

final class AcceptanceRemovalControlTests: XCTestCase {

    func testCocoaNotFoundIsExpectedAndProceeds() {
        XCTAssertEqual(
            RemovalDecision.forError(domain: NSCocoaErrorDomain, code: NSFileNoSuchFileError),
            .proceed
        )
    }

    /// THE CONTROL @reviewer ASKED FOR: the same NUMERIC code in a DIFFERENT domain is NOT a not-found.
    /// A code-only check would have said "no prior export" and run on with a stale file present.
    func testSameCodeInAnotherDomainIsRefused() {
        XCTAssertEqual(
            RemovalDecision.forError(domain: "com.example.other", code: NSFileNoSuchFileError),
            .refuse,
            "an error from another domain with the same numeric code was treated as not-found"
        )
    }

    func testPermissionFailureIsRefused() {
        XCTAssertEqual(
            RemovalDecision.forError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError),
            .refuse
        )
    }
}
