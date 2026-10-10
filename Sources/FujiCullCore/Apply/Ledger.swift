import Foundation

/// Which of a frame's files an archive file is. `raw` is the camera's raw file (a RAF today).
public enum FileRole: String, Codable, Sendable, CaseIterable {
    case raw
    case jpg
    case googlePhotos
    case video
}

/// Whose file it is: a frame (by FrameID) or a video (by its path on the card).
public struct Owner: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case frame
        case video
    }

    public let kind: Kind
    public let id: String

    public static func frame(_ id: FrameID) -> Owner { Owner(kind: .frame, id: id.rawValue) }
    public static func video(_ path: String) -> Owner { Owner(kind: .video, id: path) }
}

/// Where a file FujiCull wrote lives. Every record names its destination in full, so keepers filed under
/// an earlier trip folder, or on another archive drive, are still found (DESIGN §5.7, Destinations).
public struct ArchiveLocation: Codable, Hashable, Sendable {
    public let volumeUUID: String
    /// The trip folder's exact on-disk name.
    public let folder: String
    /// nil for the trip folder itself, else `Google Photos` or `Videos`.
    public let subfolder: String?
    public let name: String

    public init(volumeUUID: String, folder: String, subfolder: String? = nil, name: String) {
        self.volumeUUID = volumeUUID
        self.folder = folder
        self.subfolder = subfolder
        self.name = name
    }
}

/// What a card file was when it was copied. A record binds to a file on the card only if these still
/// match (SR2).
public struct SourceIdentity: Codable, Hashable, Sendable {
    public let path: String
    public let size: Int64
    public let modified: Date
    public let captureTime: CaptureTime?
    public let sha256: String

    public init(path: String, size: Int64, modified: Date, captureTime: CaptureTime?, sha256: String) {
        self.path = path
        self.size = size
        self.modified = modified
        self.captureTime = captureTime
        self.sha256 = sha256
    }
}

/// One line of a card's Apply journal (SR15). One record per file per operation; destructive operations
/// are bracketed by an intent before and an outcome after (SR25).
public enum LedgerRecord: Codable, Equatable, Sendable {
    /// The trip folder chosen for new copies.
    case destination(volumeUUID: String, folder: String)
    /// Written before the file is created.
    case reserve(owner: Owner, role: FileRole, location: ArchiveLocation, partial: String)
    /// Written only after the data and the rename are durable.
    case verified(
        owner: Owner, role: FileRole, location: ArchiveLocation, source: SourceIdentity, size: Int64, sha256: String)
    /// A reservation abandoned during recovery.
    case released(location: ArchiveLocation)
    /// A verified file replaced by a re-homed copy (SR26). It stays on the archive and is never removed.
    case superseded(location: ArchiveLocation)
    case tagged(location: ArchiveLocation)
    case untagged(location: ArchiveLocation)
    case trashing(location: ArchiveLocation)
    case trashed(location: ArchiveLocation, trashPath: String?)
    case deleting(path: String)
    case deleted(path: String)
}

/// What the journal's records add up to. Records fall into three families, and the latest record within a
/// family is authoritative: an archive file's state, its tag, and a card file's state.
///
/// The rules are strict in the safe direction. A record that doesn't follow from the one before it (a
/// `verified` with no `reserve`, a `trashed` with no `trashing`) is ignored, so it can never make a file
/// that isn't provably FujiCull's look removable.
public struct Ledger: Equatable, Sendable {
    /// A trip folder on an archive volume.
    public struct Destination: Hashable, Sendable {
        public let volumeUUID: String
        public let folder: String

        public init(volumeUUID: String, folder: String) {
            self.volumeUUID = volumeUUID
            self.folder = folder
        }
    }

    public struct ArchiveFile: Equatable, Sendable {
        public enum Status: Equatable, Sendable {
            /// Named, perhaps partly written; not yet proven.
            case reserved
            case verified
            case released
            case superseded
            /// About to be moved to the Trash, or moved without the outcome being recorded.
            case trashing
            case trashed
        }

        public let location: ArchiveLocation
        public let owner: Owner
        public let role: FileRole
        public let partial: String
        public fileprivate(set) var status: Status
        public fileprivate(set) var source: SourceIdentity?
        public fileprivate(set) var size: Int64?
        public fileprivate(set) var sha256: String?
        public fileprivate(set) var trashPath: String?
        /// True when FujiCull set the Favourite tag on this file, so FujiCull may remove it (SR12).
        public fileprivate(set) var taggedByUs = false
        /// Position of this file's reservation among all reservations: a larger number was reserved later.
        public fileprivate(set) var sequence = 0

        public var destination: Destination { Destination(volumeUUID: location.volumeUUID, folder: location.folder) }
    }

    public enum CardFileStatus: Equatable, Sendable {
        case deleting
        case deleted
    }

    public private(set) var chosenDestination: Destination?
    private var files: [ArchiveLocation: ArchiveFile] = [:]
    /// Locations in the order they were first reserved, so listings are stable.
    private var order: [ArchiveLocation] = []
    private var cardFiles: [String: CardFileStatus] = [:]
    private var reservations = 0

    public init(_ records: [LedgerRecord] = []) {
        for record in records { self.record(record) }
    }

    // MARK: Reading

    public func file(at location: ArchiveLocation) -> ArchiveFile? { files[location] }

    /// Every archive file on record, in the order first reserved.
    public var allFiles: [ArchiveFile] { order.compactMap { files[$0] } }

    public func files(of owner: Owner) -> [ArchiveFile] { allFiles.filter { $0.owner == owner } }

    public func cardFileStatus(_ path: String) -> CardFileStatus? { cardFiles[path] }

    /// Reservations with no outcome: a copy that was interrupted. Recovery settles each one (SR25).
    public var openReservations: [ArchiveFile] { allFiles.filter { $0.status == .reserved } }

    /// Trash moves with no recorded outcome.
    public var unsettledTrashes: [ArchiveFile] { allFiles.filter { $0.status == .trashing } }

    /// Card deletions with no recorded outcome.
    public var unsettledDeletes: [String] { cardFiles.filter { $0.value == .deleting }.keys.sorted() }

    // MARK: Binding (SR2)

    /// Among `candidates` (one owner's files), the archive file the journal proves FujiCull wrote for
    /// exactly this card file, if there is one and it is still current. `trashing` counts: the move was
    /// planned, but the file is still there.
    public func boundFile(
        among candidates: [ArchiveFile], role: FileRole, to file: SourceFile, captured: CaptureTime?
    ) -> ArchiveFile? {
        // A path with a `deleted` record is a closed chapter: whatever is there now is a new file.
        guard cardFileStatus(file.relativePath) != .deleted else { return nil }
        return candidates.last { candidate in
            guard candidate.role == role, candidate.status == .verified || candidate.status == .trashing,
                let source = candidate.source, source.path == file.relativePath, source.size == file.size
            else { return false }
            // The moment the photo was taken settles it. With no capture time on either side (videos, or a
            // JPG without EXIF) the file's own date stands in.
            if source.captureTime != nil || captured != nil { return source.captureTime == captured }
            return source.modified == file.modified
        }
    }

    // MARK: Folding in a record

    public mutating func record(_ record: LedgerRecord) {
        switch record {
        case .destination(let volumeUUID, let folder):
            chosenDestination = Destination(volumeUUID: volumeUUID, folder: folder)
        case .reserve(let owner, let role, let location, let partial):
            if files[location] == nil { order.append(location) }
            reservations += 1
            files[location] = ArchiveFile(
                location: location, owner: owner, role: role, partial: partial, status: .reserved,
                sequence: reservations)
        case .verified(let owner, let role, let location, let source, let size, let sha256):
            // Only the frame that reserved the name can verify it.
            guard let file = files[location], file.status == .reserved, file.owner == owner, file.role == role
            else { return }
            files[location]?.status = .verified
            files[location]?.source = source
            files[location]?.size = size
            files[location]?.sha256 = sha256
        case .released(let location):
            move(location, from: .reserved, to: .released)
        case .superseded(let location):
            move(location, from: .verified, to: .superseded)
        case .trashing(let location):
            move(location, from: .verified, to: .trashing)
        case .trashed(let location, let trashPath):
            if move(location, from: .trashing, to: .trashed) { files[location]?.trashPath = trashPath }
        case .tagged(let location):
            files[location]?.taggedByUs = true
        case .untagged(let location):
            files[location]?.taggedByUs = false
        case .deleting(let path):
            cardFiles[path] = .deleting
        case .deleted(let path):
            cardFiles[path] = .deleted
        }
    }

    @discardableResult
    private mutating func move(
        _ location: ArchiveLocation, from: ArchiveFile.Status, to: ArchiveFile.Status
    ) -> Bool {
        guard files[location]?.status == from else { return false }
        files[location]?.status = to
        return true
    }
}
