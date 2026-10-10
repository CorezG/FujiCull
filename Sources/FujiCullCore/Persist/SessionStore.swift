import Foundation

/// Saves one card's session in `~/Library/Application Support/FujiCull/` (DESIGN §5.3):
/// `Sessions/<key>.json`, beside the Apply journal `Ledger/<key>.jsonl`.
///
/// - One writer (SR5): every save goes through this actor, so the latest state always wins.
/// - Locked while open (SR3): a second window or process can't open the same card.
/// - Crash-safe: atomic replace, then `F_FULLFSYNC` of the file and its folder.
/// - Writes only. Archiving and setting aside are copy-then-reset, so this code never deletes, moves or
///   renames a file (CONSTRAINTS.md architecture rule; only the Apply engine does that).
public actor SessionStore {
    public enum StoreError: Error, Equatable {
        case alreadyOpen(key: String)
        case notOpen
        /// Written by a newer FujiCull; left untouched rather than overwritten.
        case newerVersion(key: String)
        case io(String)
    }

    private let directory: URL
    private let debounce: Duration
    private var key: String?
    private var lockDescriptor: Int32 = -1
    private var pending: SessionFile?
    private var flushTask: Task<Void, Never>?
    /// The last error from a debounced save, reported by the next `flush` or `close`.
    private var deferredError: Error?

    public init(directory: URL, debounce: Duration = .milliseconds(300)) {
        self.directory = directory
        self.debounce = debounce
    }

    private var sessions: URL { directory.appendingPathComponent("Sessions", isDirectory: true) }
    private var ledgers: URL { directory.appendingPathComponent("Ledger", isDirectory: true) }
    private var locks: URL { directory.appendingPathComponent("Locks", isDirectory: true) }

    // MARK: Open and close

    /// Locks `key` and returns its saved session, or nil if there isn't a usable one.
    public func open(key: String) throws -> SessionFile? {
        if self.key != nil { try close() }
        for folder in [sessions, ledgers, locks] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        let lockPath = locks.appendingPathComponent("\(key).lock").path
        let descriptor = Darwin.open(lockPath, O_CREAT | O_RDWR | O_EXLOCK | O_NONBLOCK | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else {
            if errno == EWOULDBLOCK { throw StoreError.alreadyOpen(key: key) }
            throw StoreError.io("could not lock \(lockPath): errno \(errno)")
        }
        lockDescriptor = descriptor
        self.key = key

        let url = sessionURL(key)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        let file: SessionFile
        do {
            file = try JSONDecoder().decode(SessionFile.self, from: data)
        } catch {
            try write(data, to: sessions.appendingPathComponent("\(key).json.bad-\(Self.timestamp())"))
            try write(Self.encoded(SessionFile.empty(key: key)), to: url)
            return nil
        }
        guard file.schemaVersion <= SessionFile.currentSchemaVersion else {
            releaseLock()
            throw StoreError.newerVersion(key: key)
        }
        return file
    }

    /// Writes any pending save and releases the lock.
    public func close() throws {
        defer { releaseLock() }
        try flush()
    }

    // MARK: Saving

    /// Saves after a short pause, so a burst of keypresses becomes one write.
    public func scheduleSave(_ file: SessionFile) {
        guard key != nil else { return }
        pending = file
        guard flushTask == nil else { return }
        let delay = debounce
        flushTask = Task {
            do { try await Task.sleep(for: delay) } catch { return }
            self.flushDebounced()
        }
    }

    /// Saves now.
    public func save(_ file: SessionFile) throws {
        guard let key else { throw StoreError.notOpen }
        cancelPending()
        try write(Self.encoded(file), to: sessionURL(key))
    }

    /// Writes a pending save immediately, and reports any error from an earlier debounced save.
    public func flush() throws {
        flushTask?.cancel()
        flushTask = nil
        if let file = pending, let key {
            pending = nil
            try write(Self.encoded(file), to: sessionURL(key))
        }
        if let error = deferredError {
            deferredError = nil
            throw error
        }
    }

    /// Copies the session and its Apply journal to `Archive/<key>-<time>/`, then resets both (SR4 Start fresh).
    /// Archive files written for the old session stay where they are and are never removed later.
    public func startFresh() throws {
        guard let key else { throw StoreError.notOpen }
        cancelPending()
        let archive = directory.appendingPathComponent("Archive/\(key)-\(Self.timestamp())", isDirectory: true)
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
        for source in [sessionURL(key), ledgers.appendingPathComponent("\(key).jsonl")]
        where FileManager.default.fileExists(atPath: source.path) {
            try write(Data(contentsOf: source), to: archive.appendingPathComponent(source.lastPathComponent))
        }
        try write(Self.encoded(SessionFile.empty(key: key)), to: sessionURL(key))
        let ledger = ledgers.appendingPathComponent("\(key).jsonl")
        if FileManager.default.fileExists(atPath: ledger.path) { try write(Data(), to: ledger) }
    }

    // MARK: Internals

    private func sessionURL(_ key: String) -> URL { sessions.appendingPathComponent("\(key).json") }

    private func flushDebounced() {
        flushTask = nil
        guard let file = pending, let key else { return }
        pending = nil
        do { try write(Self.encoded(file), to: sessionURL(key)) } catch { deferredError = error }
    }

    private func cancelPending() {
        flushTask?.cancel()
        flushTask = nil
        pending = nil
    }

    private func releaseLock() {
        if lockDescriptor >= 0 { Darwin.close(lockDescriptor) }
        lockDescriptor = -1
        key = nil
        cancelPending()
    }

    /// Atomic replace, then force the file and its folder to the disk itself, not just the drive cache.
    private func write(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        for path in [url.path, url.deletingLastPathComponent().path] {
            let descriptor = Darwin.open(path, O_RDONLY | O_CLOEXEC)
            guard descriptor >= 0 else { throw StoreError.io("could not open \(path) to sync") }
            defer { Darwin.close(descriptor) }
            if fcntl(descriptor, F_FULLFSYNC) != 0 { throw StoreError.io("F_FULLFSYNC failed for \(path)") }
        }
    }

    private static func encoded(_ file: SessionFile) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(file)
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return formatter.string(from: Date())
    }
}

extension SessionFile {
    /// A valid session with no decisions, used when starting fresh or replacing a damaged file.
    static func empty(key: String) -> SessionFile {
        SessionFile(key: key, rootHint: "", session: CullSession(frameIDs: []), frames: [])
    }
}
