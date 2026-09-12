import SwiftUI
import UIKit
import AVFoundation
import VisionKit

/// Why the scanner could not be shown. The app keeps working without it (A16).
enum ScannerUnavailableReason: Hashable, Sendable {
    /// Camera permission was denied or is restricted by a profile; offer Settings.
    case cameraAccessDenied
    /// No document camera on this device (or the simulator).
    case notSupported
}

/// SwiftUI wrapper of `VNDocumentCameraViewController` with a graceful
/// camera-permission path: authorization is checked (and requested when not
/// yet determined) *before* the system scanner is shown. When access is denied
/// or restricted, `onDenied` fires and a small placeholder with an "Open
/// Settings" button is shown instead of a blank camera; the caller normally
/// dismisses the sheet in `onDenied`. Scanned pages arrive as upright UIImages.
struct DocumentScannerView: UIViewControllerRepresentable {
    var onScanned: ([UIImage]) -> Void
    var onDenied: () -> Void
    var onCancel: () -> Void = {}
    var onError: (Error) -> Void = { _ in }
    /// Called when the scanner is missing for a reason other than permission; defaults to `onDenied`.
    var onUnavailable: ((ScannerUnavailableReason) -> Void)? = nil

    init(onScanned: @escaping ([UIImage]) -> Void, onDenied: @escaping () -> Void,
         onCancel: @escaping () -> Void = {}, onError: @escaping (Error) -> Void = { _ in },
         onUnavailable: ((ScannerUnavailableReason) -> Void)? = nil) {
        self.onScanned = onScanned; self.onDenied = onDenied; self.onCancel = onCancel
        self.onError = onError; self.onUnavailable = onUnavailable
    }

    func makeCoordinator() -> Coordinator { Coordinator(view: self) }

    func makeUIViewController(context: Context) -> ScannerHostController {
        let host = ScannerHostController()
        host.coordinator = context.coordinator
        return host
    }

    func updateUIViewController(_ controller: ScannerHostController, context: Context) {
        context.coordinator.view = self
    }

    static func cameraAuthorization() -> AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .video)
    }

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        var view: DocumentScannerView
        init(view: DocumentScannerView) { self.view = view }

        func unavailable(_ reason: ScannerUnavailableReason) {
            if let handler = view.onUnavailable { handler(reason) } else { view.onDenied() }
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
            var images: [UIImage] = []
            images.reserveCapacity(scan.pageCount)
            for index in 0..<scan.pageCount { images.append(scan.imageOfPage(at: index)) }
            view.onScanned(images)
        }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
            view.onCancel()
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) {
            view.onError(error)
        }
    }

    /// Container that decides between the system scanner and the denied placeholder.
    final class ScannerHostController: UIViewController {
        weak var coordinator: Coordinator?
        private var didDecide = false

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .systemBackground
        }

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            guard !didDecide else { return }
            didDecide = true
            decide()
        }

        private func decide() {
            guard VNDocumentCameraViewController.isSupported else {
                showPlaceholder(.notSupported); coordinator?.unavailable(.notSupported); return
            }
            switch DocumentScannerView.cameraAuthorization() {
            case .authorized:
                embedScanner()
            case .notDetermined:
                AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                    DispatchQueue.main.async {
                        guard let self else { return }
                        if granted { self.embedScanner() } else { self.denied() }
                    }
                }
            case .denied, .restricted:
                denied()
            @unknown default:
                denied()
            }
        }

        private func denied() {
            showPlaceholder(.cameraAccessDenied)
            coordinator?.view.onDenied()
        }

        private func embedScanner() {
            let scanner = VNDocumentCameraViewController()
            scanner.delegate = coordinator
            addChild(scanner)
            scanner.view.frame = view.bounds
            scanner.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            view.addSubview(scanner.view)
            scanner.didMove(toParent: self)
        }

        private func showPlaceholder(_ reason: ScannerUnavailableReason) {
            let title: String
            let message: String
            switch reason {
            case .cameraAccessDenied:
                title = "Camera access is off"
                message = "Courseleaf needs the camera to scan pages. You can allow it in Settings; typing, drawing and importing files keep working without it."
            case .notSupported:
                title = "Scanning is not available"
                message = "This device has no document camera. Import a PDF or an image from Files instead."
            }
            var configuration = UIContentUnavailableConfiguration.empty()
            configuration.image = UIImage(systemName: "camera.fill")
            configuration.text = title
            configuration.secondaryText = message
            if reason == .cameraAccessDenied, let settings = URL(string: UIApplication.openSettingsURLString) {
                var button = UIButton.Configuration.filled()
                button.title = "Open Settings"
                configuration.button = button
                configuration.buttonProperties.primaryAction = UIAction { _ in UIApplication.shared.open(settings) }
            }
            contentUnavailableConfiguration = configuration
        }
    }
}
