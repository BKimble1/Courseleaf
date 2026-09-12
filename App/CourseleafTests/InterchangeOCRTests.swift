import XCTest
import CoreGraphics
import CoreImage
import UIKit
import DocumentCore
@testable import Courseleaf

/// Recognition evidence for acceptance A15. This is an **evaluation**, not a
/// pass/fail gate on Vision's accuracy: the suite renders a small synthetic
/// corpus, runs the real recognizer over it, and records the character and word
/// error rate for each case in the test log so `docs/VALIDATION.md` can quote
/// measured numbers instead of claims.
///
/// Only one thing is asserted as a requirement: clean printed text at a normal
/// size must come back with a character error rate below 0.15. Everything else
/// is measured and reported. Handwriting is deliberately absent — synthetic
/// strokes are not handwriting, and a real evaluation needs a student-written
/// corpus on a physical iPad. That gate stays open in `docs/VALIDATION.md`.
final class InterchangeOCRTests: XCTestCase {

    /// One synthetic page of printed text rendered to a CGImage the size of the page.
    private func renderText(_ lines: [String], pageSize: PageSize = .letter, fontSize: CGFloat,
                            font: UIFont? = nil, blurRadius: CGFloat = 0, contrast: CGFloat = 1) throws -> CGImage {
        let size = CGSize(width: pageSize.width, height: pageSize.height)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 2
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            let resolved = font ?? UIFont.systemFont(ofSize: fontSize)
            let ink = UIColor(white: 1 - contrast, alpha: 1)
            var y: CGFloat = 72
            for line in lines {
                let attributes: [NSAttributedString.Key: Any] = [.font: resolved, .foregroundColor: ink]
                (line as NSString).draw(at: CGPoint(x: 72, y: y), withAttributes: attributes)
                y += resolved.lineHeight * 1.4
            }
        }
        guard var cg = image.cgImage else { throw XCTSkip("could not render the corpus page") }
        if blurRadius > 0 {
            let input = CIImage(cgImage: cg)
            guard let filter = CIFilter(name: "CIGaussianBlur") else { throw XCTSkip("CIGaussianBlur unavailable") }
            filter.setValue(input, forKey: kCIInputImageKey)
            filter.setValue(blurRadius, forKey: kCIInputRadiusKey)
            guard let output = filter.outputImage,
                  let blurred = CIContext().createCGImage(output, from: input.extent) else {
                throw XCTSkip("could not blur the corpus page")
            }
            cg = blurred
        }
        return cg
    }

    private func score(_ lines: [String], image: CGImage, pageSize: PageSize = .letter) async throws -> OCREvaluation.Score {
        let recognizer = VisionTextRecognizer(source: InMemoryContentSource(snapshot: emptySnapshot(), assets: [:]))
        let recognized = try await recognizer.recognizeLines(in: image, pageSize: pageSize)
        let hypothesis = OCREvaluation.transcript(lines: recognized.map { ($0.text, $0.bounds.minY, $0.bounds.minX) })
        return OCREvaluation.score(reference: lines.joined(separator: " "), hypothesis: hypothesis)
    }

    private func emptySnapshot() -> DocumentSnapshot {
        DocumentSnapshot.newNotebook(title: "OCR", now: InterchangeTestSupport.fixedDate)
    }

    // MARK: The corpus

    private static let paragraph = [
        "Chapter 3: Conservation of Energy",
        "A block of mass m slides down a frictionless incline of height h.",
        "Find the speed of the block at the bottom of the incline.",
        "Use the work energy theorem and ignore air resistance.",
    ]

    func testCleanPrintedTextIsRecognizedAccurately() async throws {
        let image = try renderText(Self.paragraph, fontSize: 16)
        let score = try await score(Self.paragraph, image: image)
        print("[A15] clean printed 16 pt system font: \(score)")
        XCTAssertLessThan(score.characterErrorRate, 0.15,
                          "clean printed text should be recognized well; measured \(score)")
    }

    /// Measured only. Smaller type, a serif face and a low-quality photo-like page
    /// are recorded so the limitation in `docs/PRODUCT_SPEC.md` rests on numbers.
    func testCorpusErrorRatesAreMeasuredAndReported() async throws {
        var rows: [(String, OCREvaluation.Score)] = []

        let small = try renderText(Self.paragraph, fontSize: 9)
        rows.append(("small 9 pt system", try await score(Self.paragraph, image: small)))

        let serif = try renderText(Self.paragraph, fontSize: 14,
                                   font: UIFont(name: "TimesNewRomanPSMT", size: 14) ?? UIFont.systemFont(ofSize: 14))
        rows.append(("serif 14 pt", try await score(Self.paragraph, image: serif)))

        let blurred = try renderText(Self.paragraph, fontSize: 16, blurRadius: 2.0)
        rows.append(("blurred (radius 2)", try await score(Self.paragraph, image: blurred)))

        let faint = try renderText(Self.paragraph, fontSize: 16, contrast: 0.35)
        rows.append(("low contrast (35%)", try await score(Self.paragraph, image: faint)))

        print("[A15] recognition corpus (Vision, en-US, accurate, 2x raster):")
        for (name, score) in rows { print("[A15]   \(name): \(score)") }

        // The pipeline must run and return something for every case; accuracy is
        // reported, not gated, because these are deliberately hard inputs.
        for (name, score) in rows {
            XCTAssertGreaterThan(score.referenceCharacters, 0, "\(name): empty reference")
            XCTAssertLessThanOrEqual(score.characterErrorRate, 1.0, "\(name): error rate out of range")
        }
    }

    func testRecognitionReturnsNothingForABlankPageRatherThanFailing() async throws {
        let blank = try renderText([], fontSize: 16)
        let recognizer = VisionTextRecognizer(source: InMemoryContentSource(snapshot: emptySnapshot(), assets: [:]))
        let lines = try await recognizer.recognizeLines(in: blank, pageSize: .letter)
        XCTAssertTrue(lines.isEmpty, "a blank page produced \(lines.count) phantom lines")
    }

    func testRecognizedLinesCarryPageSpaceBoundsInsideThePage() async throws {
        let image = try renderText(Self.paragraph, fontSize: 16)
        let recognizer = VisionTextRecognizer(source: InMemoryContentSource(snapshot: emptySnapshot(), assets: [:]))
        let lines = try await recognizer.recognizeLines(in: image, pageSize: .letter)
        XCTAssertFalse(lines.isEmpty, "nothing recognized, so bounds cannot be checked")
        let page = PageRect(origin: .zero, size: .letter)
        for line in lines {
            XCTAssertTrue(page.contains(line.bounds), "line '\(line.text)' has bounds outside the page: \(line.bounds)")
            XCTAssertGreaterThan(line.bounds.width, 0)
            XCTAssertGreaterThan(line.bounds.height, 0)
        }
        // Reading order: the title is above the body text in page space (y grows downwards).
        let sorted = lines.sorted { $0.bounds.minY < $1.bounds.minY }
        XCTAssertTrue(sorted.first?.text.contains("Chapter") ?? false,
                      "first line by page-space y was '\(sorted.first?.text ?? "")'")
    }

    // MARK: The scoring itself

    func testErrorRateMathIsCorrect() {
        let exact = OCREvaluation.score(reference: "the quick brown fox", hypothesis: "the quick brown fox")
        XCTAssertEqual(exact.characterErrorRate, 0, accuracy: 1e-12)
        XCTAssertEqual(exact.wordErrorRate, 0, accuracy: 1e-12)

        // One substituted word out of four.
        let oneWord = OCREvaluation.score(reference: "the quick brown fox", hypothesis: "the quick brown box")
        XCTAssertEqual(oneWord.wordErrorRate, 0.25, accuracy: 1e-12)
        XCTAssertEqual(oneWord.characterEdits, 1)

        // Normalization folds case and whitespace by default, but not in `.exact`.
        let folded = OCREvaluation.score(reference: "The  Quick", hypothesis: "the quick")
        XCTAssertEqual(folded.characterErrorRate, 0, accuracy: 1e-12)
        let strict = OCREvaluation.score(reference: "The  Quick", hypothesis: "the quick", normalization: .exact)
        XCTAssertGreaterThan(strict.characterErrorRate, 0)

        XCTAssertEqual(OCREvaluation.levenshtein(Array("kitten"), Array("sitting")), 3)
    }
}
