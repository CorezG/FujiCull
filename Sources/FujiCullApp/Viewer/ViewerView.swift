import AppKit
import FujiCullImaging
import SwiftUI

/// The photo surface: a layer-backed NSView that takes keys directly, which gives reliable key repeat
/// (ADR-006). Fit mode scales the image into the view; 100% zoom shows the full-resolution image at one
/// image pixel per screen pixel, panned by the mouse (R12, D5).
final class ViewerNSView: NSView {
    /// Returns true when the key was handled.
    var onKey: ((NSEvent) -> Bool)?
    var image: CGImage? { didSet { applyGeometry() } }
    var zoomImage: CGImage? { didSet { applyGeometry() } }
    /// nil = fit; 1 = 100%.
    var zoomScale: CGFloat? {
        didSet {
            applyGeometry()
            window?.invalidateCursorRects(for: self)
        }
    }
    /// The frame's upright size in pixels, known from EXIF before the full image arrives.
    var pixelSize: CGSize?
    /// Called with the new zoom when the scroll wheel or a pinch changes it.
    var onZoom: ((CGFloat?) -> Void)?
    /// Rejected frames are shown dimmed, as in the prototype.
    var dimmed = false { didSet { applyGeometry() } }

    private let imageLayer = CALayer()
    private var mouse: CGPoint?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setUp()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setUp()
    }

    private func setUp() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.addSublayer(imageLayer)
    }

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
        window?.acceptsMouseMovedEvents = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(
            NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func resetCursorRects() {
        if zoomScale != nil { addCursorRect(bounds, cursor: .crosshair) }
    }

    override func layout() {
        super.layout()
        applyGeometry()
    }

    override func mouseMoved(with event: NSEvent) {
        mouse = convert(event.locationInWindow, from: nil)
        if zoomScale != nil { applyGeometry() }
    }

    /// Wheel away from you (or two-finger up) zooms in, towards you zooms out, about the point under the
    /// mouse; past fit it snaps back to fit.
    override func scrollWheel(with event: NSEvent) {
        let raw = event.isDirectionInvertedFromDevice ? -event.scrollingDeltaY : event.scrollingDeltaY
        zoom(by: event.hasPreciseScrollingDeltas ? raw / 10 : raw, at: event)
    }

    /// Trackpad pinch.
    override func magnify(with event: NSEvent) {
        zoom(by: log(max(1 + event.magnification, 0.01)) * 10, at: event)
    }

    private func zoom(by steps: CGFloat, at event: NSEvent) {
        guard steps != 0, let points = pointSize else { return }
        mouse = convert(event.locationInWindow, from: nil)
        let fit = ZoomGeometry.fitScale(imageSize: points, viewSize: bounds.size)
        onZoom?(ZoomGeometry.scale(after: steps, from: zoomScale, fit: fit))
    }

    /// The 100% size in points.
    private var pointSize: CGSize? {
        guard let pixels = pixelSize else { return nil }
        return ZoomGeometry.pointSize(
            pixelWidth: Int(pixels.width), pixelHeight: Int(pixels.height), scale: window?.backingScaleFactor ?? 2)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        if onKey?(event) != true { super.keyDown(with: event) }
    }

    /// Key-ups reach the view even when the key-down was a menu shortcut.
    var onKeyUp: (() -> Void)?

    override func keyUp(with event: NSEvent) {
        onKeyUp?()
        super.keyUp(with: event)
    }

    /// Places the image without implicit animation, so panning follows the mouse exactly.
    private func applyGeometry() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let scale = zoomScale, let points = pointSize, let shown = zoomImage ?? image {
            // Until the full-resolution image arrives, the display image stands in at the zoomed size.
            imageLayer.contents = shown
            imageLayer.contentsGravity = .resize
            imageLayer.frame = ZoomGeometry.frame(
                imageSize: points, scale: scale, viewSize: bounds.size,
                mouse: mouse ?? CGPoint(x: bounds.midX, y: bounds.midY))
        } else {
            imageLayer.contents = image
            imageLayer.contentsGravity = .resizeAspect
            imageLayer.frame = bounds
        }
        imageLayer.opacity = dimmed ? 0.55 : 1
        CATransaction.commit()
    }
}

struct ViewerRepresentable: NSViewRepresentable {
    let image: CGImage?
    var zoomImage: CGImage?
    var zoomScale: CGFloat?
    var pixelSize: CGSize?
    var onZoom: ((CGFloat?) -> Void)?
    /// Called after a new image is put on screen (timing readout, T15).
    var onImageShown: (() -> Void)?
    var onKeyUp: (() -> Void)?
    let dimmed: Bool
    let onKey: (NSEvent) -> Bool

    func makeNSView(context: Context) -> ViewerNSView {
        let view = ViewerNSView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: ViewerNSView, context: Context) {
        view.onKey = onKey
        view.onKeyUp = onKeyUp
        if view.image !== image {
            view.image = image
            onImageShown?()
        }
        if view.zoomImage !== zoomImage { view.zoomImage = zoomImage }
        view.onZoom = onZoom
        view.pixelSize = pixelSize
        if view.zoomScale != zoomScale { view.zoomScale = zoomScale }
        if view.dimmed != dimmed { view.dimmed = dimmed }
    }
}
