import Foundation
import UIKit
import DocumentCore

/// Image objects, drawn beneath the ink layer (compositing band 2).
final class ImageObjectLayerView: UIView {
    private(set) var views: [ObjectID: ImageObjectView] = [:]
    private var loadTasks: [ObjectID: Task<Void, Never>] = [:]
    weak var loader: PageContentLoader?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        // Images are selected through the overlay (lasso/tap); the layer itself never takes touches.
        isUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func update(objects: [CanvasObject]) {
        let images = objects.filter { $0.kind == .image }
        let ids = Set(images.map(\.id))
        for (id, view) in views where !ids.contains(id) {
            view.removeFromSuperview()
            views[id] = nil
            loadTasks[id]?.cancel()
            loadTasks[id] = nil
        }
        for object in images {
            if let view = views[object.id] {
                let previousAsset = view.object.content.assetID
                view.apply(object)
                if previousAsset != object.content.assetID { load(object, into: view) }
            } else {
                let view = ImageObjectView(object: object)
                views[object.id] = view
                addSubview(view)
                load(object, into: view)
            }
        }
        // Keep page order as z-order.
        for object in images { if let v = views[object.id] { bringSubviewToFront(v) } }
    }

    private func load(_ object: CanvasObject, into view: ImageObjectView) {
        guard case .image(let content) = object.content, let loader else { return }
        loadTasks[object.id]?.cancel()
        loadTasks[object.id] = Task { [weak view] in
            let image = await loader.image(for: content.assetID)
            guard !Task.isCancelled else { return }
            view?.setSourceImage(image)
        }
    }

    func view(for id: ObjectID) -> ImageObjectView? { views[id] }

    func preview(ids: Set<ObjectID>, transform: PageTransform?) {
        for (id, view) in views where ids.contains(id) { view.preview(transformedBy: transform) }
    }

    func clearPreviews() { for view in views.values { view.preview(transformedBy: nil) } }

    func cancelLoads() {
        for task in loadTasks.values { task.cancel() }
        loadTasks.removeAll()
    }
}
