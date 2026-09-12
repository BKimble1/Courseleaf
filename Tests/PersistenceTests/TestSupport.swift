import XCTest
import DocumentCore
@testable import Persistence

/// Shared fixtures for the Persistence tests. Every test works in its own
/// temporary directory under `FileManager.default.temporaryDirectory`.
enum Support {
    static let now = Date(timeIntervalSince1970: 1_757_600_000.25)

    static func makeTempDirectory(_ name: String = "PersistenceTests") throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func inkData(_ seed: String) -> Data {
        let drawing = ReferenceDrawing(strokes: [ReferenceStroke(points: [PagePoint(x: 1, y: 1), PagePoint(x: 20, y: 30)])])
        var data = try! ReferenceInkEngine().encode(drawing)
        data.append(contentsOf: Array(seed.utf8))
        return data
    }

    /// A three-page notebook with an ink asset on page 0, an image object on page 1 and a review item.
    static func makeSnapshot(title: String = "Physics 1", pageCount: Int = 3) -> (snapshot: DocumentSnapshot, assets: [PendingAsset]) {
        var snap = DocumentSnapshot.newNotebook(title: title, template: .cornell, pageCount: pageCount, now: now)
        let ink = PendingAsset.make(data: inkData("ink-1"), mediaType: .inkDrawing, now: now)
        let image = PendingAsset.make(data: Data("PNG-bytes-\(title)".utf8), mediaType: .png, originalFileName: "photo.png", now: now)
        snap.assets[ink.asset.id] = ink.asset
        snap.assets[image.asset.id] = image.asset
        let p0 = snap.document.pageIDs[0]
        snap.pages[p0]!.inkLayers = [InkLayer(engine: .reference, dataAssetID: ink.asset.id)]
        snap.pages[p0]!.objects = [
            CanvasObject(frame: PageRect(x: 10, y: 20, width: 200, height: 40), content: .text(TextContent(text: "Newton's second law")), createdAt: now),
        ]
        if pageCount > 1 {
            let p1 = snap.document.pageIDs[1]
            let tape = CanvasObject(frame: PageRect(x: 0, y: 0, width: 50, height: 20), content: .tape(TapeContent()), createdAt: now)
            snap.pages[p1]!.objects = [
                CanvasObject(frame: PageRect(x: 50, y: 60, width: 120, height: 90), content: .image(ImageContent(assetID: image.asset.id)), createdAt: now),
                tape,
            ]
            snap.pages[p1]!.problem = ProblemMetadata(title: "HW2 #3", status: .checkAgain)
            snap.document.reviewItems = [ReviewItem(pageID: p1, region: PageRect(x: 0, y: 0, width: 5, height: 5), prompt: "why?", answerTapeID: tape.id, createdAt: now)]
        }
        return (snap, [ink, image])
    }

    /// Content-only view of a snapshot: revision identifiers are assigned by
    /// the store on every commit, so they are neutralized before comparing.
    static func normalized(_ snapshot: DocumentSnapshot) -> DocumentSnapshot {
        let fixed = RevisionID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000000")!)
        var s = snapshot
        s.document.revisionHead = fixed
        s.document.schemaVersion = DocumentSchema.current
        for id in s.pages.keys { s.pages[id]!.revisionID = fixed }
        s.document.deletedPages = s.document.deletedPages.map { var d = $0; d.page.revisionID = fixed; return d }
        s.revisions = [:]
        return s
    }

    static func editPage(_ snapshot: inout DocumentSnapshot, index: Int, text: String) -> ChangeSet {
        let id = snapshot.document.pageIDs[index]
        snapshot.pages[id]!.objects.append(CanvasObject(frame: PageRect(x: 5, y: 5, width: 100, height: 20), content: .text(TextContent(text: text)), createdAt: now))
        snapshot.pages[id]!.modifiedAt = now.addingTimeInterval(1)
        return ChangeSet(changedPageIDs: [id])
    }

    static func files(in directory: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).sorted()
    }
}

extension XCTestCase {
    func tempDirectory(_ name: String = "PersistenceTests") throws -> URL {
        let url = try Support.makeTempDirectory(name)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// Polls (real time) until `condition` is true; fails the test on timeout.
    func waitUntil(_ what: String, timeout: TimeInterval = 5, file: StaticString = #filePath, line: UInt = #line, _ condition: () async -> Bool) async {
        let start = Date()
        while !(await condition()) {
            if Date().timeIntervalSince(start) > timeout { XCTFail("timed out waiting for \(what)", file: file, line: line); return }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
    }
}
