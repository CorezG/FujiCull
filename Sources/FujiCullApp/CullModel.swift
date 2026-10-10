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
        /// Only part of the saved session matches the card: ask Resume or Start fresh (SR4).
        case resumePrompt(matched: Int, expected: Int)
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
    /// Decisions, cursor, filter and undo (DESIGN §5.2).
    private(set) var session = CullSession(frameIDs: [])
    /// View toggles owned by the app (REQUIREMENTS §4.3): zoom (T12), grid (T11), EXIF line (T13).
    private(set) var isZoomed = false
    private(set) var isGrid = false
    private(set) var showsExif = true
    /// Brief confirmation after a decision; `id` changes every time so the view can re-trigger it.
    private(set) var flash: (symbol: String, id: Int)?
    /// The best image available for the current frame: the T1 display image, or its T0 thumbnail meanwhile.
    private(set) var currentImage: CGImage?
    private(set) var currentIsDisplayQuality = false

    @ObservationIgnored private var identityBase: URL?
    @ObservationIgnored private var sourceVolume: URL?
    @ObservationIgnored private let reader = CardReader()
    /// Saves decisions in ~/Library/Application Support/FujiCull (DESIGN §5.3).
    @ObservationIgnored private let store = SessionStore(directory: CullModel.supportDirectory())
    @ObservationIgnored private var sessionKey: String?
    @ObservationIgnored private var saveRevision = 0
    @ObservationIgnored private var pendingResume: CullSession?
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
        observers.append(
            NotificationCenter.default.addObserver(
                forName: NSApplication.willTerminateNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.saveBeforeQuitting() }
            })
    }

    var cursor: Int { session.cursor }

    /// The frame on screen, or nil when the Undecided-only list is empty.
    var currentFrame: Frame? { session.currentFrameID == nil ? nil : frames[session.cursor] }

    var currentMark: FrameMark { frames.isEmpty ? FrameMark() : session.mark(at: session.cursor) }

    /// 1-based position within the frames being browsed, and how many there are.
    var position: (index: Int, count: Int) {
        let visible = session.visibleIndices
        return ((visible.firstIndex(of: session.cursor) ?? -1) + 1, visible.count)
    }

    func refreshCards() {
        detectedCards = SourceLocator.cameraCards(among: SourceLocator.mountedVolumes())
    }

    // MARK: Opening and closing

    func open(_ folder: URL) async {
        await closeSource()
        let name = Self.displayName(of: folder)
        phase = .scanning(name: name)
        let base = SourceLocator.identityBase(for: folder)
        do {
            let result = try await Task.detached(priority: .userInitiated) {
                try SourceScanner.scan(folder, identityBase: base)
            }.value
            let key = try SessionKey.for(source: folder)
            let saved = try await store.open(key: key)
            sourceName = name
            identityBase = base
            sourceVolume = try? folder.resourceValues(forKeys: [.volumeURLKey]).volume
            sessionKey = key
            frames = result.frames
            switch SessionRestore.match(saved, to: result.frames) {
            case .none:
                session = CullSession(frameIDs: result.frames.map(\.id))
            case .full(let restored):
                session = restored
            case .partial(let matched, let expected, let resumed):
                pendingResume = resumed
                phase = .resumePrompt(matched: matched, expected: expected)
                return
            }
            phase = .browsing
            showCurrent()
        } catch SessionStore.StoreError.alreadyOpen {
            phase = .failed(message: "\(name) is already open in another FujiCull window.")
        } catch SessionStore.StoreError.newerVersion {
            phase = .failed(message: "\(name) was saved by a newer version of FujiCull. Update FujiCull to open it.")
        } catch {
            phase = .failed(message: "Couldn't read \(name): \(error.localizedDescription)")
        }
    }

    /// Resume: keep the saved decisions that still match the card.
    func resumeSession() {
        guard case .resumePrompt = phase, let resumed = pendingResume else { return }
        pendingResume = nil
        session = resumed
        phase = .browsing
        saveSoon()
        showCurrent()
    }

    /// Start fresh: the old session and journal are archived, and every frame starts Undecided.
    func startFresh() async {
        guard case .resumePrompt = phase else { return }
        pendingResume = nil
        do {
            try await store.startFresh()
        } catch {
            phase = .failed(message: "Couldn't archive the old session: \(error.localizedDescription)")
            return
        }
        session = CullSession(frameIDs: frames.map(\.id))
        phase = .browsing
        showCurrent()
    }

    /// For menus and notifications, which can't await.
    func close() {
        Task { await closeSource() }
    }

    /// Saves, releases the card's session lock and frees every cached preview (DESIGN §5.3, §5.4).
    func closeSource() async {
        generation += 1
        let reader = reader
        Task { await reader.cancelPending(except: []) }
        if sessionKey != nil {
            saveSoon()
            do { try await store.close() } catch { phase = .failed(message: "Couldn't save: \(error)") }
        }
        sessionKey = nil
        pendingResume = nil
        frames = []
        session = CullSession(frameIDs: [])
        isZoomed = false
        isGrid = false
        flash = nil
        currentImage = nil
        currentIsDisplayQuality = false
        displayCache.removeAll()
        thumbnailCache.removeAll()
        inFlight.removeAll()
        identityBase = nil
        sourceVolume = nil
        sourceName = ""
        if case .failed = phase {} else { phase = .start }
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

    // MARK: Saving

    /// Queues a save of the current state; the store writes the latest one after a short pause (SR5).
    private func saveSoon() {
        guard let key = sessionKey else { return }
        saveRevision += 1
        let file = SessionFile(key: key, rootHint: identityBase?.path ?? "", session: session, frames: frames)
        let revision = saveRevision
        let store = store
        Task { await store.scheduleSave(file, revision: revision) }
    }

    /// Quitting can't wait for an async task, so this blocks briefly until the latest state is on disk.
    private func saveBeforeQuitting() {
        guard let key = sessionKey else { return }
        let file = SessionFile(key: key, rootHint: identityBase?.path ?? "", session: session, frames: frames)
        let store = store
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            do {
                try await store.save(file)
                try await store.close()
            } catch {
                FileHandle.standardError.write(Data("FujiCull: couldn't save before quitting: \(error)\n".utf8))
            }
            done.signal()
        }
        _ = done.wait(timeout: .now() + 5)
    }

    private static func supportDirectory() -> URL {
        let base =
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("FujiCull", isDirectory: true)
    }

    // MARK: Commands

    /// The single entry point for keys and menu items (ADR-006), so each fires exactly once.
    func perform(_ action: KeyAction) {
        guard phase == .browsing else { return }
        switch action {
        case .cull(let command):
            let before = (cursor: session.cursor, frame: session.currentFrameID, mark: currentMark)
            session.apply(command)
            if let frame = before.frame, let index = frames.firstIndex(where: { $0.id == frame }),
                session.mark(at: index) != before.mark
            {
                flash(for: command, mark: session.mark(at: index))
            }
            if session.cursor != before.cursor || session.currentFrameID != before.frame { showCurrent() }
            saveSoon()
        case .toggleZoom, .toggleGrid, .toggleExif:
            guard canPerform(action) else { return }
            switch action {
            case .toggleZoom: isZoomed.toggle()
            case .toggleGrid: isGrid.toggle()
            default: showsExif.toggle()
            }
        }
    }

    func canPerform(_ action: KeyAction) -> Bool {
        guard phase == .browsing else { return false }
        switch action {
        case .cull(.undo): return session.canUndo
        case .cull: return !frames.isEmpty
        // Shown in the menus now so the keymap is complete; their views arrive in T11 (grid),
        // T12 (zoom) and T13 (EXIF line).
        case .toggleZoom, .toggleGrid, .toggleExif: return false
        }
    }

    private func flash(for command: CullCommand, mark: FrameMark) {
        let symbol: String
        switch command {
        case .keep: symbol = "✓"
        case .reject: symbol = "✕"
        case .toggleFavourite: symbol = mark.isFavourite ? "♥" : "♡"
        default: return
        }
        flash = (symbol, (flash?.id ?? 0) + 1)
    }

    /// Shows the best cached image for the cursor, then asks the reader for what's missing around it.
    private func showCurrent() {
        guard let frame = currentFrame else {
            currentImage = nil
            return
        }
        if let image = displayCache.value(for: frame.id) {
            currentImage = image
            currentIsDisplayQuality = true
        } else {
            currentImage = thumbnailCache.value(for: frame.id)
            currentIsDisplayQuality = false
        }

        // Prefetch through the frames being browsed, so the Undecided-only filter skips decided ones.
        let visible = session.visibleIndices
        let position = visible.firstIndex(of: session.cursor) ?? 0
        let window = PrefetchWindow.requests(cursor: position, count: visible.count).map {
            (index: visible[$0.index], priority: $0.priority)
        }
        let keep = Set(window.flatMap { [key(.thumbnail, frames[$0.index].id), key(.display, frames[$0.index].id)] })
        let reader = reader
        Task { await reader.cancelPending(except: keep) }

        if currentImage == nil { request(.thumbnail, index: session.cursor, priority: .current) }
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
