import Foundation
import UIKit
import DocumentCore

/// Keeps live `PageCanvasView`s only for the focused page and its immediate
/// neighbours (at most `liveLimit`, 3 by default) and placeholders for the
/// other visible pages (docs/ARCHITECTURE.md §8, acceptance A06). The pool
/// owns no layout; the caller positions the views it hands back.
@MainActor
final class PageViewPool {
    struct Update {
        var addedCanvases: [PageCanvasView] = []
        var evictedCanvases: [PageCanvasView] = []
        var addedPlaceholders: [PagePlaceholderView] = []
        var removedPlaceholders: [PagePlaceholderView] = []
    }

    let liveLimit: Int
    private let makeCanvas: (PageID) -> PageCanvasView
    private let makePlaceholder: (PageID) -> PagePlaceholderView
    private(set) var liveCanvases: [PageID: PageCanvasView] = [:]
    private(set) var placeholders: [PageID: PagePlaceholderView] = [:]
    /// Total canvases created over the pool's lifetime (diagnostics/tests).
    private(set) var canvasesCreated = 0

    init(liveLimit: Int = 3,
         makeCanvas: @escaping (PageID) -> PageCanvasView,
         makePlaceholder: @escaping (PageID) -> PagePlaceholderView) {
        precondition(liveLimit >= 1)
        self.liveLimit = liveLimit
        self.makeCanvas = makeCanvas
        self.makePlaceholder = makePlaceholder
    }

    var liveCanvasCount: Int { liveCanvases.count }

    func canvas(for id: PageID) -> PageCanvasView? { liveCanvases[id] }
    func placeholder(for id: PageID) -> PagePlaceholderView? { placeholders[id] }

    /// Page indices that should have a live canvas: the focus page and its
    /// neighbours, nearest first, never more than `limit`.
    static func liveIndices(focus: Int?, pageCount: Int, limit: Int) -> [Int] {
        guard let focus, pageCount > 0, limit >= 1 else { return [] }
        let f = min(max(focus, 0), pageCount - 1)
        let candidates = [f, f + 1, f - 1].filter { $0 >= 0 && $0 < pageCount }
        return Array(candidates.prefix(limit))
    }

    /// Reconciles the pool with the current page order, the visible page
    /// indices and the focus page. Returns what was created and evicted so the
    /// caller can attach, detach and retain (for undo) as needed.
    @discardableResult
    func update(pageIDs: [PageID], visibleIndices: [Int], focusIndex: Int?) -> Update {
        var update = Update()
        let liveIdx = Self.liveIndices(focus: focusIndex, pageCount: pageIDs.count, limit: liveLimit)
        let liveIDs = liveIdx.compactMap { pageIDs.indices.contains($0) ? pageIDs[$0] : nil }
        let liveSet = Set(liveIDs)
        let visibleIDs = Set(visibleIndices.compactMap { pageIDs.indices.contains($0) ? pageIDs[$0] : nil })

        // Evict canvases that are no longer in the live set (or whose page vanished).
        for (id, canvas) in liveCanvases where !liveSet.contains(id) {
            canvas.prepareForReuse()
            liveCanvases[id] = nil
            update.evictedCanvases.append(canvas)
        }
        // Create canvases for the live set, nearest first.
        for id in liveIDs where liveCanvases[id] == nil {
            guard liveCanvases.count < liveLimit else { break }
            let canvas = makeCanvas(id)
            canvasesCreated += 1
            liveCanvases[id] = canvas
            update.addedCanvases.append(canvas)
        }
        // Placeholders for visible pages that are not live.
        let wantPlaceholders = visibleIDs.subtracting(liveSet)
        for (id, view) in placeholders where !wantPlaceholders.contains(id) {
            placeholders[id] = nil
            update.removedPlaceholders.append(view)
        }
        for id in wantPlaceholders where placeholders[id] == nil {
            let view = makePlaceholder(id)
            placeholders[id] = view
            update.addedPlaceholders.append(view)
        }
        assert(liveCanvases.count <= liveLimit)
        return update
    }

    /// Drops everything (document closed or memory warning); returns the canvases that were live.
    func removeAll() -> Update {
        var update = Update()
        for (_, canvas) in liveCanvases { canvas.prepareForReuse(); update.evictedCanvases.append(canvas) }
        for (_, view) in placeholders { update.removedPlaceholders.append(view) }
        liveCanvases.removeAll()
        placeholders.removeAll()
        return update
    }
}
