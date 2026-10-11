import AppKit
import FujiCullCore
import SwiftUI

/// Thumbnails of every frame with its decision, virtualised by NSCollectionView so 2,000+ frames scroll
/// smoothly (ADR-006). Two styles share the cells and loading:
/// - `.strip`: the filmstrip along the bottom (R14). It never takes keyboard focus, so keys reach the viewer.
/// - `.grid`: the grid view (R15). It takes the keys itself; the selection is the cursor.
/// Clicking a cell goes to that frame.
struct FilmstripView: NSViewRepresentable {
    enum Style {
        case strip
        case grid
    }

    /// Strip height: the cell, its insets and a little slack, plus room for the scroll bar underneath, so
    /// the bar never takes space from the thumbnails.
    static let stripHeight =
        FilmstripCell.height + 28 + NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy)

    let model: CullModel
    var style: Style = .strip
    /// Grid only: the keymap handler (returns true when the key was used).
    var onKey: ((NSEvent) -> Bool)?
    /// Inputs that should trigger a refresh. SwiftUI calls `updateNSView` when they change.
    let session: CullSession
    let thumbnailRevision: Int

    func makeCoordinator() -> FilmstripCoordinator { FilmstripCoordinator(model: model) }

    func makeNSView(context: Context) -> NSScrollView {
        let layout = NSCollectionViewFlowLayout()
        switch style {
        case .strip:
            layout.scrollDirection = .horizontal
            layout.itemSize = NSSize(width: FilmstripCell.width, height: FilmstripCell.height)
            layout.minimumLineSpacing = 6
            layout.sectionInset = NSEdgeInsets(top: 12, left: 12, bottom: 8, right: 12)
        case .grid:
            layout.scrollDirection = .vertical
            layout.itemSize = NSSize(width: 184, height: 138)
            layout.minimumLineSpacing = 14
            layout.minimumInteritemSpacing = 14
            layout.sectionInset = NSEdgeInsets(top: 18, left: 18, bottom: 18, right: 18)
        }

        let collection = ThumbnailCollectionView()
        collection.takesKeys = style == .grid
        collection.onKey = onKey
        collection.collectionViewLayout = layout
        collection.backgroundColors = [style == .strip ? NSColor(white: 0.14, alpha: 1) : .black]
        collection.isSelectable = false
        collection.register(FilmstripItem.self, forItemWithIdentifier: FilmstripItem.identifier)
        collection.dataSource = context.coordinator
        context.coordinator.collection = collection
        context.coordinator.scrollPosition = style == .strip ? .centeredHorizontally : .nearestHorizontalEdge
        context.coordinator.opensOnDoubleClick = style == .grid

        let scroll = style == .strip ? StripScrollView() : NSScrollView()
        scroll.documentView = collection
        scroll.hasHorizontalScroller = false
        scroll.hasVerticalScroller = style == .grid
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsetsZero
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        (scroll.documentView as? ThumbnailCollectionView)?.onKey = onKey
        context.coordinator.refresh(session: session, thumbnailRevision: thumbnailRevision)
    }
}

/// The strip's scroll view, with a scroll bar that is always there to grab and drag through a long card
/// (owner's request, 2026-10-11). `stripHeight` leaves room for it below the thumbnails.
///
/// History, so this isn't undone by accident: NSCollectionView switches the horizontal bar on for a
/// horizontal layout. Without room for it the bar took 17 pt from the cells and AppKit warned on every
/// layout pass; refusing the bar stopped the strip scrolling to the current frame; an overlay bar fixed both
/// but can't be grabbed with a mouse (docs/spikes/perf.md).
private final class StripScrollView: NSScrollView {
    override var scrollerStyle: NSScroller.Style {
        get { .legacy }
        set {}
    }
}

/// The strip never takes focus, so keys keep going to the viewer; the grid takes focus and hands every key
/// to the keymap, so ↑/↓ decide and ←/→ move instead of the collection view's own selection behaviour.
private final class ThumbnailCollectionView: NSCollectionView {
    var takesKeys = false
    var onKey: ((NSEvent) -> Bool)?

    override var acceptsFirstResponder: Bool { takesKeys }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if takesKeys { window?.makeFirstResponder(self) }
    }

    override func keyDown(with event: NSEvent) {
        if onKey?(event) != true { super.keyDown(with: event) }
    }
}

@MainActor
final class FilmstripCoordinator: NSObject, NSCollectionViewDataSource {
    private let model: CullModel
    weak var collection: NSCollectionView?
    var scrollPosition: NSCollectionView.ScrollPosition = .centeredHorizontally
    /// Grid only: a double-click opens the frame in the single view, like Return.
    var opensOnDoubleClick = false
    private var shownCount = -1
    private var shownCursor = -1

    init(model: CullModel) {
        self.model = model
    }

    func refresh(session: CullSession, thumbnailRevision: Int) {
        guard let collection else { return }
        let started = ContinuousClock.now
        defer { model.lastStripRefreshMs = CullModel.milliseconds(since: started) }
        if session.frameIDs.count != shownCount {
            shownCount = session.frameIDs.count
            shownCursor = -1
            collection.reloadData()
        } else {
            // Only the cells on screen; the rest are configured when they scroll into view.
            for indexPath in collection.indexPathsForVisibleItems() {
                (collection.item(at: indexPath) as? FilmstripItem).map { configure($0, index: indexPath.item) }
            }
        }
        if session.cursor != shownCursor, shownCount > 0 {
            shownCursor = session.cursor
            collection.layoutSubtreeIfNeeded()
            collection.scrollToItems(
                at: [IndexPath(item: session.cursor, section: 0)], scrollPosition: scrollPosition)
        }
    }

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        model.frames.count
    }

    func collectionView(
        _ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath
    ) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: FilmstripItem.identifier, for: indexPath)
        if let item = item as? FilmstripItem { configure(item, index: indexPath.item) }
        return item
    }

    private func configure(_ item: FilmstripItem, index: Int) {
        guard model.frames.indices.contains(index) else { return }
        let session = model.session
        if !model.hasThumbnail(at: index) { model.requestThumbnail(at: index) }
        let frame = model.frames[index]
        item.cell.show(
            image: model.thumbnailImage(at: index), mark: session.mark(at: index), isCurrent: index == session.cursor,
            isHidden: session.undecidedOnly && session.mark(at: index).decision != .undecided,
            unpaired: frame.isUnpaired ? (frame.jpg == nil ? "RAF" : "JPG") : nil)
        item.onClick = { [weak self] clicks in
            guard let self else { return }
            model.perform(.cull(.goTo(index)))
            if clicks == 2, opensOnDoubleClick { model.perform(.toggleZoom) }
        }
    }
}

final class FilmstripItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("FilmstripItem")
    let cell = FilmstripCell()
    /// Called with the click count: 1 selects, 2 also opens the frame from the grid.
    var onClick: ((Int) -> Void)?

    override func loadView() {
        view = cell
        cell.onClick = { [weak self] clicks in self?.onClick?(clicks) }
    }
}

/// One thumbnail: the image fitted inside, a coloured bar for Keep/Reject, ♥ for favourites, a white
/// outline on the current frame, rejects dimmed, and frames hidden by the Undecided filter faded (R14).
final class FilmstripCell: NSView {
    static let width: CGFloat = 86
    static let height: CGFloat = 64

    var onClick: ((Int) -> Void)?
    private let imageLayer = CALayer()
    private let barLayer = CALayer()
    private let heartLayer = CATextLayer()
    /// ✎ on a frame flagged as needing a RAW edit (R28).
    private let editLayer = CATextLayer()
    /// "RAF" or "JPG" on an unpaired frame (R4).
    private let badgeLayer = CATextLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: Self.height))
        wantsLayer = true
        guard let layer else { return }
        layer.backgroundColor = NSColor(white: 0.07, alpha: 1).cgColor
        layer.cornerRadius = 4
        layer.masksToBounds = true
        layer.borderColor = NSColor.white.cgColor
        imageLayer.contentsGravity = .resizeAspect
        layer.addSublayer(imageLayer)
        layer.addSublayer(barLayer)
        heartLayer.string = "♥"
        heartLayer.fontSize = 11
        heartLayer.foregroundColor = NSColor.systemPink.cgColor
        heartLayer.alignmentMode = .right
        heartLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        layer.addSublayer(heartLayer)
        editLayer.string = "✎"
        editLayer.fontSize = 11
        editLayer.foregroundColor = NSColor.systemOrange.cgColor
        editLayer.alignmentMode = .right
        editLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        layer.addSublayer(editLayer)
        badgeLayer.fontSize = 9
        badgeLayer.foregroundColor = NSColor.black.cgColor
        badgeLayer.backgroundColor = NSColor.systemYellow.cgColor
        badgeLayer.cornerRadius = 3
        badgeLayer.alignmentMode = .center
        badgeLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        layer.addSublayer(badgeLayer)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func layout() {
        super.layout()
        imageLayer.frame = bounds
        barLayer.frame = NSRect(x: 0, y: 0, width: bounds.width, height: 3)
        heartLayer.frame = NSRect(x: bounds.width - 18, y: bounds.height - 16, width: 15, height: 14)
        editLayer.frame = NSRect(x: bounds.width - 32, y: bounds.height - 16, width: 15, height: 14)
        badgeLayer.frame = NSRect(x: 4, y: bounds.height - 15, width: 26, height: 12)
    }

    func show(image: CGImage?, mark: FrameMark, isCurrent: Bool, isHidden: Bool, unpaired: String? = nil) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.contents = image
        imageLayer.opacity = mark.decision == .reject ? 0.32 : 1
        switch mark.decision {
        case .keep: barLayer.backgroundColor = NSColor.systemGreen.cgColor
        case .reject: barLayer.backgroundColor = NSColor.systemRed.cgColor
        case .undecided: barLayer.backgroundColor = NSColor.clear.cgColor
        }
        heartLayer.isHidden = !mark.isFavourite
        editLayer.isHidden = !mark.needsEdit
        badgeLayer.string = unpaired
        badgeLayer.isHidden = unpaired == nil
        layer?.borderWidth = isCurrent ? 2 : 0
        alphaValue = isHidden ? 0.18 : 1
        CATransaction.commit()
    }

    override func mouseDown(with event: NSEvent) {
        onClick?(event.clickCount)
    }
}
