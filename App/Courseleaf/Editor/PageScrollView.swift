import Foundation
import UIKit
import DocumentCore

/// The zoomable, scrollable page area. `contentView` holds the page views in
/// unzoomed content space; the scroll view applies the zoom (0.5x–8x). Two
/// fingers always pan/zoom; one finger pans only when finger drawing is off
/// (so a finger can draw when the student enabled it).
final class PageScrollView: UIScrollView {
    let contentView = UIView()
    var layout: PageLayout? {
        didSet { applyContentSize() }
    }

    /// Space kept clear at the top for the writing controls. Held here rather
    /// than written straight into `contentInset` because `centerContentIfNeeded`
    /// owns that inset and would otherwise overwrite it on the next layout pass,
    /// putting the first page back underneath the toolbar.
    var chromeInsetTop: CGFloat = 0 {
        didSet {
            guard chromeInsetTop != oldValue else { return }
            centerContentIfNeeded()
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        addSubview(contentView)
        minimumZoomScale = CGFloat(EditorZoom.minimum)
        maximumZoomScale = CGFloat(EditorZoom.maximum)
        bouncesZoom = true
        alwaysBounceVertical = true
        alwaysBounceHorizontal = false
        contentInsetAdjustmentBehavior = .never
        showsVerticalScrollIndicator = true
        showsHorizontalScrollIndicator = true
        indicatorStyle = .default
        backgroundColor = .secondarySystemBackground
        keyboardDismissMode = .interactive
        isDirectionalLockEnabled = false
        decelerationRate = .normal
        pinchGestureRecognizer?.isEnabled = true
        panGestureRecognizer.minimumNumberOfTouches = 1
        panGestureRecognizer.maximumNumberOfTouches = 2
        accessibilityLabel = "Pages"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Finger drawing needs one-finger touches for the canvas; require two fingers to pan then.
    func setFingerDrawingEnabled(_ enabled: Bool) {
        panGestureRecognizer.minimumNumberOfTouches = enabled ? 2 : 1
    }

    func setLayoutMode(isHorizontalPaging: Bool) {
        isPagingEnabled = isHorizontalPaging
        alwaysBounceVertical = !isHorizontalPaging
        alwaysBounceHorizontal = isHorizontalPaging
    }

    private func applyContentSize() {
        guard let layout else { return }
        let size = CGSize(layout.contentSize)
        let zoom = zoomScale
        contentView.transform = .identity
        contentView.frame = CGRect(origin: .zero, size: size)
        contentView.transform = CGAffineTransform(scaleX: zoom, y: zoom)
        contentView.frame.origin = .zero
        contentSize = CGSize(width: size.width * zoom, height: size.height * zoom)
        centerContentIfNeeded()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        centerContentIfNeeded()
    }

    /// Keeps content centred when it is narrower/shorter than the viewport.
    func centerContentIfNeeded() {
        let available = max(0, bounds.height - chromeInsetTop)
        let inset = UIEdgeInsets(
            top: chromeInsetTop + max(0, (available - contentSize.height) / 2),
            left: max(0, (bounds.width - contentSize.width) / 2),
            bottom: 0, right: 0)
        if contentInset.left != inset.left || contentInset.top != inset.top {
            contentInset = UIEdgeInsets(top: inset.top, left: inset.left, bottom: contentInset.bottom, right: 0)
            verticalScrollIndicatorInsets.top = chromeInsetTop
        }
    }

    /// The visible rectangle in unzoomed content space.
    var visibleContentRect: CGRect {
        let z = max(zoomScale, 0.0001)
        return CGRect(x: contentOffset.x / z, y: contentOffset.y / z, width: bounds.width / z, height: bounds.height / z)
    }

    /// The part of the viewport the student can actually see the page in, in
    /// unzoomed content space: the visible rect minus the toolbar's band.
    var unobscuredContentRect: CGRect {
        let z = max(zoomScale, 0.0001)
        return CGRect(x: contentOffset.x / z,
                      y: (contentOffset.y + chromeInsetTop) / z,
                      width: bounds.width / z,
                      height: max(bounds.height - chromeInsetTop, 1) / z)
    }

    /// Zooms about the viewport centre (or a given content point) keeping it fixed.
    /// The parameter is named `scale` so it does not shadow `UIScrollView.zoom(to:animated:)`.
    func setZoom(_ scale: CGFloat, anchoredAt contentPoint: CGPoint? = nil, animated: Bool) {
        let target = min(max(scale, minimumZoomScale), maximumZoomScale)
        let anchor = contentPoint ?? CGPoint(x: visibleContentRect.midX, y: visibleContentRect.midY)
        let size = CGSize(width: bounds.width / target, height: bounds.height / target)
        let rect = CGRect(x: anchor.x - size.width / 2, y: anchor.y - size.height / 2, width: size.width, height: size.height)
        zoom(to: rect, animated: animated)
    }

    /// Scrolls so the given content-space rect is visible (top-left aligned when larger than the viewport).
    func scroll(toContentRect rect: CGRect, animated: Bool) {
        let z = zoomScale
        let zoomed = CGRect(x: rect.minX * z, y: rect.minY * z, width: rect.width * z, height: rect.height * z)
        var offset = CGPoint(x: zoomed.minX - max(0, (bounds.width - zoomed.width) / 2),
                             y: zoomed.minY - max(0, (bounds.height - zoomed.height) / 2))
        offset.x = max(-contentInset.left, min(offset.x, contentSize.width - bounds.width + contentInset.right))
        offset.y = max(-contentInset.top, min(offset.y, contentSize.height - bounds.height + contentInset.bottom))
        setContentOffset(offset, animated: animated)
    }
}
