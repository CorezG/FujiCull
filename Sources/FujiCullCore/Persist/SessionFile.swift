/// One saved frame: its identity (SR2) and its mark. Only frames that aren't plain Undecided are saved.
public struct StoredFrame: Codable, Equatable, Sendable {
    public let id: FrameID
    /// Exact sizes of the frame's files when it was decided; nil for a file the frame doesn't have.
    public let jpgSize: Int64?
    public let rafSize: Int64?
    /// When the photo was taken, once its EXIF has been read; nil before that, and in version 1 files.
    public let captureTime: CaptureTime?
    public let mark: FrameMark

    public init(id: FrameID, jpgSize: Int64?, rafSize: Int64?, captureTime: CaptureTime?, mark: FrameMark) {
        self.id = id
        self.jpgSize = jpgSize
        self.rafSize = rafSize
        self.captureTime = captureTime
        self.mark = mark
    }
}

/// What `SessionStore` writes to `Sessions/<key>.json` (DESIGN §5.3). About 100–200 KB for 2,000 frames.
public struct SessionFile: Codable, Equatable, Sendable {
    /// Version 2 added each frame's capture time (SR2). Version 1 files still open.
    public static let currentSchemaVersion = 2

    public var schemaVersion: Int
    public var key: String
    /// Where the source was last seen, for messages only; identity comes from `key` and the frames.
    public var rootHint: String
    public var cursorFrameID: FrameID?
    public var undecidedOnly: Bool
    /// Sorted by FrameID, so saves of the same state are byte-identical.
    public var frames: [StoredFrame]

    /// `captureTimes` holds what is known so far; a frame missing from it is saved without one.
    public init(
        key: String, rootHint: String, session: CullSession, frames scanned: [Frame],
        captureTimes: [FrameID: CaptureTime] = [:]
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.key = key
        self.rootHint = rootHint
        self.cursorFrameID = session.frameIDs.indices.contains(session.cursor) ? session.frameIDs[session.cursor] : nil
        self.undecidedOnly = session.undecidedOnly
        let byID = Dictionary(scanned.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        self.frames = session.storedMarks.compactMap { id, mark in
            guard let frame = byID[id] else { return nil }
            return StoredFrame(
                id: id, jpgSize: frame.jpg?.size, rafSize: frame.raf?.size, captureTime: captureTimes[id], mark: mark)
        }
        .sorted { $0.id < $1.id }
    }
}

/// The result of matching a saved session to what's on the card now (SR4).
public enum RestoreOutcome: Equatable, Sendable {
    /// Nothing saved for this card.
    case none
    /// Every saved decision still belongs to a frame on the card: restore silently.
    case full(CullSession)
    /// Only `matched` of the `expected` saved decisions still fit. The app asks: Resume (use `resumed`,
    /// which keeps just the matching decisions) or Start fresh.
    case partial(matched: Int, expected: Int, resumed: CullSession)
}

public enum SessionRestore {
    /// Whether a restored decision really belongs to the scanned frame, now that the frame's capture time
    /// has been read (SR2). Path and sizes can repeat after a card is formatted and refilled; the moment a
    /// photo was taken doesn't. With no capture time on either side there is no proof, so it doesn't bind.
    ///
    /// Files from schema 1 never recorded capture times; their decisions are accepted this once, and the
    /// next save records the times.
    public static func binds(_ stored: StoredFrame, to scanned: CaptureTime?, savedBySchema schema: Int) -> Bool {
        guard let scanned else { return false }
        guard let saved = stored.captureTime else { return schema < 2 }
        return saved == scanned
    }

    /// Matches `file` to the scanned `frames` by FrameID and the exact size of each file, which is all a
    /// scan knows. `binds` then confirms each match as capture times are read (SR2). Frames whose files
    /// Apply deleted are expected to be gone and don't count (SR4).
    public static func match(
        _ file: SessionFile?, to frames: [Frame], deletedByApply: Set<FrameID> = []
    ) -> RestoreOutcome {
        guard let file else { return .none }
        let scanned = Dictionary(frames.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var marks: [FrameID: FrameMark] = [:]
        var expected = 0
        for stored in file.frames where !deletedByApply.contains(stored.id) {
            expected += 1
            if let frame = scanned[stored.id], frame.jpg?.size == stored.jpgSize, frame.raf?.size == stored.rafSize {
                marks[stored.id] = stored.mark
            }
        }
        let session = CullSession(
            frameIDs: frames.map(\.id), marks: marks, cursor: file.cursorFrameID, undecidedOnly: file.undecidedOnly)
        return marks.count == expected
            ? .full(session) : .partial(matched: marks.count, expected: expected, resumed: session)
    }
}
