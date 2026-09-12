import Foundation
import SwiftUI
import UIKit
import DocumentCore
import PageGeometry
import Editing
import Workspace

// The picture of the work a review item is about.
//
// Review used to show the item's metadata and a "Reveal the Answer" button that
// changed the tape on a page the student could not see, which meant revealing
// an answer showed nothing at all. The queue now renders the page — cropped to
// the item's region when it has one — and re-renders after a reveal, so the
// answer is actually visible where it was asked for.

/// What a review item's source page turned out to be.
enum ReviewPreviewState {
    case loading
    case ready(UIImage)
    /// The page or the notebook is gone, or could not be read. Never a blank box.
    case unavailable(String)
}

@MainActor
enum ReviewPagePreviewRenderer {

    /// Renders the page behind `entry`, cropped to the item's region with a
    /// little context around it. `width` is in points.
    static func render(entry: ReviewQueueEntry, env: AppEnvironment, width: CGFloat) async -> ReviewPreviewState {
        let session: any DocumentSessioning
        do {
            session = try await env.session(for: entry.documentID)
        } catch {
            return .unavailable("This notebook could not be opened, so there is nothing to show. \(AppErrorText.message(for: error))")
        }
        guard let page = session.editor.page(entry.item.pageID) else {
            return .unavailable("The page this item came from is no longer in the notebook. The item is still here so you can remove it.")
        }
        guard page.size.isValid else {
            return .unavailable("This page has no usable size, so it cannot be drawn.")
        }

        let loader = PageContentLoader(assets: SessionAssetProvider(session: session))
        let input = await PageContentResolver.resolve(page: page, loader: loader, wantsInk: true, wantsImages: true)
        let pageRect = CGRect(origin: .zero, size: CGSize(page.size))
        let crop = cropRect(for: entry.item.region, in: pageRect)
        let geometry = renderGeometry(pageRect: pageRect, crop: crop, targetWidth: width)

        let rendered = await Task.detached(priority: .userInitiated) { () -> UIImage? in
            let full = PageRenderer.renderPage(input, size: geometry.renderSize, scale: geometry.pixelScale)
            return cropped(full, to: geometry.cropInRendered)
        }.value

        guard let rendered else {
            return .unavailable("This page could not be drawn. Open it in the notebook to check it.")
        }
        return .ready(rendered)
    }

    /// The region plus breathing room, clamped to the page. A region with no
    /// context around it reads as a fragment rather than as work.
    static func cropRect(for region: PageRect?, in pageRect: CGRect) -> CGRect {
        guard let region else { return pageRect }
        let rect = CGRect(region).intersection(pageRect)
        guard !rect.isNull, rect.width > 1, rect.height > 1 else { return pageRect }
        let padded = rect.insetBy(dx: -(rect.width * 0.12 + 10), dy: -(rect.height * 0.25 + 10))
        let clamped = padded.intersection(pageRect)
        return clamped.isNull ? pageRect : clamped
    }

    struct Geometry {
        var renderSize: CGSize
        var pixelScale: CGFloat
        /// The crop, in the rendered image's point space.
        var cropInRendered: CGRect
    }

    /// Renders the whole page at whatever scale makes the crop `targetWidth`
    /// wide, with a cap so a small region on a large page cannot ask for a
    /// bitmap the size of a wall.
    static func renderGeometry(pageRect: CGRect, crop: CGRect, targetWidth: CGFloat) -> Geometry {
        let width = max(targetWidth, 80)
        var scale = width / max(crop.width, 1)
        let maxDimension: CGFloat = 3000
        let longest = max(pageRect.width, pageRect.height)
        if longest * scale > maxDimension { scale = maxDimension / max(longest, 1) }
        scale = max(scale, 0.05)
        let renderSize = CGSize(width: pageRect.width * scale, height: pageRect.height * scale)
        let cropInRendered = CGRect(x: crop.minX * scale, y: crop.minY * scale,
                                    width: crop.width * scale, height: crop.height * scale)
        return Geometry(renderSize: renderSize, pixelScale: 2, cropInRendered: cropInRendered)
    }

    nonisolated static func cropped(_ image: UIImage, to rect: CGRect) -> UIImage? {
        guard let cg = image.cgImage else { return image }
        let scale = image.scale
        let pixelRect = CGRect(x: rect.minX * scale, y: rect.minY * scale,
                               width: rect.width * scale, height: rect.height * scale).integral
        let bounds = CGRect(x: 0, y: 0, width: CGFloat(cg.width), height: CGFloat(cg.height))
        let clamped = pixelRect.intersection(bounds)
        guard !clamped.isNull, clamped.width >= 1, clamped.height >= 1,
              let piece = cg.cropping(to: clamped) else { return image }
        return UIImage(cgImage: piece, scale: scale, orientation: image.imageOrientation)
    }
}

/// The preview itself, with its own loading and unavailable states.
struct ReviewPagePreview: View {
    let entry: ReviewQueueEntry
    /// Changing this re-renders: the tape state lives in the document, so a
    /// reveal has to redraw the page to be visible.
    let revision: Int

    @Environment(AppEnvironment.self) private var env
    @State private var state: ReviewPreviewState = .loading

    var body: some View {
        Group {
            switch state {
            case .loading:
                ZStack {
                    RoundedRectangle(cornerRadius: 8).fill(Color(.secondarySystemBackground))
                    ProgressView()
                }
                .frame(height: 180)
                .accessibilityLabel("Loading the page")
            case .ready(let image):
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .frame(maxHeight: 340)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(.separator), lineWidth: 1))
                    .accessibilityLabel(entry.item.region == nil
                                        ? "Page \(entry.pageIndex + 1) of \(entry.documentTitle)"
                                        : "The part of page \(entry.pageIndex + 1) this item covers")
            case .unavailable(let message):
                Label {
                    Text(message).font(Typography.detail)
                } icon: {
                    Image(systemName: "exclamationmark.triangle")
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .task(id: revision) { await reload() }
    }

    private func reload() async {
        state = .loading
        state = await ReviewPagePreviewRenderer.render(entry: entry, env: env, width: 900)
    }
}
