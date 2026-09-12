import XCTest
import UIKit
import DocumentCore
@testable import Courseleaf

// `PageLayout` is the pure geometry of the scroll view's content space and
// `PageViewPool` is the virtualization that keeps a 300-page notebook from
// allocating 300 canvases (docs/ARCHITECTURE.md §8, acceptance A06).
@MainActor
final class EditorLayoutTests: XCTestCase {

    private let fixedDate = Date(timeIntervalSince1970: 1_757_600_000)
    private let letter = PageSize(width: 612, height: 792)

    private func page(_ size: PageSize) -> Page {
        Page(size: size, background: .template(.blank), revisionID: RevisionID(), createdAt: fixedDate, modifiedAt: fixedDate)
    }

    // MARK: Vertical continuous layout

    func testVerticalLayoutStacksPagesWithGapsAndPadding() {
        let layout = PageLayout(mode: .verticalContinuous, pageSizes: [letter, letter, letter])
        XCTAssertEqual(layout.pageCount, 3)
        // Content width is the widest page plus the padding on both sides.
        XCTAssertEqual(layout.contentSize.width, 612 + 2 * PageLayout.defaultPadding)
        // 3 pages, 2 gaps, padding above the first and below the last.
        XCTAssertEqual(layout.contentSize.height, 3 * 792 + 2 * PageLayout.defaultGap + 2 * PageLayout.defaultPadding)

        XCTAssertEqual(layout.frames[0].minX, 16)
        XCTAssertEqual(layout.frames[0].minY, 16)
        XCTAssertEqual(layout.frames[1].minY, 16 + 792 + 24)
        XCTAssertEqual(layout.frames[2].minY, 16 + 2 * (792 + 24))
        XCTAssertEqual(layout.frames[2].height, 792)
    }

    func testNarrowPagesAreCentredOnTheWidestPage() {
        let narrow = PageSize(width: 400, height: 600)
        let layout = PageLayout(mode: .verticalContinuous, pageSizes: [letter, narrow])
        XCTAssertEqual(layout.contentSize.width, 644)
        XCTAssertEqual(layout.frames[1].minX, (644 - 400) / 2)
    }

    func testPageIndexAtPointFallsBackToTheNearestPage() {
        let layout = PageLayout(mode: .verticalContinuous, pageSizes: [letter, letter, letter])
        XCTAssertEqual(layout.pageIndex(at: PagePoint(x: 300, y: 100)), 0)
        XCTAssertEqual(layout.pageIndex(at: PagePoint(x: 300, y: 900)), 1)   // inside page 2
        // A point in the gap resolves to the page whose centre is closest.
        XCTAssertEqual(layout.pageIndex(at: PagePoint(x: 300, y: 825)), 1)
        XCTAssertNil(PageLayout(mode: .verticalContinuous, pageSizes: []).pageIndex(at: .zero))
    }

    func testIndicesIntersectingAndFocusIndex() {
        let layout = PageLayout(mode: .verticalContinuous, pageSizes: [letter, letter, letter])
        let viewport = PageRect(x: 0, y: 0, width: 644, height: 900)
        XCTAssertEqual(layout.indices(intersecting: viewport), [0, 1])
        // Page 1 covers far more of the viewport than page 2 does.
        XCTAssertEqual(layout.focusIndex(forVisibleRect: viewport), 0)
        XCTAssertEqual(layout.focusIndex(forVisibleRect: PageRect(x: 0, y: 900, width: 644, height: 900)), 1)
        XCTAssertNil(PageLayout(mode: .verticalContinuous, pageSizes: []).focusIndex(forVisibleRect: viewport))
    }

    func testContentOffsetShowingPagePutsItAtTheTopOfTheViewport() {
        let layout = PageLayout(mode: .verticalContinuous, pageSizes: [letter, letter, letter])
        let offset = layout.contentOffset(showingPage: 1, zoomScale: 1, viewportSize: PageSize(width: 700, height: 1000))
        // Half a gap of breathing room above the page.
        XCTAssertEqual(offset.y, 832 - 12, accuracy: 0.0001)
        XCTAssertEqual(offset.x, 0, accuracy: 0.0001)

        // Zoomed in, the offset scales with the zoom and stays inside the content.
        let zoomed = layout.contentOffset(showingPage: 2, zoomScale: 2, viewportSize: PageSize(width: 700, height: 1000))
        XCTAssertEqual(zoomed.y, (16 + 2 * 816 - 12) * 2, accuracy: 0.0001)
        let clamped = layout.contentOffset(showingPage: 2, zoomScale: 0.25, viewportSize: PageSize(width: 4000, height: 4000))
        XCTAssertEqual(clamped.x, 0, accuracy: 0.0001)
        XCTAssertEqual(clamped.y, 0, accuracy: 0.0001)
        XCTAssertEqual(layout.contentOffset(showingPage: 99, zoomScale: 1, viewportSize: PageSize(width: 700, height: 1000)), .zero)
    }

    func testFitToWidthZoomFillsTheViewport() {
        let layout = PageLayout(mode: .verticalContinuous, pageSizes: [letter])
        XCTAssertEqual(layout.fitToWidthZoom(viewportWidth: 1288), 2, accuracy: 0.0001)
        XCTAssertEqual(layout.fitToWidthZoom(viewportWidth: 0), 1, accuracy: 0.0001)
    }

    // MARK: Horizontal paged layout

    func testHorizontalPagedLayoutGivesEachPageOneSlot() {
        let slot = PageSize(width: 800, height: 1000)
        let layout = PageLayout(mode: .horizontalPaged(slotSize: slot), pageSizes: [letter, letter, letter])
        XCTAssertEqual(layout.contentSize.width, 2400)
        XCTAssertEqual(layout.contentSize.height, 1000)
        XCTAssertEqual(layout.frames[0].minX, (800 - 612) / 2)
        XCTAssertEqual(layout.frames[1].minX, 800 + (800 - 612) / 2)
        XCTAssertEqual(layout.frames[0].minY, (1000 - 792) / 2)

        XCTAssertEqual(layout.focusIndex(forVisibleRect: PageRect(x: 800, y: 0, width: 800, height: 1000)), 1)
        let offset = layout.contentOffset(showingPage: 2, zoomScale: 1, viewportSize: slot)
        XCTAssertEqual(offset.x, 1600, accuracy: 0.0001)
        XCTAssertEqual(offset.y, 0, accuracy: 0.0001)
    }

    // MARK: Virtualization

    func testLiveIndicesStayWithinTheLimitAndFollowTheFocusPage() {
        XCTAssertEqual(PageViewPool.liveIndices(focus: 0, pageCount: 300, limit: 3), [0, 1])
        XCTAssertEqual(PageViewPool.liveIndices(focus: 10, pageCount: 300, limit: 3), [10, 11, 9])
        XCTAssertEqual(PageViewPool.liveIndices(focus: 299, pageCount: 300, limit: 3), [299, 298])
        XCTAssertEqual(PageViewPool.liveIndices(focus: 10, pageCount: 300, limit: 1), [10])
        XCTAssertEqual(PageViewPool.liveIndices(focus: nil, pageCount: 300, limit: 3), [])
        XCTAssertEqual(PageViewPool.liveIndices(focus: 0, pageCount: 0, limit: 3), [])
    }

    func testPoolNeverExceedsItsLiveLimitScrollingThroughThreeHundredPages() {
        let pages = (0..<300).map { _ in page(letter) }
        var pagesByID: [PageID: Page] = [:]
        for page in pages { pagesByID[page.id] = page }
        let ids = pages.map(\.id)
        let layout = PageLayout(mode: .verticalContinuous, pageSizes: pages.map(\.size))

        let pool = PageViewPool(
            liveLimit: 3,
            makeCanvas: { id in PageCanvasView(page: pagesByID[id]!, host: nil, loader: nil) },
            makePlaceholder: { PagePlaceholderView(pageID: $0) })

        var maximumLive = 0
        var maximumPlaceholders = 0
        var y = 0.0
        let viewport = PageSize(width: 800, height: 1000)
        while y < layout.contentSize.height {
            let visible = PageRect(x: 0, y: y, width: viewport.width, height: viewport.height)
            pool.update(pageIDs: ids,
                        visibleIndices: layout.indices(intersecting: visible),
                        focusIndex: layout.focusIndex(forVisibleRect: visible))
            XCTAssertLessThanOrEqual(pool.liveCanvasCount, 3, "more than three live canvases at y = \(y)")
            maximumLive = max(maximumLive, pool.liveCanvasCount)
            maximumPlaceholders = max(maximumPlaceholders, pool.placeholders.count)
            y += 816   // one page plus the gap
        }

        XCTAssertEqual(maximumLive, 3, "the pool should keep the focus page and its neighbours live")
        XCTAssertLessThanOrEqual(maximumPlaceholders, 8, "placeholders are bounded by the visible pages")
        XCTAssertLessThan(pool.liveCanvasCount, 300)

        let cleared = pool.removeAll()
        XCTAssertEqual(pool.liveCanvasCount, 0)
        XCTAssertEqual(pool.placeholders.count, 0)
        XCTAssertFalse(cleared.evictedCanvases.isEmpty)
    }

    func testPoolReusesLiveCanvasesWhileTheFocusPageStays() {
        let pages = (0..<10).map { _ in page(letter) }
        var pagesByID: [PageID: Page] = [:]
        for page in pages { pagesByID[page.id] = page }
        let ids = pages.map(\.id)
        let pool = PageViewPool(
            liveLimit: 3,
            makeCanvas: { id in PageCanvasView(page: pagesByID[id]!, host: nil, loader: nil) },
            makePlaceholder: { PagePlaceholderView(pageID: $0) })

        pool.update(pageIDs: ids, visibleIndices: [3, 4], focusIndex: 3)
        let created = pool.canvasesCreated
        let canvas = pool.canvas(for: ids[3])
        XCTAssertNotNil(canvas)

        let second = pool.update(pageIDs: ids, visibleIndices: [3, 4], focusIndex: 3)
        XCTAssertEqual(pool.canvasesCreated, created, "an unchanged focus must not rebuild canvases")
        XCTAssertTrue(second.addedCanvases.isEmpty)
        XCTAssertTrue(second.evictedCanvases.isEmpty)
        XCTAssertTrue(pool.canvas(for: ids[3]) === canvas)

        // Jumping far away evicts everything that is no longer live.
        let third = pool.update(pageIDs: ids, visibleIndices: [9], focusIndex: 9)
        XCTAssertFalse(third.evictedCanvases.isEmpty)
        XCTAssertNil(pool.canvas(for: ids[3]))
        XCTAssertLessThanOrEqual(pool.liveCanvasCount, 3)
    }

    // MARK: Zoom limits

    func testEditorZoomClampsToTheContract() {
        XCTAssertEqual(EditorZoom.minimum, 0.5)
        XCTAssertEqual(EditorZoom.maximum, 8)
        XCTAssertEqual(EditorZoom.clamped(0.1), 0.5)
        XCTAssertEqual(EditorZoom.clamped(40), 8)
        XCTAssertEqual(EditorZoom.clamped(1.5), 1.5)
    }
}
