import XCTest
@testable import Persistence
final class PersistenceModuleTests: XCTestCase {
    func testModuleName() { XCTAssertEqual(PersistenceModule.name, "Persistence") }
}
