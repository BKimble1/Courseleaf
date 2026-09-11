import XCTest
@testable import Archive
final class ArchiveModuleTests: XCTestCase {
    func testModuleName() { XCTAssertEqual(ArchiveModule.name, "Archive") }
}
