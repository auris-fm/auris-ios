import XCTest
@testable import podcasts

/// Boundary tests for wire-number → Int64 conversion: out-of-range values
/// degrade to nil instead of trapping (PR #14 review, both waves).
final class CloudRouteEventInt64BoundaryTests: XCTestCase {
    private func int64(_ value: Double) -> Int64? {
        CloudRouteJSONValue.double(value).int64Value
    }

    func testInRangeValuesConvert() {
        XCTAssertEqual(int64(0), 0)
        XCTAssertEqual(int64(1_000_000), 1_000_000)
        XCTAssertEqual(int64(-1_000_000), -1_000_000)
        // 2^62 is exactly representable (Int64.max/2 rounds up to it).
        XCTAssertEqual(int64(Double(Int64.max) / 2), 4_611_686_018_427_387_904)
        XCTAssertEqual(int64(-9_223_372_036_854_775_808.0), .min)
    }

    func testExactInt64MinConverts() {
        // -2^63 is exactly representable as a Double and is a valid Int64.
        XCTAssertEqual(int64(-9_223_372_036_854_775_808.0), Int64.min)
    }

    func testExactPowerOfTwoBeyondMaxReturnsNilInsteadOfTrapping() {
        // 2^63: integral, rounds to itself, and Double(Int64.max) == 2^63 —
        // the `<=` form admitted it and Int64(value) trapped.
        XCTAssertEqual(int64(9_223_372_036_854_775_808.0), nil)
    }

    func testSlightlyBeyondMaxReturnsNil() {
        XCTAssertEqual(int64(9_223_372_036_854_775_808.0 + 1024), nil)
    }

    func testAstronomicValuesReturnNil() {
        XCTAssertEqual(int64(1e300), nil)
        XCTAssertEqual(int64(-1e300), nil)
    }

    func testNonIntegralValuesReturnNil() {
        XCTAssertNil(int64(1.5))
        XCTAssertNil(int64(-0.5))
    }
}
