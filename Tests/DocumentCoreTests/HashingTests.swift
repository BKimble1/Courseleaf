import XCTest
@testable import DocumentCore

final class HashingTests: XCTestCase {
    func testSHA256KnownVectors() {
        XCTAssertEqual(SHA256.hexDigest(""), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(SHA256.hexDigest("abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(SHA256.hexDigest("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"),
                       "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
        // One million 'a' characters.
        let million = Data(repeating: UInt8(ascii: "a"), count: 1_000_000)
        XCTAssertEqual(SHA256.hexDigest(million), "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0")
    }

    func testSHA256IncrementalMatchesOneShot() {
        var h = SHA256.Hasher()
        let data = Data((0..<1000).map { UInt8($0 % 251) })
        for chunk in stride(from: 0, to: data.count, by: 37) {
            h.update(data[chunk..<min(chunk + 37, data.count)])
        }
        XCTAssertEqual(h.finalize(), SHA256.hash(data))
    }

    func testCRC32KnownVector() {
        XCTAssertEqual(CRC32.checksum(Data("123456789".utf8)), 0xCBF43926)
        XCTAssertEqual(CRC32.checksum(Data()), 0)
    }
}
