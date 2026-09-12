import Foundation
import DocumentCore
import PageGeometry

// Pure layout of page frames inside the scroll view's unzoomed content space
// (one content point = one page point at zoom 1; the scroll view applies the
// zoom). No UIKit so the maths is unit-testable.

struct PageLayout: Equatable {
    enum Mode: Equatable {
        /// Pages stacked vertically, centred horizontally, `gap` points apart.
        case verticalContinuous
        /// One page per slot, slots side by side. `slotSize` is the viewport
        /// size divided by the base zoom, so a slot fills the viewport exactly.
        case horizontalPaged(slotSize: PageSize)
    }

    static let defaultGap: Double = 24
    static let defaultPadding: Double = 16

    let mode: Mode
    let pageSizes: [PageSize]
    let gap: Double
    let padding: Double
    /// Page frames in content space (unzoomed), one per page.
    let frames: [PageRect]
    let contentSize: PageSize

    init(mode: Mode, pageSizes: [PageSize], gap: Double = PageLayout.defaultGap, padding: Double = PageLayout.defaultPadding) {
        self.mode = mode
        self.pageSizes = pageSizes
        self.gap = gap
        self.padding = padding
        var frames: [PageRect] = []
        switch mode {
        case .verticalContinuous:
            let maxWidth = pageSizes.map(\.width).max() ?? 0
            let contentWidth = maxWidth + 2 * padding
            var y = padding
            for size in pageSizes {
                let x = (contentWidth - size.width) / 2
                frames.append(PageRect(x: x, y: y, width: size.width, height: size.height))
                y += size.height + gap
            }
            let height = pageSizes.isEmpty ? 2 * padding : y - gap + padding
            self.frames = frames
            self.contentSize = PageSize(width: contentWidth, height: height)
        case .horizontalPaged(let slot):
            for (i, size) in pageSizes.enumerated() {
                // Fit the page inside the slot (letterbox), keep aspect ratio 1:1 (no scaling of page points):
                // pages larger than the slot are centred and overflow the slot's visible area;
                // the scroll view's zoom (base zoom) is chosen so the largest page fits.
                let x = Double(i) * slot.width + (slot.width - size.width) / 2
                let y = max(0, (slot.height - size.height) / 2)
                frames.append(PageRect(x: x, y: y, width: size.width, height: size.height))
            }
            self.frames = frames
            let height = max(slot.height, (pageSizes.map(\.height).max() ?? 0))
            self.contentSize = PageSize(width: slot.width * Double(pageSizes.count), height: height)
        }
    }

    var pageCount: Int { pageSizes.count }

    /// The page whose frame contains the point, else the nearest page along the scroll axis.
    func pageIndex(at point: PagePoint) -> Int? {
        guard !frames.isEmpty else { return nil }
        if let hit = frames.firstIndex(where: { $0.contains(point) }) { return hit }
        var best = 0
        var bestDistance = Double.infinity
        for (i, f) in frames.enumerated() {
            let d: Double
            switch mode {
            case .verticalContinuous: d = abs(point.y - f.midY)
            case .horizontalPaged: d = abs(point.x - f.midX)
            }
            if d < bestDistance { bestDistance = d; best = i }
        }
        return best
    }

    /// Indices of pages whose frame (including the gap around it) intersects `rect`.
    func indices(intersecting rect: PageRect) -> [Int] {
        let rect = rect.standardized
        guard !frames.isEmpty else { return [] }
        return frames.indices.filter { frames[$0].insetBy(dx: -gap / 2, dy: -gap / 2).intersects(rect) }
    }

    /// The page to treat as "current" for a visible rect: the one covering the
    /// largest visible area; ties go to the page whose centre is closest to the
    /// visible centre. nil only when there are no pages.
    func focusIndex(forVisibleRect rect: PageRect) -> Int? {
        guard !frames.isEmpty else { return nil }
        let rect = rect.standardized
        let candidates = indices(intersecting: rect)
        guard !candidates.isEmpty else { return pageIndex(at: rect.center) }
        var best = candidates[0]
        var bestArea = -1.0
        var bestDistance = Double.infinity
        for i in candidates {
            let inter = frames[i].intersection(rect)
            let area = inter.map { $0.width * $0.height } ?? 0
            let distance = frames[i].center.distance(to: rect.center)
            if area > bestArea + 1e-9 || (abs(area - bestArea) <= 1e-9 && distance < bestDistance) {
                best = i; bestArea = area; bestDistance = distance
            }
        }
        return best
    }

    /// Mapping from page `index`'s page space to the scroll view's bounds
    /// coordinates for a zoom and content offset (see `PageGeometry.CanvasMapping`).
    func canvasMapping(forPage index: Int, zoomScale: Double, contentOffset: PagePoint) -> CanvasMapping {
        let origin = frames.indices.contains(index) ? frames[index].origin : .zero
        return CanvasMapping(zoomScale: zoomScale, contentOffset: contentOffset,
                             pageOrigin: PagePoint(x: origin.x * zoomScale, y: origin.y * zoomScale))
    }

    /// Content offset (zoomed) that puts page `index` at the top-left of a viewport, clamped to the content.
    func contentOffset(showingPage index: Int, zoomScale: Double, viewportSize: PageSize) -> PagePoint {
        guard frames.indices.contains(index) else { return .zero }
        let f = frames[index]
        let maxX = max(0, contentSize.width * zoomScale - viewportSize.width)
        let maxY = max(0, contentSize.height * zoomScale - viewportSize.height)
        switch mode {
        case .verticalContinuous:
            let y = (f.minY - gap / 2) * zoomScale
            let x = max(0, min(maxX, (f.midX * zoomScale) - viewportSize.width / 2))
            return PagePoint(x: x, y: max(0, min(maxY, y)))
        case .horizontalPaged(let slot):
            let x = Double(index) * slot.width * zoomScale
            return PagePoint(x: max(0, min(maxX, x)), y: 0)
        }
    }

    /// The zoom at which the widest page (plus padding) fills `viewportWidth`.
    func fitToWidthZoom(viewportWidth: Double) -> Double {
        guard contentSize.width > 0, viewportWidth > 0 else { return 1 }
        return viewportWidth / contentSize.width
    }
}

/// Zoom limits of the editor (contract: 0.5x–8x of page points).
enum EditorZoom {
    static let minimum: Double = 0.5
    static let maximum: Double = 8
    static let step: Double = 1.25
    static func clamped(_ z: Double) -> Double { min(max(z, minimum), maximum) }
}
