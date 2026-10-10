import AppKit
import FujiCullCore
import FujiCullImaging
import Observation
import os

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
        case full = "t2"
    }

    private(set) var phase: Phase = .start
    private(set) var detectedCards: [URL] = []
    private(set) var sourceName = ""
    private(set) var frames: [Frame] = []
    /// Decisions, cursor, filter and undo (DESIGN §5.2).
    private(set) var session = CullSession(frameIDs: [])
    /// View toggles owned by the app (REQUIREMENTS §4.3): zoom (T12), grid (T11), EXIF line (T13).
    /// nil = fit; 1 = 100% (one image pixel per screen pixel); up to `ZoomGeometry.maxScale` (R12, D5).
    /// Returns to fit whenever the cursor moves to another frame.
    private(set) var zoomScale: CGFloat?
    var isZoomed: Bool { zoomScale != nil }
    private(set) var isGrid = false
    private(set) var showsExif = true
    /// Brief confirmation after a decision; `id` changes every time so the view can re-trigger it.
    private(set) var flash: (symbol: String, id: Int)?
    /// The best image available for the current frame: the T1 display image, or its T0 thumbnail meanwhile.
    private(set) var currentImage: CGImage?
    private(set) var currentIsDisplayQuality = false
    /// The current frame at full resolution, while zoomed to 100% (R12).
    private(set) var zoomImage: CGImage?
    /// Bumped (at most every 100 ms) as the background pass brings in thumbnails, so the filmstrip refreshes.
    private(set) var thumbnailRevision = 0
    /// Debug timing readout (View > Show Timings, T15): how long each move takes to reach the screen.
    private(set) var showsTimings = false
    private(set) var timingText = ""

    @ObservationIgnored private var identityBase: URL?
    @ObservationIgnored private var sourceVolume: URL?
    @ObservationIgnored private let reader = CardReader()
    /// Saves decisions in ~/Library/Application Support/FujiCull (DESIGN §5.3).
    @ObservationIgnored private let store = SessionStore(directory: CullModel.supportDirectory())
    @ObservationIgnored private var sessionKey: String?
    @ObservationIgnored private var saveRevision = 0
    @ObservationIgnored private var pendingResume: CullSession?
    /// Eight display images (~20 MB each at 2736 px). The prefetch window is five, so the frame preloaded
    /// for the next step is never pushed out early (owner saw intermittent lag with a 100 MB budget).
    @ObservationIgnored private var displayCache = PreviewCache<FrameID, CGImage>(byteBudget: 160_000_000)
    @ObservationIgnored private var thumbnailCache = PreviewCache<FrameID, CGImage>(byteBudget: 30_000_000)
    /// T2 for the current frame only, while zoomed: 80 MB at size M (DESIGN §5.4).
    @ObservationIgnored private var fullCache = PreviewCache<FrameID, CGImage>(byteBudget: 340_000_000)
    @ObservationIgnored private var inFlight: Set<String> = []
    /// Every frame's T0 once read: the thumbnail still compressed (~9 KB) plus EXIF (DESIGN §5.4).
    @ObservationIgnored private var headers: [FrameID: ThumbnailHeader] = [:]
    @ObservationIgnored private var metadataTask: Task<Void, Never>?
    @ObservationIgnored private var thumbnailRefreshScheduled = false
    @ObservationIgnored private var timing = MoveTiming()
    @ObservationIgnored var lastStripRefreshMs = 0.0
    /// Holding an arrow key: moves show thumbnails only, and the frame stopped on loads when the key is
    /// released or after a short rest (T15), so the card isn't busy reading frames already flown past.
    @ObservationIgnored private var isRifling = false
    @ObservationIgnored private var settleTask: Task<Void, Never>?
    @ObservationIgnored private var openStarted: ContinuousClock.Instant?
    @ObservationIgnored private var openScanMs = 0.0
    @ObservationIgnored private var zoomStarted: ContinuousClock.Instant?
    private static let timingLog = Logger(subsystem: "com.github.corezg.FujiCull", category: "timing")
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
        let started = ContinuousClock.now
        do {
            let result = try await Task.detached(priority: .userInitiated) {
                try SourceScanner.scan(folder, identityBase: base)
            }.value
            openScanMs = Self.milliseconds(since: started)
            openStarted = started
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
            beginBrowsing()
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
        saveSoon()
        beginBrowsing()
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
        beginBrowsing()
    }

    private func beginBrowsing() {
        phase = .browsing
        showCurrent()
        startMetadataPass()
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
        settleTask?.cancel()
        settleTask = nil
        isRifling = false
        openStarted = nil
        frames = []
        session = CullSession(frameIDs: [])
        zoomScale = nil
        isGrid = false
        flash = nil
        currentImage = nil
        currentIsDisplayQuality = false
        zoomImage = nil
        fullCache.removeAll()
        displayCache.removeAll()
        thumbnailCache.removeAll()
        metadataTask?.cancel()
        metadataTask = nil
        headers.removeAll()
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
        let started = ContinuousClock.now
        defer { timing.mainMs = Self.milliseconds(since: started) }
        // Keys can arrive as menu shortcuts or in the view, so take the time from the event itself.
        if let event = NSApp.currentEvent, event.type == .keyDown { timing.keyUptime = event.timestamp }
        switch action {
        case .cull(let command):
            let before = (cursor: session.cursor, frame: session.currentFrameID, mark: currentMark)
            session.apply(command)
            // Moving to another photo returns to fit (R12 as amended 2026-10-09).
            if session.currentFrameID != before.frame, isZoomed {
                zoomScale = nil
                zoomImage = nil
                fullCache.removeAll()
            }
            if let frame = before.frame, let index = frames.firstIndex(where: { $0.id == frame }),
                session.mark(at: index) != before.mark
            {
                flash(for: command, mark: session.mark(at: index))
            }
            if session.cursor != before.cursor || session.currentFrameID != before.frame {
                timing.start(frame: session.currentFrameID)
                if let event = NSApp.currentEvent, event.type == .keyDown, event.isARepeat {
                    isRifling = true
                    showCurrent(loadsDisplay: false)
                    settleSoon()
                } else {
                    isRifling = false
                    showCurrent()
                }
            }
            saveSoon()
        case .fitToWindow:
            setZoom(nil)
        case .toggleZoom, .toggleGrid, .toggleExif:
            guard canPerform(action) else { return }
            switch action {
            // In the grid, Return opens the selected frame in the single view.
            case .toggleZoom where isGrid:
                isGrid = false
                showCurrent()
            case .toggleZoom:
                setZoom(isZoomed ? nil : 1)
            case .toggleGrid:
                isGrid.toggle()
                if !isGrid { showCurrent() }
            default: showsExif.toggle()
            }
        }
    }

    /// A key was released: if it was being held, load the frame it stopped on now.
    func keyReleased() {
        guard isRifling else { return }
        settle()
    }

    private func settleSoon() {
        settleTask?.cancel()
        settleTask = Task {
            do { try await Task.sleep(for: .milliseconds(120)) } catch { return }
            settle()
        }
    }

    private func settle() {
        settleTask?.cancel()
        settleTask = nil
        guard isRifling else { return }
        isRifling = false
        showCurrent()
    }

    // MARK: Timing (T15)

    func toggleTimings() {
        showsTimings.toggle()
    }

    /// Called by the viewer each time it puts a new image on screen.
    func imageShown() {
        if let started = openStarted, currentImage != nil {
            openStarted = nil
            let first = Int(Self.milliseconds(since: started))
            Self.timingLog.notice(
                "open \(self.sourceName, privacy: .public): \(self.frames.count, privacy: .public) frames, scan \(Int(self.openScanMs), privacy: .public) ms, first photo \(first, privacy: .public) ms"
            )
        }
        guard let frame = currentFrame?.id, timing.frame == frame, let key = timing.keyUptime else { return }
        let ms = (ProcessInfo.processInfo.systemUptime - key) * 1000
        if timing.photoMs == nil {
            timing.photoMs = ms
            timing.wasPreloaded = currentIsDisplayQuality
        }
        if currentIsDisplayQuality, timing.sharpMs == nil {
            timing.sharpMs = ms
            let photo = Int(timing.photoMs ?? ms)
            let sharp = Int(ms)
            let source = timing.wasPreloaded ? "preloaded" : "loaded"
            let main = String(format: "%.1f", timing.mainMs)
            let strip = String(format: "%.1f", lastStripRefreshMs)
            timingText = "key→photo \(photo) ms · sharp \(sharp) ms (\(source)) · main \(main) ms · strip \(strip) ms"
            Self.timingLog.notice(
                "move \(frame.rawValue, privacy: .public): photo \(photo, privacy: .public) ms, sharp \(sharp, privacy: .public) ms, \(source, privacy: .public), main \(main, privacy: .public) ms, strip \(strip, privacy: .public) ms"
            )
        }
    }

    static func milliseconds(since start: ContinuousClock.Instant) -> Double {
        let elapsed = ContinuousClock.now - start
        return Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
    }

    /// Sets the zoom from Return, the scroll wheel or a pinch. Full-resolution images load only while zoomed
    /// and are freed when it returns to fit.
    func setZoom(_ scale: CGFloat?) {
        guard phase == .browsing, !isGrid, scale == nil || currentFrame?.jpg != nil else { return }
        let wasZoomed = isZoomed
        zoomScale = scale
        if scale != nil, !wasZoomed { zoomStarted = .now }
        if scale == nil {
            zoomImage = nil
            fullCache.removeAll()
        } else if !wasZoomed {
            showCurrent()
        }
    }

    /// The current frame's EXIF, once its T0 has been read.
    var currentExif: ExifSummary? {
        guard let frame = currentFrame else { return nil }
        return headers[frame.id]?.exif
    }

    /// The current frame's upright size in pixels, from EXIF, so zoom can be sized before the full image loads.
    var currentPixelSize: CGSize? {
        if let zoomImage { return CGSize(width: zoomImage.width, height: zoomImage.height) }
        guard let frame = currentFrame, let size = headers[frame.id]?.exif.uprightPixelSize else { return nil }
        return CGSize(width: size.width, height: size.height)
    }

    func canPerform(_ action: KeyAction) -> Bool {
        guard phase == .browsing else { return false }
        switch action {
        case .cull(.undo): return session.canUndo
        case .cull: return !frames.isEmpty
        case .toggleGrid: return !frames.isEmpty
        case .fitToWindow: return isZoomed
        // Return opens the selected frame from the grid; in the single view it zooms a frame that has a JPG.
        case .toggleZoom: return isGrid || currentFrame?.jpg != nil
        case .toggleExif: return !frames.isEmpty
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
    private func showCurrent(loadsDisplay: Bool = true) {
        guard let frame = currentFrame else {
            currentImage = nil
            zoomImage = nil
            return
        }
        zoomImage = isZoomed ? fullCache.value(for: frame.id) : nil
        if let image = displayCache.value(for: frame.id) {
            currentImage = image
            currentIsDisplayQuality = true
        } else {
            currentImage = thumbnailImage(for: frame.id)
            currentIsDisplayQuality = false
        }

        // Prefetch through the frames being browsed, so the Undecided-only filter skips decided ones.
        let visible = session.visibleIndices
        let position = visible.firstIndex(of: session.cursor) ?? 0
        let window = PrefetchWindow.requests(cursor: position, count: visible.count).map {
            (index: visible[$0.index], priority: $0.priority)
        }
        // While zoomed, the full-resolution current frame (zoom doesn't carry over to other frames).
        let zoomWindow = isZoomed ? Array(window.prefix(1)) : []
        let keep = Set(
            window.flatMap { [key(.thumbnail, frames[$0.index].id), key(.display, frames[$0.index].id)] }
                + zoomWindow.map { key(.full, frames[$0.index].id) })
        let reader = reader
        // Only the viewer's own window is cancelled; filmstrip thumbnails and the background pass carry on.
        // While rifling, nothing but the current thumbnail is kept, so the card is free when the key is released.
        let keepNow = loadsDisplay ? keep : [key(.thumbnail, frame.id)]
        Task { await reader.cancelPending(except: keepNow, upTo: .behind1) }

        if currentImage == nil {
            let index = session.cursor
            Task { await fetchHeader(index: index, priority: .current) }
        }
        // The grid shows thumbnails only, so it doesn't read whole JPGs from the card.
        guard !isGrid, loadsDisplay else { return }
        // Zoomed: the full-resolution frame first, so 100% appears as soon as possible.
        for item in zoomWindow { requestFull(index: item.index, priority: item.priority) }
        for item in window { requestDisplay(index: item.index, priority: item.priority) }
    }

    private func requestDisplay(index: Int, priority: ReadPriority) {
        let frame = frames[index]
        let key = key(.display, frame.id)
        // A RAF-only frame shows the full-size JPEG embedded in the RAF (R4).
        guard displayCache.value(for: frame.id) == nil, !inFlight.contains(key), let file = frame.jpg ?? frame.raf,
            let base = identityBase
        else { return }
        inFlight.insert(key)
        let url = base.appendingPathComponent(file.relativePath)
        let maxPixelSize = Self.displayPixelSize()
        let generation = generation
        let reader = reader
        Task {
            do {
                // The card reader only reads; decoding runs alongside, so the next file's read isn't held up.
                let data = try await reader.submit(key: key, priority: priority) { try PreviewPipeline.readJPEG(url) }
                let image = try await Task.detached(priority: .userInitiated) {
                    try PreviewPipeline.decodeDisplay(data, maxPixelSize: maxPixelSize)
                }.value
                guard generation == self.generation else { return }
                inFlight.remove(key)
                displayCache.insert(image, for: frame.id, cost: image.bytesPerRow * image.height)
                if currentFrame?.id == frame.id {
                    currentImage = image
                    currentIsDisplayQuality = true
                }
            } catch {
                // Cancelled because the cursor moved on, or unreadable. Either way, let a later visit retry.
                if generation == self.generation { inFlight.remove(key) }
            }
        }
    }

    /// T2: every pixel, only while zoomed (DESIGN §5.4).
    private func requestFull(index: Int, priority: ReadPriority) {
        let frame = frames[index]
        let key = key(.full, frame.id)
        guard fullCache.value(for: frame.id) == nil, !inFlight.contains(key), let jpg = frame.jpg,
            let base = identityBase
        else { return }
        inFlight.insert(key)
        let url = base.appendingPathComponent(jpg.relativePath)
        let generation = generation
        let reader = reader
        Task {
            do {
                let requested = ContinuousClock.now
                let data = try await reader.submit(key: key, priority: priority) { try Data(contentsOf: url) }
                let readMs = Int(Self.milliseconds(since: requested))
                let decodeStarted = ContinuousClock.now
                let image = try await Task.detached(priority: .userInitiated) {
                    try PreviewPipeline.decodeFull(data)
                }.value
                let decodeMs = Int(Self.milliseconds(since: decodeStarted))
                guard generation == self.generation else { return }
                inFlight.remove(key)
                guard isZoomed else { return }
                fullCache.insert(image, for: frame.id, cost: image.bytesPerRow * image.height)
                if currentFrame?.id == frame.id {
                    zoomImage = image
                    if let started = zoomStarted {
                        zoomStarted = nil
                        Self.timingLog.notice(
                            "zoom \(frame.id.rawValue, privacy: .public): full resolution in \(Int(Self.milliseconds(since: started)), privacy: .public) ms (read \(readMs, privacy: .public) ms, decode \(decodeMs, privacy: .public) ms, \(image.width, privacy: .public)x\(image.height, privacy: .public))"
                        )
                    }
                }
            } catch {
                if generation == self.generation { inFlight.remove(key) }
            }
        }
    }

    // MARK: Thumbnails (T0)

    /// Asks for a frame's thumbnail, for a filmstrip cell that has scrolled into view.
    func requestThumbnail(at index: Int) {
        Task { await fetchHeader(index: index, priority: .thumbnail) }
    }

    func hasThumbnail(at index: Int) -> Bool {
        frames.indices.contains(index) && headers[frames[index].id] != nil
    }

    /// The upright thumbnail for a frame, decoded on demand from its compressed T0 and cached (LRU).
    func thumbnailImage(at index: Int) -> CGImage? {
        frames.indices.contains(index) ? thumbnailImage(for: frames[index].id) : nil
    }

    private func thumbnailImage(for id: FrameID) -> CGImage? {
        if let cached = thumbnailCache.value(for: id) { return cached }
        guard let header = headers[id], let jpeg = header.thumbnailJPEG,
            let image = ThumbnailLoader.decodeThumbnail(jpeg, orientation: header.exif.orientation)
        else { return nil }
        thumbnailCache.insert(image, for: id, cost: image.bytesPerRow * image.height)
        return image
    }

    /// Reads a frame's T0 once; returns when it's stored, cancelled or already being fetched elsewhere.
    private func fetchHeader(index: Int, priority: ReadPriority) async {
        guard frames.indices.contains(index) else { return }
        let frame = frames[index]
        let key = key(.thumbnail, frame.id)
        guard headers[frame.id] == nil, !inFlight.contains(key), let file = frame.jpg ?? frame.raf,
            let base = identityBase
        else { return }
        inFlight.insert(key)
        let url = base.appendingPathComponent(file.relativePath)
        let generation = generation
        do {
            let header = try await reader.submit(key: key, priority: priority) { try ThumbnailLoader.loadHeader(url) }
            guard generation == self.generation else { return }
            inFlight.remove(key)
            headers[frame.id] = header
            thumbnailsChanged()
            if currentFrame?.id == frame.id, !currentIsDisplayQuality, let image = thumbnailImage(for: frame.id) {
                currentImage = image
            }
        } catch {
            if generation == self.generation { inFlight.remove(key) }
        }
    }

    /// Reads every frame's T0 in the background, starting at the cursor (DESIGN §5.4). About 4.5 s for
    /// 2,091 frames on Fuji SD; viewer requests always jump ahead of it in the card reader's queue.
    private func startMetadataPass() {
        metadataTask?.cancel()
        let order = MetadataPass.order(count: frames.count, startingAt: session.cursor)
        let generation = generation
        metadataTask = Task {
            for index in order {
                if Task.isCancelled || generation != self.generation { return }
                await fetchHeader(index: index, priority: .background)
            }
        }
    }

    private func thumbnailsChanged() {
        guard !thumbnailRefreshScheduled else { return }
        thumbnailRefreshScheduled = true
        Task {
            do {
                try await Task.sleep(for: .milliseconds(100))
            } catch {
                thumbnailRefreshScheduled = false
                return
            }
            thumbnailRefreshScheduled = false
            thumbnailRevision += 1
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

/// One move's timings, for the debug readout.
private struct MoveTiming {
    var frame: FrameID?
    var keyUptime: TimeInterval?
    var photoMs: Double?
    var sharpMs: Double?
    var wasPreloaded = false
    var mainMs = 0.0

    mutating func start(frame: FrameID?) {
        self.frame = frame
        photoMs = nil
        sharpMs = nil
        wasPreloaded = false
    }
}
