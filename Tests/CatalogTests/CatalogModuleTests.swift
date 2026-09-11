import XCTest
@testable import Catalog
final class CatalogModuleTests: XCTestCase {
    func testModuleName() { XCTAssertEqual(CatalogModule.name, "Catalog") }
}
