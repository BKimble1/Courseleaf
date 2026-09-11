import XCTest
@testable import Fixtures
final class FixturesModuleTests: XCTestCase {
    func testModuleName() { XCTAssertEqual(FixturesModule.name, "Fixtures") }
}
