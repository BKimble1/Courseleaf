import Foundation
import DocumentCore

/// Orientation of the graphics context an export draws into.
public enum ExportContextOrientation: Hashable, Sendable {
    /// Origin at the page's top-left corner, y down (UIKit image contexts, flipped CGContexts). Equal to page space at scale 1.
    case topLeftYDown
    /// Origin at the page's bottom-left corner, y up (an unflipped PDF/Quartz context whose media box is the page).
    case bottomLeftYUp
}

/// Transforms used when compositing a page into an export context whose
/// origin is the page origin (docs/ARCHITECTURE.md §4 — identical on screen
/// and in export). Every method returns a transform *from* the named space
/// *to* the export context.
public enum ExportGeometry {
    /// Page space → export context. `scale` is the raster scale (points → pixels), 1 for vector PDF output.
    public static func pageToContext(pageSize: PageSize, orientation: ExportContextOrientation = .topLeftYDown,
                                     scale: Double = 1) -> PageTransform {
        let s = PageTransform.scale(scale)
        switch orientation {
        case .topLeftYDown:
            return s
        case .bottomLeftYUp:
            // y' = (H - y) * scale
            return PageTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: pageSize.height).concatenating(s)
        }
    }

    /// Transform that positions the *source* PDF page's content (PDF user
    /// space) in the export context so it lands exactly under the page-space
    /// overlay: crop origin removed, `/Rotate` applied, then the context
    /// orientation. Concatenate it with the context CTM before drawing the
    /// source page with rotation disabled.
    public static func sourcePageTransform(_ mapping: PageMapping, orientation: ExportContextOrientation = .topLeftYDown,
                                           scale: Double = 1) -> PageTransform {
        mapping.pdfUserToPage.concatenating(pageToContext(pageSize: mapping.pageSize, orientation: orientation, scale: scale))
    }

    /// Unit-square object space → export context (reuses `CanvasObject.transform`).
    public static func objectTransform(_ object: CanvasObject, pageSize: PageSize,
                                       orientation: ExportContextOrientation = .topLeftYDown, scale: Double = 1) -> PageTransform {
        object.transform.concatenating(pageToContext(pageSize: pageSize, orientation: orientation, scale: scale))
    }

    /// Frame of an object in the export context (axis-aligned bounds including rotation).
    public static func objectBounds(_ object: CanvasObject, pageSize: PageSize,
                                    orientation: ExportContextOrientation = .topLeftYDown, scale: Double = 1) -> PageRect {
        object.bounds.applying(pageToContext(pageSize: pageSize, orientation: orientation, scale: scale))
    }

    /// Whether a tape object is drawn (as a covering rectangle) under the export policy.
    public static func shouldDrawTape(_ tape: TapeContent, policy: TapeExportPolicy) -> Bool {
        switch policy {
        case .asShown: return !tape.isRevealed
        case .coverAll: return true
        case .revealAll: return false
        }
    }

    /// Objects to draw *beneath* the ink layer (images), in page order.
    public static func objectsBelowInk(_ objects: [CanvasObject]) -> [CanvasObject] {
        objects.filter { $0.kind == .image }
    }

    /// Objects to draw *above* the ink layer, in page order with tape last so it
    /// covers what it is meant to cover; tape is filtered by `policy`.
    public static func objectsAboveInk(_ objects: [CanvasObject], tape policy: TapeExportPolicy) -> [CanvasObject] {
        let nonTape = objects.filter { $0.kind == .text || $0.kind == .shape }
        let tapes = objects.filter { obj in
            if case .tape(let t) = obj.content { return shouldDrawTape(t, policy: policy) }
            return false
        }
        return nonTape + tapes
    }
}
