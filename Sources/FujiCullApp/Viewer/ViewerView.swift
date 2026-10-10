import AppKit
import SwiftUI

/// The photo surface: a layer-backed NSView that scales the image to fit and takes keys directly,
/// which gives reliable key repeat (ADR-006).
final class ViewerNSView: NSView {
    /// Returns true when the key was handled.
    var onKey: ((NSEvent) -> Bool)?

    var image: CGImage? {
        didSet { layer?.contents = image }
    }

    /// Rejected frames are shown dimmed, as in the prototype.
    var dimmed = false {
        didSet { layer?.opacity = dimmed ? 0.55 : 1 }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.contentsGravity = .resizeAspect
        layer?.backgroundColor = NSColor.black.cgColor
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        layer?.contentsGravity = .resizeAspect
        layer?.backgroundColor = NSColor.black.cgColor
    }

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        if onKey?(event) != true { super.keyDown(with: event) }
    }
}

struct ViewerRepresentable: NSViewRepresentable {
    let image: CGImage?
    let dimmed: Bool
    let onKey: (NSEvent) -> Bool

    func makeNSView(context: Context) -> ViewerNSView {
        let view = ViewerNSView()
        view.onKey = onKey
        view.image = image
        view.dimmed = dimmed
        return view
    }

    func updateNSView(_ view: ViewerNSView, context: Context) {
        view.onKey = onKey
        if view.image !== image { view.image = image }
        if view.dimmed != dimmed { view.dimmed = dimmed }
    }
}
