import Foundation
import XCTest
import DocumentCore
@testable import Editing

/// Deterministic in-memory fixtures for the editing tests. No file I/O is
/// needed: the editor is a pure value transformer over `DocumentSnapshot`.
enum EditingFixture {
    static let start = Date(timeIntervalSince1970: 1_757_600_000)

    static func snapshot(pageCount: Int = 3) -> DocumentSnapshot {
        DocumentSnapshot.newNotebook(title: "Editing", pageCount: pageCount, now: start)
    }

    static func text(_ string: String = "text", frame: PageRect, rotation: Double = 0, locked: Bool = false) -> CanvasObject {
        CanvasObject(frame: frame, rotation: rotation, isLocked: locked, content: .text(TextContent(text: string)), createdAt: start)
    }
    static func image(_ assetID: AssetID, frame: PageRect, locked: Bool = false) -> CanvasObject {
        CanvasObject(frame: frame, isLocked: locked, content: .image(ImageContent(assetID: assetID)), createdAt: start)
    }
    static func shape(frame: PageRect, locked: Bool = false) -> CanvasObject {
        CanvasObject(frame: frame, isLocked: locked, content: .shape(ShapeContent(kind: .rectangle)), createdAt: start)
    }
    static func tape(frame: PageRect, revealed: Bool = false, locked: Bool = false) -> CanvasObject {
        CanvasObject(frame: frame, isLocked: locked, content: .tape(TapeContent(isRevealed: revealed)), createdAt: start)
    }

    static func inkAsset(_ seed: UInt8) -> PendingAsset {
        PendingAsset.make(data: Data([0x49, 0x4E, 0x4B, seed]), mediaType: .inkDrawing, now: start)
    }
    static func imageAsset(_ seed: UInt8) -> PendingAsset {
        PendingAsset.make(data: Data([0x89, 0x50, 0x4E, 0x47, seed]), mediaType: .png, now: start)
    }

    /// Everything about a page except its timestamps: what "content untouched" means.
    struct PageContent: Equatable {
        var id: PageID
        var size: PageSize
        var background: PageBackground
        var objects: [CanvasObject]
        var inkLayers: [InkLayer]
        var problem: ProblemMetadata?
        var isBookmarked: Bool
        init(_ page: Page) {
            id = page.id; size = page.size; background = page.background; objects = page.objects
            inkLayers = page.inkLayers; problem = page.problem; isBookmarked = page.isBookmarked
        }
    }
}

extension DocumentEditor {
    func firstInkLayerID(of pageID: PageID) -> InkLayerID { page(pageID)!.inkLayers[0].id }
}

func XCTAssertRectEqual(_ a: PageRect, _ b: PageRect, accuracy: Double = 1e-9, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(a.minX, b.minX, accuracy: accuracy, "minX", file: file, line: line)
    XCTAssertEqual(a.minY, b.minY, accuracy: accuracy, "minY", file: file, line: line)
    XCTAssertEqual(a.width, b.width, accuracy: accuracy, "width", file: file, line: line)
    XCTAssertEqual(a.height, b.height, accuracy: accuracy, "height", file: file, line: line)
}

func XCTAssertThrowsEditingError<T>(_ expression: @autoclosure () throws -> T, _ expected: EditingError,
                                    file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertThrowsError(try expression(), file: file, line: line) { error in
        XCTAssertEqual(error as? EditingError, expected, file: file, line: line)
    }
}
