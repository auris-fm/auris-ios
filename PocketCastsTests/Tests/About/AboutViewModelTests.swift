import XCTest

@testable import podcasts

final class AboutViewModelTests: XCTestCase {
    func testBuildDateTextLabelsTheBuildDateTheBinaryCarries() {
        let viewModel = AboutViewModel(buildDateProvider: { "2026-10-13 09:32 +0800" })

        XCTAssertEqual(viewModel.buildDateText, "Built 2026-10-13 09:32 +0800")
    }

    func testBuildDateTextIsAbsentWhenTheBinaryCarriesNoBuildDate() {
        let viewModel = AboutViewModel(buildDateProvider: { nil })

        XCTAssertNil(viewModel.buildDateText)
    }
}
