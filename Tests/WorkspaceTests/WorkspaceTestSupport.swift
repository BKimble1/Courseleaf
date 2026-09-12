import Foundation
import XCTest
import DocumentCore
import Fixtures
import Persistence
@testable import Workspace

/// Shared helpers for the Workspace tests: temporary library roots, a service
/// wired to the fixture inspectors and a manual clock/sleeper (no real-time
/// save timers), fixture files written to disk, and identity-free comparison
/// of snapshots.
enum WS {
    static let epoch = Date(timeIntervalSince1970: 1_757_600_000)

    static func makeTempDirectory(_ name: String = "WorkspaceTests") throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Writes a generated fixture to `directory` and returns its URL.
    static func fixtureFile(_ name: String, in directory: URL) throws -> URL {
        guard let fixture = FixtureCatalog.fixture(named: name) else { throw FixtureError.unknownFixture(name) }
        let url = directory.appendingPathComponent(fixture.relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fixture.generate().write(to: url, options: .atomic)
        return url
    }

    /// The alignment sidecar shipped in `Fixtures/alignment.json` when the checkout has it, else the generated one.
    static func alignmentSidecar() throws -> AlignmentSidecar {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let shipped = repo.appendingPathComponent("Fixtures/alignment.json")
        let data: Data
        if let shippedData = try? Data(contentsOf: shipped) { data = shippedData } else { data = try FixtureCatalog.alignmentSidecarData() }
        return try DocumentJSON.decoder().decode(AlignmentSidecar.self, from: data)
    }

    static func files(in directory: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).sorted()
    }

    static func inkData(_ seed: String) -> Data {
        let drawing = ReferenceDrawing(strokes: [ReferenceStroke(points: [PagePoint(x: 1, y: 1), PagePoint(x: 20, y: 30), PagePoint(x: 40, y: 12)])])
        var data = try! ReferenceInkEngine().encode(drawing)
        data.append(contentsOf: Array(seed.utf8))
        return data
    }

    static func textObject(_ text: String, x: Double = 72, y: Double = 100) -> CanvasObject {
        CanvasObject(frame: PageRect(x: x, y: y, width: 200, height: 40), content: .text(TextContent(text: text)), createdAt: epoch)
    }

    /// Everything about a snapshot except identifiers and revision bookkeeping.
    struct Fingerprint: Equatable {
        struct PagePrint: Equatable {
            var size: PageSize
            var background: String
            var objects: [String]
            var inkAssets: [String?]
            var problem: ProblemMetadata?
            var isBookmarked: Bool
        }
        struct ReviewPrint: Equatable {
            var pageIndex: Int
            var region: PageRect?
            var prompt: String?
            var state: ReviewState
            var hasTape: Bool
            var history: [ReviewEvent.Action]
        }
        var title: String
        var kind: DocumentKind
        var pages: [PagePrint]
        var reviewItems: [ReviewPrint]
        var assetDigests: Set<String>
        var deletedPageCount: Int
    }

    static func fingerprint(_ s: DocumentSnapshot) -> Fingerprint {
        func digest(_ id: AssetID?) -> String? { id.flatMap { s.assets[$0]?.sha256 } }
        let pages = s.orderedPages.map { page -> Fingerprint.PagePrint in
            let background: String
            switch page.background {
            case .template(let t): background = "template:\(t.kind.rawValue)"
            case .pdf(let src): background = "pdf:\(digest(src.assetID) ?? "?"):\(src.pageIndex):\(src.rotation.rawValue):\(src.cropBox)"
            case .image(let id): background = "image:\(digest(id) ?? "?")"
            }
            let objects = page.objects.map { o -> String in
                switch o.content {
                case .text(let t): return "text:\(t.text):\(o.frame)"
                case .image(let i): return "image:\(digest(i.assetID) ?? "?"):\(o.frame)"
                case .shape(let sh): return "shape:\(sh.kind.rawValue):\(o.frame)"
                case .tape(let t): return "tape:\(t.isRevealed):\(t.label ?? ""):\(o.frame)"
                }
            }
            return .init(size: page.size, background: background, objects: objects,
                         inkAssets: page.inkLayers.map { digest($0.dataAssetID) }, problem: page.problem, isBookmarked: page.isBookmarked)
        }
        let items = s.document.reviewItems.map { item -> Fingerprint.ReviewPrint in
            .init(pageIndex: s.pageIndex(item.pageID) ?? -1, region: item.region, prompt: item.prompt, state: item.state,
                  hasTape: item.answerTapeID != nil, history: item.history.map(\.action))
        }
        return Fingerprint(title: s.document.title, kind: s.document.kind, pages: pages, reviewItems: items,
                           assetDigests: Set(s.assets.values.map(\.sha256)), deletedPageCount: s.document.deletedPages.count)
    }

    /// Neutralizes revision bookkeeping and open timestamps so two loads of the same document compare equal.
    static func normalized(_ snapshot: DocumentSnapshot) -> DocumentSnapshot {
        let fixed = RevisionID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000000")!)
        var s = snapshot
        s.document.revisionHead = fixed
        s.document.schemaVersion = DocumentSchema.current
        s.document.lastOpenedAt = nil
        for id in s.pages.keys { s.pages[id]!.revisionID = fixed }
        s.document.deletedPages = s.document.deletedPages.map { var d = $0; d.page.revisionID = fixed; return d }
        s.revisions = [:]
        return s
    }
}

/// A clock that moves forward by `tick` on every read, so commit latencies are non-zero and deterministic.
final class TickingClock: Clock, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    var tick: TimeInterval
    init(start: Date = WS.epoch, tick: TimeInterval = 0) { current = start; self.tick = tick }
    func now() -> Date {
        lock.lock(); defer { lock.unlock() }
        current = current.addingTimeInterval(tick)
        return current
    }
}

/// Collects values delivered from callbacks on any thread.
final class Log<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [T] = []
    func append(_ item: T) { lock.lock(); items.append(item); lock.unlock() }
    var all: [T] { lock.lock(); defer { lock.unlock() }; return items }
}

extension XCTestCase {
    func tempDirectory(_ name: String = "WorkspaceTests") throws -> URL {
        let url = try WS.makeTempDirectory(name)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// A service on a fresh library root: fixture inspectors, the given clock and a manual sleeper (saves only on flush).
    func makeService(root: URL, clock: any Clock = ManualClock(start: WS.epoch)) async throws -> LibraryService {
        let service = LibraryService(rootURL: root, pdfInspector: MinimalPDFInspector(), imageInspector: ImageHeaderInspector(), clock: clock)
        await service.configureSaving(sleeper: ManualSleeper())
        try await service.open()
        addTeardownBlock { await service.close() }
        return service
    }

    func waitUntil(_ what: String, timeout: TimeInterval = 5, file: StaticString = #filePath, line: UInt = #line, _ condition: () async -> Bool) async {
        let start = Date()
        while !(await condition()) {
            if Date().timeIntervalSince(start) > timeout { XCTFail("timed out waiting for \(what)", file: file, line: line); return }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    func XCTAssertThrowsWorkspaceError<T>(_ expression: @autoclosure () async throws -> T, _ check: (WorkspaceError) -> Bool = { _ in true },
                                          _ message: String = "", file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await expression()
            XCTFail("expected a WorkspaceError \(message)", file: file, line: line)
        } catch let error as WorkspaceError {
            XCTAssertTrue(check(error), "unexpected error \(error) \(message)", file: file, line: line)
        } catch {
            XCTFail("expected a WorkspaceError, got \(error) \(message)", file: file, line: line)
        }
    }
}
