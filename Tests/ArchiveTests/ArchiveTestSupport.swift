import Foundation
import XCTest
import DocumentCore
@testable import Archive

// Shared helpers: a rich fixture snapshot, temporary directories, an
// archive rewriter for building malicious variants of a valid archive, and a
// raw ZIP builder for byte-level corruption cases.

let fixtureEpoch = Date(timeIntervalSince1970: 1_757_600_000)
func fixtureDate(_ offsetSeconds: Double) -> Date { fixtureEpoch.addingTimeInterval(offsetSeconds) }

/// Deterministic UUID source (xorshift) for reproducible re-identification.
final class SeededUUIDs {
    private var state: UInt64
    init(seed: UInt64) { state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed }
    func next() -> UUID {
        func step() -> UInt64 { state ^= state << 13; state ^= state >> 7; state ^= state << 17; return state }
        let a = step(), b = step()
        func byte(_ v: UInt64, _ i: Int) -> UInt8 { UInt8((v >> (UInt64(i) * 8)) & 0xFF) }
        return UUID(uuid: (byte(a, 0), byte(a, 1), byte(a, 2), byte(a, 3), byte(a, 4), byte(a, 5), byte(a, 6), byte(a, 7),
                           byte(b, 0), byte(b, 1), byte(b, 2), byte(b, 3), byte(b, 4), byte(b, 5), byte(b, 6), byte(b, 7)))
    }
}

struct Fixture {
    var snapshot: DocumentSnapshot
    var assetBytes: [AssetID: Data]
    var provider: AssetDataProvider {
        let bytes = assetBytes
        return { asset in
            guard let d = bytes[asset.id] else { throw ArchiveError.missingEntry(asset.relativePath) }
            return d
        }
    }

    static func pngBytes(seed: UInt8, length: Int = 600) -> Data {
        var d = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        var x = UInt32(seed) &+ 1
        while d.count < length { x = x &* 1_664_525 &+ 1_013_904_223; d.append(UInt8(x >> 24)) }
        return d
    }

    static func inkBytes(strokeCount: Int, offset: Double) -> Data {
        var strokes: [ReferenceStroke] = []
        for i in 0..<strokeCount {
            let base = Double(i) * 10 + offset
            let pts = (0..<12).map { PagePoint(x: base + Double($0) * 3.5, y: 100 + Double($0 * $0) * 0.25) }
            strokes.append(ReferenceStroke(tool: i % 2 == 0 ? .pen : .highlighter, color: RGBAColor(hex: "#1F3A93")!,
                                           width: 2.5 + Double(i), points: pts,
                                           transform: .translation(x: Double(i), y: 0),
                                           mask: i % 3 == 0 ? PageRect(x: base, y: 90, width: 30, height: 60).corners : nil))
        }
        return try! ReferenceInkEngine().encode(ReferenceDrawing(strokes: strokes))
    }

    /// A notebook with ink, images, a PDF page, a problem page, review items,
    /// bookmarks, a deleted page kept with content and a two-step history.
    static func make(title: String = "Physics 101", seed: UInt8 = 1) -> Fixture {
        let t0 = fixtureDate(0), t1 = fixtureDate(60.5), t2 = fixtureDate(120.25)
        let rev1 = Revision(parentIDs: [], sequence: 1, createdAt: t0, changedPageIDs: [], summary: "Created")
        var rev2 = Revision(parentIDs: [rev1.id], sequence: 2, createdAt: t2, changedPageIDs: [], summary: "Edited")

        let ink1 = PendingAsset.make(data: inkBytes(strokeCount: 5, offset: Double(seed)), mediaType: .inkDrawing, now: t1)
        let ink2 = PendingAsset.make(data: inkBytes(strokeCount: 2, offset: Double(seed) + 200), mediaType: .inkDrawing, now: t1)
        let png = PendingAsset.make(data: pngBytes(seed: seed), mediaType: .png, originalFileName: "diagram.png", now: t1)
        let pdf = PendingAsset.make(data: Data("%PDF-1.4\n% fixture \(seed)\n%%EOF\n".utf8), mediaType: .pdf,
                                    originalFileName: "lecture.pdf", pageCount: 3, now: t0)
        let assets = [ink1, ink2, png, pdf]

        let tape = CanvasObject(frame: PageRect(x: 300, y: 500, width: 200, height: 40), content: .tape(TapeContent(label: "answer")), createdAt: t1)
        let page1 = Page(size: .letter, background: .template(.lined), objects: [
            CanvasObject(frame: PageRect(x: 72, y: 72, width: 200, height: 150), rotation: 0.1,
                         content: .image(ImageContent(assetID: png.asset.id, crop: PageRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8), opacity: 0.9)), createdAt: t1),
            CanvasObject(frame: PageRect(x: 72, y: 300, width: 300, height: 60), isLocked: true,
                         content: .text(TextContent(text: "Newton's second law: F = ma", fontSize: 18, weight: .semibold)), createdAt: t1),
            CanvasObject(frame: PageRect(x: 100, y: 400, width: 120, height: 80),
                         content: .shape(ShapeContent(kind: .arrow, strokeColor: RGBAColor(hex: "#C0392B")!, strokeWidth: 3)), createdAt: t1),
            tape,
        ], inkLayers: [InkLayer(engine: .reference, dataAssetID: ink1.asset.id)],
        problem: ProblemMetadata(title: "Block on incline", sourceReference: "HW3 #4", given: "m = 2 kg, θ = 30°", find: "a",
                                 resultRegion: PageRect(x: 300, y: 500, width: 200, height: 40), status: .checkAgain),
        isBookmarked: true, revisionID: rev2.id, createdAt: t0, modifiedAt: t2)

        let page2 = Page(size: PageSize(width: 792, height: 612),
                         background: .pdf(PDFPageSource(assetID: pdf.asset.id, pageIndex: 1,
                                                        mediaBox: PageRect(x: 0, y: 0, width: 612, height: 792),
                                                        cropBox: PageRect(x: 0, y: 0, width: 612, height: 792), rotation: .degrees90)),
                         inkLayers: [InkLayer(engine: .reference, dataAssetID: nil)], revisionID: rev1.id, createdAt: t0, modifiedAt: t0)
        let page3 = Page(size: .a4, background: .template(.grid), inkLayers: [InkLayer(engine: .reference, dataAssetID: ink2.asset.id, isVisible: false)],
                         isBookmarked: false, revisionID: rev2.id, createdAt: t1, modifiedAt: t2)
        let deleted = Page(size: .letter, background: .image(png.asset.id), inkLayers: [InkLayer(engine: .reference)],
                           revisionID: rev1.id, createdAt: t0, modifiedAt: t1)
        rev2.changedPageIDs = [page1.id, page3.id]

        let review1 = ReviewItem(pageID: page1.id, region: PageRect(x: 300, y: 500, width: 200, height: 40), prompt: "Find a",
                                 answerTapeID: tape.id, state: .pending, createdAt: t1)
        let review2 = ReviewItem(pageID: deleted.id, prompt: "Old", state: .reviewed, createdAt: t0, lastReviewedAt: t1,
                                 history: [ReviewEvent(action: .added, at: t0), ReviewEvent(action: .markedReviewed, at: t1)])

        let doc = Document(kind: .notebook, title: title, folderID: FolderID(), language: "en",
                           cover: CoverStyle(palette: .ocean, pattern: .dots), defaultTemplate: .lined, defaultPageSize: .letter,
                           isFavorite: true, pageIDs: [page1.id, page2.id, page3.id],
                           deletedPages: [DeletedPage(page: deleted, originalIndex: 1, deletedAt: t1)],
                           reviewItems: [review1, review2], revisionHead: rev2.id, createdAt: t0, modifiedAt: t2,
                           lastOpenedAt: t2, lastViewedPageIndex: 2)
        let snapshot = DocumentSnapshot(
            document: doc,
            pages: [page1.id: page1, page2.id: page2, page3.id: page3, deleted.id: deleted],
            assets: Dictionary(uniqueKeysWithValues: assets.map { ($0.asset.id, $0.asset) }),
            revisions: [rev1.id: rev1, rev2.id: rev2])
        precondition(snapshot.validate().isEmpty, "\(snapshot.validate())")
        return Fixture(snapshot: snapshot, assetBytes: Dictionary(uniqueKeysWithValues: assets.map { ($0.asset.id, $0.data) }))
    }
}

extension XCTestCase {
    func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArchiveTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    @discardableResult
    func writeFixtureArchive(_ fixture: Fixture, to url: URL, includeHistory: Bool = true) throws -> ArchiveManifest {
        try DocumentArchiveWriter.write(snapshot: fixture.snapshot, assetData: fixture.provider, includeHistory: includeHistory,
                                        to: url, producer: "Courseleaf Tests 1.0 (1)", clock: ManualClock(start: fixtureDate(1000)))
    }

    func assertArchiveError<T>(_ expression: @autoclosure () throws -> T, _ expected: ArchiveError,
                               file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try expression(), file: file, line: line) { error in
            XCTAssertEqual(error as? ArchiveError, expected, "got \(error)", file: file, line: line)
        }
    }

    func assertArchiveError<T>(_ expression: @autoclosure () throws -> T, file: StaticString = #filePath, line: UInt = #line,
                               _ matches: (ArchiveError) -> Bool) {
        XCTAssertThrowsError(try expression(), file: file, line: line) { error in
            guard let e = error as? ArchiveError, matches(e) else { return XCTFail("unexpected error \(error)", file: file, line: line) }
        }
    }
}

/// Reads every entry of an archive, lets the test mutate the list, and
/// writes the result back. With `regenerateManifest` the `archive.json`
/// records (sizes and digests) are rebuilt so only the intended defect remains.
enum ArchiveRewriter {
    typealias Entry = (name: String, data: Data)

    static func entries(of url: URL) throws -> [Entry] {
        let zip = try ZipReader(url: url)
        return try zip.entries.map { ($0.name, try zip.data(for: $0)) }
    }

    static func rewrite(_ url: URL, regenerateManifest: Bool, _ transform: (inout [Entry]) throws -> Void) throws {
        var list = try entries(of: url)
        try transform(&list)
        if regenerateManifest {
            let idx = list.firstIndex { $0.name == ArchiveManifest.fileName }!
            var manifest = try DocumentJSON.decoder().decode(ArchiveManifest.self, from: list[idx].data)
            manifest.entries = list.filter { $0.name != ArchiveManifest.fileName }
                .map { ArchiveEntryRecord(path: $0.name, size: $0.data.count, sha256: SHA256.hexDigest($0.data)) }
            manifest.totalSize = manifest.entries.reduce(0) { $0 + $1.size }
            list[idx].data = try DocumentJSON.encoder().encode(manifest)
        }
        try FileManager.default.removeItem(at: url)
        let writer = try ZipWriter(url: url, modificationDate: fixtureDate(2000))
        for e in list { try writer.addEntry(name: e.name, data: e.data) }
        try writer.finish()
    }

    static func manifest(of url: URL) throws -> ArchiveManifest {
        let data = try entries(of: url).first { $0.name == ArchiveManifest.fileName }!.data
        return try DocumentJSON.decoder().decode(ArchiveManifest.self, from: data)
    }

    static func replaceManifest(at url: URL, _ mutate: (inout ArchiveManifest) -> Void) throws {
        try rewrite(url, regenerateManifest: false) { list in
            let idx = list.firstIndex { $0.name == ArchiveManifest.fileName }!
            var m = try DocumentJSON.decoder().decode(ArchiveManifest.self, from: list[idx].data)
            mutate(&m)
            list[idx].data = try DocumentJSON.encoder().encode(m)
        }
    }

    /// Manifest data for a hand-built archive listing exactly `entries`.
    static func manifestData(kind: ArchiveKind = .document, formatVersion: Int = DocumentSchema.current,
                             listing entries: [Entry]) throws -> Data {
        let m = ArchiveManifest(formatVersion: formatVersion, kind: kind, createdAt: fixtureDate(5), producer: "test",
                                entries: entries.map { ArchiveEntryRecord(path: $0.name, size: $0.data.count, sha256: SHA256.hexDigest($0.data)) })
        return try DocumentJSON.encoder().encode(m)
    }
}

/// Byte-level ZIP builder that does not validate anything, for constructing
/// containers `ZipWriter` refuses to produce.
struct RawZip {
    struct Entry {
        var name: String
        var data: Data
        var crc: UInt32? = nil           // central directory CRC (default: real)
        var localCRC: UInt32? = nil      // local header CRC (default: same as central)
        var method: UInt16 = 0
        var localOffset: UInt32? = nil   // central directory offset (default: real)
        /// When false the local header + data are not emitted (only the central record is).
        var emitLocal = true
    }

    static func le16(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8)] }
    static func le32(_ v: UInt32) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8(v >> 24)] }

    static func localHeader(name: String, data: Data, crc: UInt32, method: UInt16 = 0) -> [UInt8] {
        let n = [UInt8](name.utf8)
        return le32(0x0403_4B50) + le16(10) + le16(0x0800) + le16(method) + le16(0) + le16(0)
            + le32(crc) + le32(UInt32(data.count)) + le32(UInt32(data.count)) + le16(UInt16(n.count)) + le16(0) + n
    }

    static func centralHeader(name: String, size: UInt32, crc: UInt32, offset: UInt32, method: UInt16 = 0) -> [UInt8] {
        let n = [UInt8](name.utf8)
        return le32(0x0201_4B50) + le16(0x031E) + le16(10) + le16(0x0800) + le16(method) + le16(0) + le16(0)
            + le32(crc) + le32(size) + le32(size) + le16(UInt16(n.count)) + le16(0) + le16(0)
            + le16(0) + le16(0) + le32(0) + le32(offset) + n
    }

    static func eocd(entryCount: UInt16, cdSize: UInt32, cdOffset: UInt32) -> [UInt8] {
        le32(0x0605_4B50) + le16(0) + le16(0) + le16(entryCount) + le16(entryCount) + le32(cdSize) + le32(cdOffset) + le16(0)
    }

    static func build(_ entries: [Entry], entryCountOverride: UInt16? = nil) -> Data {
        var out: [UInt8] = []
        var central: [UInt8] = []
        for e in entries {
            let crc = e.crc ?? CRC32.checksum(e.data)
            let offset = UInt32(out.count)
            if e.emitLocal {
                out += localHeader(name: e.name, data: e.data, crc: e.localCRC ?? crc, method: e.method)
                out += [UInt8](e.data)
            }
            central += centralHeader(name: e.name, size: UInt32(e.data.count), crc: crc, offset: e.localOffset ?? offset, method: e.method)
        }
        let cdOffset = UInt32(out.count)
        out += central
        out += eocd(entryCount: entryCountOverride ?? UInt16(entries.count), cdSize: UInt32(central.count), cdOffset: cdOffset)
        return Data(out)
    }

    /// A syntactically complete document-kind archive whose only oddity is the given extra entries.
    static func archive(with entries: [Entry], listed: Bool = true) throws -> Data {
        var all = entries
        let manifest = try ArchiveRewriter.manifestData(listing: listed ? entries.map { ($0.name, $0.data) } : [])
        all.append(Entry(name: ArchiveManifest.fileName, data: manifest))
        return build(all)
    }
}
