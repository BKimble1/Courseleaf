import XCTest
import DocumentCore
@testable import Courseleaf

// "Search in Notebook" answers from the open document without waiting for the
// catalog, so the part that reads the snapshot is pure and tested here.
final class EditorSearchTests: XCTestCase {

    private let fixedDate = Date(timeIntervalSince1970: 1_757_600_000)

    private func textObject(_ text: String, at rect: PageRect) -> CanvasObject {
        CanvasObject(frame: rect, content: .text(TextContent(text: text)), createdAt: fixedDate)
    }

    private func tapeObject(label: String?, at rect: PageRect) -> CanvasObject {
        CanvasObject(frame: rect, content: .tape(TapeContent(label: label)), createdAt: fixedDate)
    }

    private func snapshot(pages: [Page]) -> DocumentSnapshot {
        let revision = Revision(parentIDs: [], sequence: 1, createdAt: fixedDate, changedPageIDs: pages.map(\.id))
        var byID: [PageID: Page] = [:]
        for var page in pages {
            page.revisionID = revision.id
            byID[page.id] = page
        }
        let document = Document(title: "Notebook", pageIDs: pages.map(\.id), revisionHead: revision.id,
                                createdAt: fixedDate, modifiedAt: fixedDate)
        return DocumentSnapshot(document: document, pages: byID, assets: [:], revisions: [revision.id: revision])
    }

    private func page(objects: [CanvasObject] = [], problem: ProblemMetadata? = nil) -> Page {
        Page(size: .letter, background: .template(.lined), objects: objects, problem: problem,
             revisionID: RevisionID(), createdAt: fixedDate, modifiedAt: fixedDate)
    }

    func testFindsTypedTextTapeLabelsAndProblemMetadata() {
        let first = page(objects: [textObject("The Laplace transform of a step", at: PageRect(x: 40, y: 60, width: 300, height: 40))])
        let second = page(objects: [tapeObject(label: "laplace answer", at: PageRect(x: 10, y: 10, width: 120, height: 28))],
                          problem: ProblemMetadata(title: "Problem 4.2 Laplace", find: "the transform",
                                                   resultRegion: PageRect(x: 0, y: 400, width: 300, height: 80)))
        let hits = NotebookSearch.documentHits(query: "laplace", snapshot: snapshot(pages: [first, second]))

        XCTAssertEqual(hits.count, 3)
        XCTAssertEqual(hits.filter { $0.kind == .text }.count, 1)
        XCTAssertEqual(hits.filter { $0.kind == .tape }.count, 1)
        XCTAssertEqual(hits.filter { $0.kind == .problem }.count, 1)
        XCTAssertEqual(Set(hits.map(\.pageIndex)), [0, 1])

        let textHit = hits.first { $0.kind == .text }
        XCTAssertNotNil(textHit)
        XCTAssertEqual(textHit?.pageIndex, 0)
        XCTAssertEqual(textHit?.bounds, PageRect(x: 40, y: 60, width: 300, height: 40))
        XCTAssertEqual(hits.first { $0.kind == .problem }?.bounds, PageRect(x: 0, y: 400, width: 300, height: 80))
    }

    func testSearchIgnoresShortQueriesAndNonTextObjects() {
        let objects = [
            textObject("integral", at: PageRect(x: 0, y: 0, width: 100, height: 20)),
            CanvasObject(frame: PageRect(x: 0, y: 40, width: 80, height: 80),
                         content: .shape(ShapeContent(kind: .rectangle)), createdAt: fixedDate),
            tapeObject(label: nil, at: PageRect(x: 0, y: 140, width: 80, height: 24)),
        ]
        let document = snapshot(pages: [page(objects: objects)])
        XCTAssertTrue(NotebookSearch.documentHits(query: "i", snapshot: document).isEmpty)
        XCTAssertTrue(NotebookSearch.documentHits(query: "   ", snapshot: document).isEmpty)
        XCTAssertEqual(NotebookSearch.documentHits(query: "integral", snapshot: document).count, 1)
        XCTAssertTrue(NotebookSearch.documentHits(query: "rectangle", snapshot: document).isEmpty)
    }

    func testSearchIsCaseAndDiacriticInsensitive() {
        let document = snapshot(pages: [page(objects: [textObject("Théorème de Gauss", at: PageRect(x: 0, y: 0, width: 200, height: 20))])])
        XCTAssertEqual(NotebookSearch.documentHits(query: "theoreme", snapshot: document).count, 1)
        XCTAssertEqual(NotebookSearch.documentHits(query: "GAUSS", snapshot: document).count, 1)
    }

    func testSearchRespectsItsLimit() {
        let pages = (0..<50).map { index in
            page(objects: [textObject("match \(index)", at: PageRect(x: 0, y: 0, width: 100, height: 20))])
        }
        let hits = NotebookSearch.documentHits(query: "match", snapshot: snapshot(pages: pages), limit: 10)
        XCTAssertLessThanOrEqual(hits.count, 11)
        XCTAssertGreaterThanOrEqual(hits.count, 10)
    }

    func testSnippetCentresOnTheMatchAndMarksTruncation() {
        let long = String(repeating: "a", count: 200) + " needle " + String(repeating: "b", count: 200)
        let snippet = NotebookSearch.snippet(of: long, around: "needle", context: 10)
        XCTAssertTrue(snippet.contains("needle"))
        XCTAssertTrue(snippet.hasPrefix("…"))
        XCTAssertTrue(snippet.hasSuffix("…"))
        XCTAssertLessThan(snippet.count, 40)

        // Newlines are collapsed so a row stays on one line.
        XCTAssertFalse(NotebookSearch.snippet(of: "one\ntwo needle three", around: "needle").contains("\n"))
        // A miss still yields readable context rather than nothing.
        XCTAssertFalse(NotebookSearch.snippet(of: "some text", around: "zzz").isEmpty)
    }
}
