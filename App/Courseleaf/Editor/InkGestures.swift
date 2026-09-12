import Foundation
import UIKit
import PencilKit
import DocumentCore
import Editing

// The UIKit half of the two pen gestures. The decisions live in the core
// package (`ScribbleEraseRecognizer`, `ShapeRecognizer`); everything here is
// touch observation, timing and drawing.
//
// PencilKit has no public API for reading a stroke while it is being drawn, and
// guessing at its private view hierarchy is not an option, so the in-progress
// path is observed the documented way: a gesture recogniser attached alongside
// the canvas that watches the same touches and never recognises, so it cannot
// delay, cancel or otherwise change what PencilKit does with them.

/// Records the touch path of the stroke in progress and reports a hold.
final class StrokeSamplingGestureRecognizer: UIGestureRecognizer {

    /// Movement under this many page points does not reset the hold timer.
    var holdRadius: Double = 7
    /// How long the pen has to rest before a shape is offered.
    var holdDuration: TimeInterval = 0.45

    private(set) var samples: [StrokeSample] = []
    private(set) var isHolding = false
    private var startTimestamp: TimeInterval = 0
    private var holdAnchor: PagePoint?
    private var holdTimer: Timer?
    private weak var trackedTouch: UITouch?

    /// Called on the main thread when the pen has rested long enough.
    var onHold: ((StrokeSamplingGestureRecognizer) -> Void)?
    /// Called for each new sample while a hold is already being shown.
    var onAdjust: ((StrokeSamplingGestureRecognizer) -> Void)?

    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
        requiresExclusiveTouchType = false
    }

    convenience init() { self.init(target: nil, action: nil) }

    var currentPoint: PagePoint? { samples.last?.location }
    var startPoint: PagePoint? { samples.first?.location }

    /// Samples taken before the hold began — the shape the student drew, as
    /// opposed to the adjustment they are making to it now.
    private(set) var samplesAtHold: [StrokeSample] = []

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)
        // One touch is followed from start to finish; a second finger landing
        // mid-stroke is not part of the gesture being observed.
        guard trackedTouch == nil, let touch = touches.first else { return }
        trackedTouch = touch
        startTimestamp = touch.timestamp
        samples = []
        samplesAtHold = []
        isHolding = false
        record(touch, event: event)
        holdAnchor = samples.last?.location
        restartHoldTimer()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesMoved(touches, with: event)
        guard let tracked = trackedTouch, touches.contains(tracked) else { return }
        record(tracked, event: event)
        guard let point = samples.last?.location else { return }
        if isHolding {
            onAdjust?(self)
            return
        }
        if let anchor = holdAnchor, anchor.distance(to: point) > holdRadius {
            holdAnchor = point
            restartHoldTimer()
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesEnded(touches, with: event)
        guard let tracked = trackedTouch, touches.contains(tracked) else { return }
        trackedTouch = nil
        finish()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesCancelled(touches, with: event)
        guard let tracked = trackedTouch, touches.contains(tracked) else { return }
        trackedTouch = nil
        samples = []
        samplesAtHold = []
        isHolding = false
        finish()
    }

    override func reset() {
        super.reset()
        cancelHoldTimer()
        trackedTouch = nil
    }

    /// Clears the recording; the caller has taken what it needs.
    func clear() {
        cancelHoldTimer()
        samples = []
        samplesAtHold = []
        isHolding = false
        holdAnchor = nil
    }

    private func finish() {
        cancelHoldTimer()
        // Never recognise: the touches belong to PencilKit.
        state = .failed
    }

    private func record(_ touch: UITouch, event: UIEvent?) {
        guard let view else { return }
        let coalesced = event?.coalescedTouches(for: touch) ?? [touch]
        for sample in coalesced {
            let location = PagePoint(sample.location(in: view))
            samples.append(StrokeSample(location: location, timeOffset: sample.timestamp - startTimestamp))
        }
        if samples.count > 4096 { samples.removeFirst(samples.count - 4096) }
    }

    private func restartHoldTimer() {
        cancelHoldTimer()
        let timer = Timer(timeInterval: holdDuration, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.state == .possible, !self.samples.isEmpty else { return }
                self.isHolding = true
                self.samplesAtHold = self.samples
                self.onHold?(self)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        holdTimer = timer
    }

    private func cancelHoldTimer() {
        holdTimer?.invalidate()
        holdTimer = nil
    }
}

// MARK: - Synthesising ink

/// Builds a `PKStroke` along a path, so a corrected shape is ordinary ink: it
/// erases, lassos, exports and prints exactly like handwriting, and adds no new
/// persisted type to the document format.
enum InkStrokeBuilder {

    static func stroke(along points: [PagePoint], ink: PKInk, width: CGFloat) -> PKStroke? {
        guard points.count >= 2 else { return nil }
        let size = CGSize(width: width, height: width)
        var controlPoints: [PKStrokePoint] = []
        controlPoints.reserveCapacity(points.count)
        // A steady, synthetic timeline: the shape was not drawn at these speeds
        // and pretending otherwise would give the stroke a misleading taper.
        let step = 1.0 / 240.0
        for (index, point) in points.enumerated() {
            controlPoints.append(PKStrokePoint(location: CGPoint(point),
                                               timeOffset: Double(index) * step,
                                               size: size,
                                               opacity: 1,
                                               force: 1,
                                               azimuth: 0,
                                               altitude: .pi / 2))
        }
        let path = PKStrokePath(controlPoints: controlPoints, creationDate: Date())
        return PKStroke(ink: ink, path: path, transform: .identity, mask: nil)
    }
}

// MARK: - Shape preview

/// The corrected shape shown over the page while the pen is still down.
final class ShapePreviewLayerView: UIView {
    private let shapeLayer = CAShapeLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        shapeLayer.fillColor = nil
        shapeLayer.lineJoin = .round
        shapeLayer.lineCap = .round
        layer.addSublayer(shapeLayer)
        isHidden = true
        isAccessibilityElement = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layoutSubviews() {
        super.layoutSubviews()
        shapeLayer.frame = bounds
    }

    func show(_ shape: RecognizedShape, color: UIColor, width: CGFloat, reduceMotion: Bool) {
        let path = UIBezierPath()
        let points = shape.polyline()
        guard let first = points.first else { return hide() }
        path.move(to: CGPoint(first))
        for point in points.dropFirst() { path.addLine(to: CGPoint(point)) }
        if shape.isClosed { path.close() }
        shapeLayer.path = path.cgPath
        shapeLayer.strokeColor = color.cgColor
        shapeLayer.lineWidth = width
        // The preview reads as "this is what you will get", so it is drawn in
        // the tool's own colour and width, not in a system tint.
        if isHidden {
            isHidden = false
            if !reduceMotion {
                shapeLayer.removeAnimation(forKey: "appear")
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = 0
                fade.toValue = 1
                fade.duration = 0.12
                shapeLayer.add(fade, forKey: "appear")
            }
        }
    }

    func hide() {
        isHidden = true
        shapeLayer.path = nil
    }
}
