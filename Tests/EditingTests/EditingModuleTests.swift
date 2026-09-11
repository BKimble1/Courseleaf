import XCTest
@testable import Editing
final class EditingModuleTests: XCTestCase {
    func testModuleName() { XCTAssertEqual(EditingModule.name, "Editing") }
}
