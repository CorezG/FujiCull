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
    var isZoomed = false {
        didSet {
            applyGeometry()
            window?.invalidateCursorRects(for: self)
        }
    }
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
        if isZoomed { addCursorRect(bounds, cursor: .crosshair) }
    }

    override func layout() {
        super.layout()
        applyGeometry()
    }

    override func mouseMoved(with event: NSEvent) {
        mouse = convert(event.locationInWindow, from: nil)
        if isZoomed { applyGeometry() }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        if onKey?(event) != true { super.keyDown(with: event) }
    }

    /// Places the image without implicit animation, so panning follows the mouse exactly.
    private func applyGeometry() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if isZoomed, let full = zoomImage {
            imageLayer.contents = full
            imageLayer.contentsGravity = .resize
            let size = ZoomGeometry.pointSize(
                pixelWidth: full.width, pixelHeight: full.height, scale: window?.backingScaleFactor ?? 2)
            imageLayer.frame = ZoomGeometry.frame(
                imageSize: size, viewSize: bounds.size, mouse: mouse ?? CGPoint(x: bounds.midX, y: bounds.midY))
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
    var isZoomed = false
    let dimmed: Bool
    let onKey: (NSEvent) -> Bool

    func makeNSView(context: Context) -> ViewerNSView {
        let view = ViewerNSView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: ViewerNSView, context: Context) {
        view.onKey = onKey
        if view.image !== image { view.image = image }
        if view.zoomImage !== zoomImage { view.zoomImage = zoomImage }
        if view.isZoomed != isZoomed { view.isZoomed = isZoomed }
        if view.dimmed != dimmed { view.dimmed = dimmed }
    }
}
