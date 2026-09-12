import Foundation
import XCTest
import DocumentCore
@testable import Catalog

/// Deterministic library fixtures for catalog tests. IDs are fresh per call
/// but every date comes from a fixed clock so ordering is reproducible.
enum CatalogFixtures {
    static let epoch = Date(timeIntervalSinceReferenceDate: 800_000_000)
    static func date(_ offset: TimeInterval) -> Date { epoch.addingTimeInterval(offset) }

    static func textObject(_ text: String, x: Double = 72, y: Double = 100) -> CanvasObject {
        CanvasObject(frame: PageRect(x: x, y: y, width: 200, height: 40), content: .text(TextContent(text: text)), createdAt: epoch)
    }

    /// A notebook with `pageCount` template pages; typed text per page from `texts` (index -> text).
    static func notebook(title: String, folderID: FolderID? = nil, pageCount: Int = 2, texts: [Int: String] = [:],
                         kind: DocumentKind = .notebook, isFavorite: Bool = false, created: TimeInterval = 0) -> DocumentSnapshot {
        var snapshot = DocumentSnapshot.newNotebook(title: title, folderID: folderID, pageCount: pageCount, kind: kind, now: date(created))
        snapshot.document.isFavorite = isFavorite
        for (index, text) in texts {
            let id = snapshot.document.pageIDs[index]
            snapshot.pages[id]!.objects.append(textObject(text))
        }
        return snapshot
    }

    /// Converts page `index` into a PDF-backed page (fake asset; the catalog never opens assets).
    static func makePDFPage(_ snapshot: inout DocumentSnapshot, index: Int) {
        let id = snapshot.document.pageIDs[index]
        let asset = SourceAsset(sha256: String(repeating: "ab", count: 32), mediaType: .pdf, byteCount: 10, pageCount: 1, importedAt: epoch)
        snapshot.assets[asset.id] = asset
        let box = PageRect(x: 0, y: 0, width: 612, height: 792)
        snapshot.pages[id]!.background = .pdf(PDFPageSource(assetID: asset.id, pageIndex: 0, mediaBox: box, cropBox: box, rotation: .degrees0))
    }

    /// Simulates an edit commit: bumps the revision of the given page and the document head.
    @discardableResult
    static func editPage(_ snapshot: inout DocumentSnapshot, index: Int, appending text: String? = nil, at: TimeInterval = 10) -> RevisionID {
        let id = snapshot.document.pageIDs[index]
        let head = snapshot.headRevision!
        let revision = Revision(parentIDs: [head.id], sequence: head.sequence + 1, createdAt: date(at), changedPageIDs: [id])
        snapshot.revisions[revision.id] = revision
        snapshot.document.revisionHead = revision.id
        snapshot.document.modifiedAt = date(at)
        snapshot.pages[id]!.revisionID = revision.id
        snapshot.pages[id]!.modifiedAt = date(at)
        if let text { snapshot.pages[id]!.objects.append(textObject(text, y: 300)) }
        return revision.id
    }

    static func addProblem(_ snapshot: inout DocumentSnapshot, index: Int, title: String, status: ProblemStatus = .unfinished) {
        let id = snapshot.document.pageIDs[index]
        snapshot.pages[id]!.problem = ProblemMetadata(title: title, status: status)
    }

    @discardableResult
    static func addReview(_ snapshot: inout DocumentSnapshot, index: Int, prompt: String?, created: TimeInterval,
                          region: PageRect? = nil, state: ReviewState = .pending, answerTapeID: ObjectID? = nil) -> ReviewItem {
        let id = snapshot.document.pageIDs[index]
        let item = ReviewItem(pageID: id, region: region, prompt: prompt, answerTapeID: answerTapeID, state: state, createdAt: date(created))
        snapshot.document.reviewItems.append(item)
        return item
    }

    static func record(_ snapshot: DocumentSnapshot, index: Int, kind: SearchRecordKind, text: String,
                       bounds: PageRect? = PageRect(x: 10, y: 20, width: 100, height: 12), confidence: Double? = nil) -> SearchRecord {
        let page = snapshot.orderedPages[index]
        return SearchRecord(documentID: snapshot.document.id, pageID: page.id, revisionID: page.revisionID, kind: kind,
                            text: text, bounds: bounds, confidence: confidence)
    }
}

/// A temporary directory removed at the end of the test.
final class TemporaryDirectory {
    let url: URL
    init(_ name: String = "CatalogTests") {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: url) }
    func file(_ name: String) -> URL { url.appendingPathComponent(name) }
}

extension XCTestCase {
    /// Runs `body` against an in-memory catalog and an on-disk catalog so both backends are exercised.
    func withEachBackend(_ test: String = #function, _ body: (CatalogDatabase, String) async throws -> Void) async throws {
        let memory = try CatalogDatabase.inMemory()
        try await body(memory, "memory")
        await memory.close()
        let dir = TemporaryDirectory()
        let disk = try CatalogDatabase.open(at: dir.file("catalog.sqlite"))
        try await body(disk, "disk")
        await disk.close()
        withExtendedLifetime(dir) {}
    }
}

// MARK: - Async assertions (XCTAssert* autoclosures cannot await an actor)

func assertEqual<T: Equatable>(_ expression1: @autoclosure () async throws -> T, _ expression2: @autoclosure () async throws -> T,
                               _ message: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) async {
    do {
        let a = try await expression1()
        let b = try await expression2()
        XCTAssertEqual(a, b, message(), file: file, line: line)
    } catch { XCTFail("threw \(error) \(message())", file: file, line: line) }
}

func assertTrue(_ expression: @autoclosure () async throws -> Bool, _ message: @autoclosure () -> String = "",
                file: StaticString = #filePath, line: UInt = #line) async {
    do { let v = try await expression(); XCTAssertTrue(v, message(), file: file, line: line) }
    catch { XCTFail("threw \(error) \(message())", file: file, line: line) }
}

func assertFalse(_ expression: @autoclosure () async throws -> Bool, _ message: @autoclosure () -> String = "",
                 file: StaticString = #filePath, line: UInt = #line) async {
    do { let v = try await expression(); XCTAssertFalse(v, message(), file: file, line: line) }
    catch { XCTFail("threw \(error) \(message())", file: file, line: line) }
}

func assertNil(_ expression: @autoclosure () async throws -> Any?, _ message: @autoclosure () -> String = "",
               file: StaticString = #filePath, line: UInt = #line) async {
    do { let v = try await expression(); XCTAssertNil(v, message(), file: file, line: line) }
    catch { XCTFail("threw \(error) \(message())", file: file, line: line) }
}

func assertGreaterThan<T: Comparable>(_ expression1: @autoclosure () async throws -> T, _ expression2: @autoclosure () async throws -> T,
                                      _ message: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) async {
    do { let a = try await expression1(); let b = try await expression2(); XCTAssertGreaterThan(a, b, message(), file: file, line: line) }
    catch { XCTFail("threw \(error) \(message())", file: file, line: line) }
}

func assertThrowsError<T>(_ expression: @autoclosure () async throws -> T, _ message: @autoclosure () -> String = "",
                          file: StaticString = #filePath, line: UInt = #line, _ handler: (Error) -> Void = { _ in }) async {
    do {
        _ = try await expression()
        XCTFail("did not throw \(message())", file: file, line: line)
    } catch { handler(error) }
}
