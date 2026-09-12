import Foundation
import UIKit
import AVFoundation
import PhotosUI
import UniformTypeIdentifiers
import DocumentCore
import Editing
import Workspace

// Image insertion (Photos, camera, Files) and the crop sheet. Permission
// denials leave the editor usable and explain how to enable access (A16).

@MainActor
protocol ImageInsertionControllerHost: AnyObject {
    var session: any DocumentSessioning { get }
    var presentingViewController: UIViewController { get }
    var currentPageID: PageID? { get }
    /// The visible page-space rect of the current page, to centre new images on what the student sees.
    var visiblePageRect: PageRect? { get }
    func registerImageAsset(data: Data, mediaType: AssetMediaType) -> AssetID
    func performDocumentOperation(_ name: String, _ body: () throws -> Void)
    func didInsertObject(_ id: ObjectID, on pageID: PageID)
}

@MainActor
final class ImageInsertionController: NSObject, PHPickerViewControllerDelegate, UIImagePickerControllerDelegate,
                                      UINavigationControllerDelegate, UIDocumentPickerDelegate {
    weak var host: ImageInsertionControllerHost?
    private let now: () -> Date

    init(now: @escaping () -> Date = Date.init) {
        self.now = now
        super.init()
    }

    // MARK: Sources

    func presentPhotoPicker() {
        guard let host else { return }
        var configuration = PHPickerConfiguration(photoLibrary: .shared())
        configuration.filter = .images
        configuration.selectionLimit = 1
        configuration.preferredAssetRepresentationMode = .current
        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = self
        host.presentingViewController.present(picker, animated: true)
    }

    func presentCamera() {
        guard let host else { return }
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
            presentAlert(title: "No Camera", message: "This iPad has no camera available. You can insert photos from your library instead.")
            return
        }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            showCamera()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                Task { @MainActor in
                    if granted { self?.showCamera() } else { self?.presentCameraDenied() }
                }
            }
        case .denied, .restricted:
            presentCameraDenied()
        @unknown default:
            presentCameraDenied()
        }
    }

    func presentFilePicker() {
        guard let host else { return }
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.png, .jpeg], asCopy: true)
        picker.delegate = self
        picker.allowsMultipleSelection = false
        host.presentingViewController.present(picker, animated: true)
    }

    private func showCamera() {
        guard let host else { return }
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.mediaTypes = [UTType.image.identifier]
        picker.delegate = self
        host.presentingViewController.present(picker, animated: true)
    }

    private func presentCameraDenied() {
        let alert = UIAlertController(title: "Camera Access Is Off",
                                      message: "Courseleaf cannot use the camera until you allow it in Settings. Writing, reading and exporting keep working without it.",
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Not Now", style: .cancel))
        alert.addAction(UIAlertAction(title: "Open Settings", style: .default) { _ in
            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
        })
        host?.presentingViewController.present(alert, animated: true)
    }

    private func presentAlert(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        host?.presentingViewController.present(alert, animated: true)
    }

    // MARK: PHPickerViewControllerDelegate

    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        guard let result = results.first else { return }
        let provider = result.itemProvider
        let preferredType = provider.hasItemConformingToTypeIdentifier(UTType.png.identifier) ? UTType.png : UTType.jpeg
        if provider.hasItemConformingToTypeIdentifier(preferredType.identifier) {
            provider.loadDataRepresentation(forTypeIdentifier: preferredType.identifier) { [weak self] data, _ in
                Task { @MainActor in
                    if let data, let stored = EditorAssets.storableImage(from: data, image: nil) {
                        self?.insert(imageData: stored.0, mediaType: stored.1, pixelSize: stored.2)
                    } else {
                        self?.loadAsUIImage(provider)
                    }
                }
            }
        } else {
            loadAsUIImage(provider)
        }
    }

    private func loadAsUIImage(_ provider: NSItemProvider) {
        guard provider.canLoadObject(ofClass: UIImage.self) else {
            presentAlert(title: "Unsupported Image", message: "That item could not be read as a PNG or JPEG image.")
            return
        }
        provider.loadObject(ofClass: UIImage.self) { [weak self] object, _ in
            Task { @MainActor in
                guard let image = object as? UIImage, let stored = EditorAssets.storableImage(from: nil, image: image) else {
                    self?.presentAlert(title: "Unsupported Image", message: "That item could not be read as an image.")
                    return
                }
                self?.insert(imageData: stored.0, mediaType: stored.1, pixelSize: stored.2)
            }
        }
    }

    // MARK: UIImagePickerControllerDelegate

    func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
        picker.dismiss(animated: true)
        guard let image = (info[.originalImage] as? UIImage), let stored = EditorAssets.storableImage(from: nil, image: image) else { return }
        insert(imageData: stored.0, mediaType: stored.1, pixelSize: stored.2)
    }

    func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
        picker.dismiss(animated: true)
    }

    // MARK: UIDocumentPickerDelegate

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { return }
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url), let stored = EditorAssets.storableImage(from: data, image: nil) else {
            presentAlert(title: "Unsupported Image", message: "Only PNG and JPEG images can be inserted.")
            return
        }
        insert(imageData: stored.0, mediaType: stored.1, pixelSize: stored.2)
    }

    // MARK: Insert

    func insert(imageData: Data, mediaType: AssetMediaType, pixelSize: CGSize) {
        guard let host, let pageID = host.currentPageID, let page = host.session.editor.page(pageID) else { return }
        let assetID = host.registerImageAsset(data: imageData, mediaType: mediaType)
        let visible = host.visiblePageRect ?? page.bounds
        let maxWidth = min(page.size.width, visible.width) * 0.7
        let maxHeight = min(page.size.height, visible.height) * 0.7
        let scale = min(1, maxWidth / max(Double(pixelSize.width), 1), maxHeight / max(Double(pixelSize.height), 1))
        let size = PageSize(width: Double(pixelSize.width) * scale, height: Double(pixelSize.height) * scale)
        let origin = PagePoint(x: max(0, visible.midX - size.width / 2), y: max(0, visible.midY - size.height / 2))
        let object = CanvasObject(frame: PageRect(origin: origin, size: size), content: .image(ImageContent(assetID: assetID)), createdAt: now())
        host.performDocumentOperation("Insert Image") {
            try host.session.apply(.addObject(pageID, object, at: nil))
        }
        host.didInsertObject(object.id, on: pageID)
    }

    // MARK: Crop

    func presentCrop(pageID: PageID, object: CanvasObject, loader: PageContentLoader) {
        guard let host, case .image(let content) = object.content else { return }
        Task { [weak self] in
            guard let self, let image = await loader.image(for: content.assetID) else { return }
            let controller = ImageCropViewController(image: image, crop: content.crop)
            controller.onDone = { [weak self] crop in
                guard let self, let host = self.host else { return }
                var updated = object
                var c = content
                let previousCrop = content.crop.standardized
                c.crop = crop
                updated.content = .image(c)
                // Keep the visible pixels the same size on the page: scale the frame by the crop ratio.
                let wRatio = crop.width / max(previousCrop.width, 1e-6)
                let hRatio = crop.height / max(previousCrop.height, 1e-6)
                updated.frame.size = PageSize(width: object.frame.width * wRatio, height: object.frame.height * hRatio)
                updated.frame.origin = PagePoint(x: object.frame.minX + (crop.minX - previousCrop.minX) / max(previousCrop.width, 1e-6) * object.frame.width,
                                                 y: object.frame.minY + (crop.minY - previousCrop.minY) / max(previousCrop.height, 1e-6) * object.frame.height)
                host.performDocumentOperation("Crop") {
                    try host.session.apply(.updateObject(pageID, updated))
                }
            }
            let navigation = UINavigationController(rootViewController: controller)
            navigation.modalPresentationStyle = .formSheet
            host.presentingViewController.present(navigation, animated: true)
        }
    }
}

/// A small crop editor: the image with a draggable crop rectangle (edges and
/// corners). The result is a unit rectangle of the source image.
final class ImageCropViewController: UIViewController {
    var onDone: ((PageRect) -> Void)?
    private let image: UIImage
    private var crop: PageRect
    private let imageView = UIImageView()
    private let cropOverlay = CropOverlayView()

    init(image: UIImage, crop: PageRect) {
        self.image = image
        self.crop = crop.standardized
        super.init(nibName: nil, bundle: nil)
        title = "Crop"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .cancel, primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) })
        navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak self] _ in
            guard let self else { return }
            self.onDone?(self.cropOverlay.crop)
            self.dismiss(animated: true)
        })
        let reset = UIBarButtonItem(title: "Reset", primaryAction: UIAction { [weak self] _ in self?.cropOverlay.crop = .unit })
        navigationItem.rightBarButtonItems = [navigationItem.rightBarButtonItem!, reset]
        imageView.image = image
        imageView.contentMode = .scaleAspectFit
        view.addSubview(imageView)
        view.addSubview(cropOverlay)
        cropOverlay.crop = crop
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let inset = view.bounds.inset(by: view.safeAreaInsets).insetBy(dx: 24, dy: 24)
        let fitted = PageRenderer.fitted(imageSize: image.size, in: inset)
        imageView.frame = fitted
        cropOverlay.frame = fitted
    }
}

/// Draggable crop rectangle in unit coordinates of its bounds.
final class CropOverlayView: UIView {
    var crop: PageRect = .unit { didSet { setNeedsDisplay() } }
    private var activeEdge: (left: Bool, right: Bool, top: Bool, bottom: Bool)?
    private var moving = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(pan(_:))))
        isAccessibilityElement = true
        accessibilityLabel = "Crop rectangle"
        accessibilityHint = "Drag the edges to crop"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private var cropRect: CGRect {
        CGRect(x: crop.minX * bounds.width, y: crop.minY * bounds.height, width: crop.width * bounds.width, height: crop.height * bounds.height)
    }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        ctx.setFillColor(UIColor.black.withAlphaComponent(0.45).cgColor)
        ctx.fill(bounds)
        ctx.clear(cropRect)
        ctx.setStrokeColor(UIColor.white.cgColor)
        ctx.setLineWidth(2)
        ctx.stroke(cropRect)
        for x in [cropRect.minX, cropRect.maxX] { for y in [cropRect.minY, cropRect.maxY] {
            ctx.setFillColor(UIColor.white.cgColor)
            ctx.fillEllipse(in: CGRect(x: x - 6, y: y - 6, width: 12, height: 12))
        } }
    }

    @objc private func pan(_ gesture: UIPanGestureRecognizer) {
        let point = gesture.location(in: self)
        let rect = cropRect
        let tolerance: CGFloat = 24
        switch gesture.state {
        case .began:
            let left = abs(point.x - rect.minX) < tolerance, right = abs(point.x - rect.maxX) < tolerance
            let top = abs(point.y - rect.minY) < tolerance, bottom = abs(point.y - rect.maxY) < tolerance
            if left || right || top || bottom { activeEdge = (left, right, top, bottom); moving = false }
            else { activeEdge = nil; moving = rect.contains(point) }
        case .changed:
            let translation = gesture.translation(in: self)
            gesture.setTranslation(.zero, in: self)
            let dx = translation.x / max(bounds.width, 1), dy = translation.y / max(bounds.height, 1)
            var c = crop
            if let edge = activeEdge {
                var minX = c.minX, maxX = c.maxX, minY = c.minY, maxY = c.maxY
                if edge.left { minX = min(max(0, minX + dx), maxX - 0.05) }
                if edge.right { maxX = max(min(1, maxX + dx), minX + 0.05) }
                if edge.top { minY = min(max(0, minY + dy), maxY - 0.05) }
                if edge.bottom { maxY = max(min(1, maxY + dy), minY + 0.05) }
                c = PageRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
            } else if moving {
                let nx = min(max(0, c.minX + dx), 1 - c.width), ny = min(max(0, c.minY + dy), 1 - c.height)
                c = PageRect(x: nx, y: ny, width: c.width, height: c.height)
            }
            crop = c
        default:
            activeEdge = nil; moving = false
        }
    }
}
