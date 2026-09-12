import Foundation
import CoreGraphics
import UIKit
import Vision
import PDFKit
import DocumentCore
import PageGeometry
import Workspace

/// One recognized line, in page space.
struct RecognizedLine: Hashable, Sendable {
    var text: String
    var bounds: PageRect
    /// Vision confidence 0...1 of the top candidate.
    var confidence: Double
}

enum RecognitionError: Error, LocalizedError, Equatable {
    case renderFailed
    case vision(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .renderFailed: return "The page could not be rendered for recognition."
        case .vision(let message): return "Text recognition failed: \(message)"
        case .cancelled: return "Recognition was cancelled."
        }
    }
}

/// On-device text recognition with Vision (`VNRecognizeTextRequest`,
/// accurate level, English, language correction). Best effort: results carry
/// a confidence and never replace ink (docs/PRODUCT_SPEC.md §6).
///
/// Input image: the page is composited at `rasterScale` pixels per point
/// (default 2×) with `PageCompositor` — ink only (white paper, no rules) for
/// template pages, ink over the background for scans (image pages and PDF
/// pages without a text layer), ink only for PDF pages that already have real
/// text (that text is indexed by `PDFTextExtractor`). Vision's normalized
/// boxes (origin bottom-left) are mapped back to page space. The request runs
/// on a utility queue, never on the main actor, and is cancelled with the task.
/// Errors are reported to the caller; documents are never modified.
struct VisionTextRecognizer: Sendable {
    var recognitionLanguages: [String] = ["en-US"]
    var usesLanguageCorrection = true
    var rasterScale: CGFloat = 2
    /// Lines below this confidence are dropped.
    var minimumConfidence: Double = 0.2
    let source: any ExportContentSource

    init(session: any DocumentSessioning) { self.source = SessionContentSource(session: session) }
    init(source: any ExportContentSource) { self.source = source }

    // MARK: Page recognition

    func records(for pageID: PageID) async throws -> [SearchRecord] {
        let snapshot = await source.snapshot()
        guard let page = snapshot.pages[pageID] else { throw ExportError.pageNotFound(pageID) }
        let lines = try await recognize(page: page)
        return lines.map {
            SearchRecord(documentID: snapshot.document.id, pageID: page.id, revisionID: page.revisionID, kind: .recognized,
                         text: $0.text, bounds: $0.bounds, language: language, confidence: $0.confidence)
        }
    }

    func recognize(page: Page) async throws -> [RecognizedLine] {
        let loader = ExportPageLoader(source: source)
        let input = try await loader.input(for: page)
        var options = CompositeOptions(tape: .revealAll, inkRasterScale: Double(rasterScale), preserveSourceVectors: false)
        options.includeObjects = false
        options.includeImages = false
        options.suppressTemplateRules = true
        switch page.background {
        case .template:
            options.includeBackground = true // paper colour only (rules suppressed)
        case .image:
            options.includeBackground = true
        case .pdf(let sourcePage):
            var hasText = false
            if let document = try? await PDFTextExtractor(source: source).pdfDocument(sourcePage.assetID, pageID: page.id) {
                hasText = PDFTextExtractor.pageHasText(document, pageIndex: sourcePage.pageIndex)
            }
            options.includeBackground = !hasText
        }
        guard input.inkDrawings.contains(where: { !$0.strokes.isEmpty }) || (options.includeBackground && !isTemplate(page)) else {
            return [] // nothing to recognize: blank template page
        }
        try Task.checkCancellation()
        let scale = rasterScale
        let image = try await Task.detached(priority: .utility) { () throws -> CGImage in
            var raster = options
            raster.inkRasterScale = Double(scale)
            guard let cg = try ImageExporter.render(input, options: raster).cgImage else { throw RecognitionError.renderFailed }
            return cg
        }.value
        return try await recognizeLines(in: image, pageSize: page.size)
    }

    private func isTemplate(_ page: Page) -> Bool { if case .template = page.background { return true } else { return false } }

    /// The Vision pipeline on an image that covers exactly `pageSize` points.
    func recognizeLines(in image: CGImage, pageSize: PageSize) async throws -> [RecognizedLine] {
        try Task.checkCancellation()
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = recognitionLanguages
        request.usesLanguageCorrection = usesLanguageCorrection
        let minimum = minimumConfidence
        let box = RequestBox(request)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[RecognizedLine], Error>) in
                DispatchQueue.global(qos: .utility).async {
                    if Task.isCancelled { continuation.resume(throwing: RecognitionError.cancelled); return }
                    let handler = VNImageRequestHandler(cgImage: image, orientation: .up, options: [:])
                    do {
                        try handler.perform([box.request])
                    } catch {
                        continuation.resume(throwing: RecognitionError.vision(error.localizedDescription)); return
                    }
                    let observations = (box.request.results ?? [])
                    var lines: [RecognizedLine] = []
                    for observation in observations {
                        guard let candidate = observation.topCandidates(1).first else { continue }
                        let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !text.isEmpty, Double(candidate.confidence) >= minimum else { continue }
                        lines.append(RecognizedLine(text: text,
                                                    bounds: Self.pageRect(fromNormalized: observation.boundingBox, pageSize: pageSize),
                                                    confidence: Double(candidate.confidence)))
                    }
                    continuation.resume(returning: lines)
                }
            }
        } onCancel: {
            box.request.cancel()
        }
    }

    /// Vision boxes are normalized with the origin at the bottom-left of the image; page space is y down.
    static func pageRect(fromNormalized box: CGRect, pageSize: PageSize) -> PageRect {
        let b = box.standardized
        let x = Double(b.minX) * pageSize.width
        let y = (1 - Double(b.maxY)) * pageSize.height
        let rect = PageRect(x: x, y: y, width: Double(b.width) * pageSize.width, height: Double(b.height) * pageSize.height)
        return rect.intersection(PageRect(origin: .zero, size: pageSize)) ?? rect
    }

    var language: String { recognitionLanguages.first.map { String($0.prefix(2)) } ?? "en" }
}

/// Lets a Vision request cross the cancellation-handler boundary.
private final class RequestBox: @unchecked Sendable {
    let request: VNRecognizeTextRequest
    init(_ request: VNRecognizeTextRequest) { self.request = request }
}
