import XCTest
@testable import Workspace
final class WorkspaceAPITests: XCTestCase {
    func testScopeEquality() { XCTAssertEqual(LibraryScope.recents, LibraryScope.recents) }
}
