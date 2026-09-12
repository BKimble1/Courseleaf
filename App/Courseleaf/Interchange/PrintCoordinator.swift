import Foundation
import UIKit

/// Where the print panel is anchored on iPad (it is presented as a popover).
enum PrintAnchor {
    case view(UIView, rect: CGRect?)
    case barButtonItem(UIBarButtonItem)
}

enum PrintError: Error, LocalizedError, Equatable {
    case printingUnavailable
    case notPrintable(URL)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .printingUnavailable: return "Printing is not available on this device."
        case .notPrintable(let url): return "\(url.lastPathComponent) cannot be printed."
        case .failed(let reason): return "Printing failed: \(reason)"
        }
    }
}

/// Presents the system print panel for a PDF produced by `PDFExporter`, so a
/// printout is the same presentation copy the student would export.
@MainActor
enum PrintCoordinator {
    /// Presents the print panel for the PDF at `url`. Returns true when the job
    /// was handed to the printer, false when the student cancelled.
    @discardableResult
    static func print(pdfAt url: URL, from anchor: PrintAnchor, jobName: String? = nil) async throws -> Bool {
        guard UIPrintInteractionController.isPrintingAvailable else { throw PrintError.printingUnavailable }
        guard UIPrintInteractionController.canPrint(url) else { throw PrintError.notPrintable(url) }
        let controller = UIPrintInteractionController.shared
        let info = UIPrintInfo(dictionary: nil)
        info.outputType = .general
        info.jobName = jobName ?? url.deletingPathExtension().lastPathComponent
        controller.printInfo = info
        controller.printingItem = url
        controller.showsNumberOfCopies = true

        return try await withCheckedThrowingContinuation { continuation in
            let completion: UIPrintInteractionController.CompletionHandler = { _, completed, error in
                if let error { continuation.resume(throwing: PrintError.failed(error.localizedDescription)) }
                else { continuation.resume(returning: completed) }
            }
            switch anchor {
            case .view(let view, let rect):
                controller.present(from: rect ?? view.bounds, in: view, animated: true, completionHandler: completion)
            case .barButtonItem(let item):
                controller.present(from: item, animated: true, completionHandler: completion)
            }
        }
    }
}
