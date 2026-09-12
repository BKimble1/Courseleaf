import XCTest
@testable import Catalog

final class FTSQueryTests: XCTestCase {
    func testQuotesEveryTokenAndPrefixesTheLast() {
        XCTAssertEqual(FTSQuery.sanitize("newton second law"), "\"newton\" \"second\" \"law\"*")
        XCTAssertEqual(FTSQuery.sanitize("  force "), "\"force\"*")
    }

    func testEmptyQueryYieldsNil() {
        XCTAssertNil(FTSQuery.sanitize(""))
        XCTAssertNil(FTSQuery.sanitize("   \n\t "))
    }

    func testDoubleQuotesAreEscapedAndOperatorsNeutralized() {
        XCTAssertEqual(FTSQuery.sanitize("say \"hi\""), "\"say\" \"\"\"hi\"\"\"*")
        XCTAssertEqual(FTSQuery.sanitize("a OR b"), "\"a\" \"OR\" \"b\"*")
        XCTAssertEqual(FTSQuery.sanitize("NEAR(x y)"), "\"NEAR(x\" \"y)\"*")
        XCTAssertEqual(FTSQuery.sanitize("col:term*"), "\"col:term*\"*")
    }
}
