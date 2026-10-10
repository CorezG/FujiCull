import AppKit
import FujiCullCore
import FujiCullImaging
import Observation

/// The open source, the cursor and the image on screen. Drives every view; all state changes happen here
/// on the main actor, and every card read goes through one `CardReader` (DESIGN §5.4, §5.5).
@MainActor @Observable
final class CullModel {
    enum Phase: Equatable {
        case start
        case scanning(name: String)
        case browsing
        case failed(message: String)
    }

    private enum Tier: String {
        case thumbnail = "t0"
        case display = "t1"
    }

    private(set) var phase: Phase = .start
    private(set) var detectedCards: [URL] = []
    private(set) var sourceName = ""
    private(set) var frames: [Frame] = []
    private(set) var cursor = 0
    /// The best image available for the current frame: the T1 display image, or its T0 thumbnail meanwhile.
    private(set) var currentImage: CGImage?
    private(set) var currentIsDisplayQuality = false

    @ObservationIgnored private var identityBase: URL?
    @ObservationIgnored private var sourceVolume: URL?
    @ObservationIgnored private let reader = CardReader()
    /// About five 2560 px frames (DESIGN §5.4 memory budget).
    @ObservationIgnored private var displayCache = PreviewCache<FrameID, CGImage>(byteBudget: 100_000_000)
    @ObservationIgnored private var thumbnailCache = PreviewCache<FrameID, CGImage>(byteBudget: 30_000_000)
    @ObservationIgnored private var inFlight: Set<String> = []
    /// Bumped whenever a source opens or closes, so results that arrive late are dropped.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    init() {
        refreshCards()
        let center = NSWorkspace.shared.notificationCenter
        observers.append(
            center.addObserver(forName: NSWorkspace.didMountNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshCards() }
            })
        observers.append(
            center.addObserver(forName: NSWorkspace.didUnmountNotification, object: nil, queue: .main) {
                [weak self] note in
                let volume = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL
                MainActor.assumeIsolated { self?.volumeUnmounted(volume) }
            })
    }

    var currentFrame: Frame? { frames.indices.contains(cursor) ? frames[cursor] : nil }

    func refreshCards() {
        detectedCards = SourceLocator.cameraCards(among: SourceLocator.mountedVolumes())
    }

    // MARK: Opening and closing

    func open(_ folder: URL) async {
        close()
        let name = Self.displayName(of: folder)
        phase = .scanning(name: name)
        let base = SourceLocator.identityBase(for: folder)
        do {
            let result = try await Task.detached(priority: .userInitiated) {
                try SourceScanner.scan(folder, identityBase: base)
            }.value
            sourceName = name
            identityBase = base
            sourceVolume = try? folder.resourceValues(forKeys: [.volumeURLKey]).volume
            frames = result.frames
            cursor = 0
            phase = .browsing
            showCurrent()
        } catch {
            phase = .failed(message: "Couldn't read \(name): \(error.localizedDescription)")
        }
    }

    /// Closes the source and frees every cached preview (DESIGN §5.4).
    func close() {
        generation += 1
        let reader = reader
        Task { await reader.cancelPending(except: []) }
        frames = []
        cursor = 0
        currentImage = nil
        currentIsDisplayQuality = false
        displayCache.removeAll()
        thumbnailCache.removeAll()
        inFlight.removeAll()
        identityBase = nil
        sourceVolume = nil
        sourceName = ""
        phase = .start
        refreshCards()
    }

    func dismissFailure() {
        phase = .start
    }

    private func volumeUnmounted(_ volume: URL?) {
        refreshCards()
        if let volume, let sourceVolume, volume.standardizedFileURL == sourceVolume.standardizedFileURL {
            close()
        }
    }

    // MARK: Navigation

    func move(by delta: Int) {
        guard phase == .browsing, !frames.isEmpty else { return }
        let target = min(max(cursor + delta, 0), frames.count - 1)
        guard target != cursor else { return }
        cursor = target
        showCurrent()
    }

    /// Shows the best cached image for the cursor, then asks the reader for what's missing around it.
    private func showCurrent() {
        guard let frame = currentFrame else { return }
        if let image = displayCache.value(for: frame.id) {
            currentImage = image
            currentIsDisplayQuality = true
        } else {
            currentImage = thumbnailCache.value(for: frame.id)
            currentIsDisplayQuality = false
        }

        let window = PrefetchWindow.requests(cursor: cursor, count: frames.count)
        let keep = Set(window.flatMap { [key(.thumbnail, frames[$0.index].id), key(.display, frames[$0.index].id)] })
        let reader = reader
        Task { await reader.cancelPending(except: keep) }

        if currentImage == nil { request(.thumbnail, index: cursor, priority: .current) }
        for item in window { request(.display, index: item.index, priority: item.priority) }
    }

    private func request(_ tier: Tier, index: Int, priority: ReadPriority) {
        let frame = frames[index]
        let key = key(tier, frame.id)
        let cached = tier == .display ? displayCache.value(for: frame.id) : thumbnailCache.value(for: frame.id)
        // RAF-only frames get their embedded preview in T14.
        guard cached == nil, !inFlight.contains(key), let jpg = frame.jpg, let base = identityBase else { return }
        inFlight.insert(key)
        let url = base.appendingPathComponent(jpg.relativePath)
        let maxPixelSize = Self.displayPixelSize()
        let generation = generation
        let reader = reader
        Task {
            do {
                let image = try await reader.submit(key: key, priority: priority) { () throws -> CGImage? in
                    switch tier {
                    case .thumbnail: return try ThumbnailLoader.load(url).image
                    case .display: return try PreviewPipeline.loadDisplay(url, maxPixelSize: maxPixelSize)
                    }
                }
                loaded(image, tier: tier, frameID: frame.id, key: key, generation: generation)
            } catch {
                // Cancelled because the cursor moved on, or unreadable. Either way, let a later visit retry.
                if generation == self.generation { inFlight.remove(key) }
            }
        }
    }

    private func loaded(_ image: CGImage?, tier: Tier, frameID: FrameID, key: String, generation: Int) {
        guard generation == self.generation else { return }
        inFlight.remove(key)
        guard let image else { return }
        let cost = image.bytesPerRow * image.height
        switch tier {
        case .display: displayCache.insert(image, for: frameID, cost: cost)
        case .thumbnail: thumbnailCache.insert(image, for: frameID, cost: cost)
        }
        guard currentFrame?.id == frameID else { return }
        if tier == .display {
            currentImage = image
            currentIsDisplayQuality = true
        } else if !currentIsDisplayQuality {
            currentImage = image
        }
    }

    // MARK: Helpers

    private func key(_ tier: Tier, _ id: FrameID) -> String { "\(tier.rawValue):\(id.rawValue)" }

    /// The long edge of the main screen in pixels, so T1 is never larger than what can be shown.
    private static func displayPixelSize() -> Int {
        guard let screen = NSScreen.main else { return 2560 }
        let size = screen.frame.size
        return Int(max(size.width, size.height) * screen.backingScaleFactor)
    }

    static func displayName(of url: URL) -> String {
        if let name = try? url.resourceValues(forKeys: [.volumeLocalizedNameKey, .volumeURLKey]),
            name.volume?.standardizedFileURL == url.standardizedFileURL, let volumeName = name.volumeLocalizedName
        {
            return volumeName
        }
        return url.lastPathComponent
    }
}
