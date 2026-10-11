import Foundation

/// Everything the planner needs to know, gathered before it runs (DESIGN §5.7). The planner itself does no
/// I/O: the card snapshot, the journal and the archive listings are all handed to it.
public struct ApplyInput: Sendable {
    public struct Source: Sendable {
        /// The card's volume UUID, if it has one; used to refuse archiving a volume onto itself (SR8).
        public var volumeUUID: String?
        /// Only a camera card has files deleted for good; any other source has them moved to the Trash (SR8).
        public var isCameraCard: Bool
        /// The SD lock switch (R6).
        public var isReadOnly: Bool

        public init(volumeUUID: String?, isCameraCard: Bool, isReadOnly: Bool) {
            self.volumeUUID = volumeUUID
            self.isCameraCard = isCameraCard
            self.isReadOnly = isReadOnly
        }
    }

    /// What is in one trip folder right now, by exact on-disk name.
    public struct Listing: Sendable {
        /// Names in the trip folder itself (key nil) and in each of its subfolders.
        public var names: [String?: [String]]
        /// Files that carry the Favourite tag now, as paths inside the trip folder (`RAW/DSCF0001.RAF`).
        public var favourites: Set<String>

        public init(names: [String?: [String]] = [:], favourites: Set<String> = []) {
            self.names = names
            self.favourites = favourites
        }

        public func names(in subfolder: String?) -> [String] { names[subfolder] ?? [] }
    }

    // The fresh scan of the card (SR16).
    public var frames: [Frame]
    public var videos: [SourceFile]
    public var otherFiles: [SourceFile]
    /// Hidden and system items the scan skipped; counted in the "left on card" warning (SR13).
    public var skippedItems: Int
    public var marks: [FrameID: FrameMark]
    public var captureTimes: [FrameID: CaptureTime]
    /// The journal after recovery (executor step 1), so every reservation is settled.
    public var ledger: Ledger
    public var source: Source
    /// The trip folder chosen for new copies.
    public var destination: Ledger.Destination
    /// A listing for every destination that could be read: the chosen one if it exists, and each one the
    /// journal refers to. A destination with no listing is missing or its drive isn't connected.
    public var listings: [Ledger.Destination: Listing]
    public var freeBytes: Int64
    public var allocationSize: Int64
    /// Frames the owner asked to copy again after the final check found a file missing or changed (SR26).
    public var copyAgain: Set<Owner>

    public init(
        frames: [Frame], videos: [SourceFile] = [], otherFiles: [SourceFile] = [], skippedItems: Int = 0,
        marks: [FrameID: FrameMark], captureTimes: [FrameID: CaptureTime], ledger: Ledger = Ledger(), source: Source,
        destination: Ledger.Destination, listings: [Ledger.Destination: Listing] = [:], freeBytes: Int64,
        allocationSize: Int64, copyAgain: Set<Owner> = []
    ) {
        self.frames = frames
        self.videos = videos
        self.otherFiles = otherFiles
        self.skippedItems = skippedItems
        self.marks = marks
        self.captureTimes = captureTimes
        self.ledger = ledger
        self.source = source
        self.destination = destination
        self.listings = listings
        self.freeBytes = freeBytes
        self.allocationSize = allocationSize
        self.copyAgain = copyAgain
    }
}

/// What one Apply run will do, file by file (SR9). Nothing here has happened yet.
public struct ApplyPlan: Equatable, Sendable {
    public enum DestinationState: Equatable, Sendable {
        /// The trip folder doesn't exist; Apply creates it.
        case new
        /// FujiCull has written to this folder for this card before.
        case ours
        /// The folder exists and this card's journal doesn't know it; pre-flight asks before adding to it.
        case existsNotOurs
    }

    public struct Copy: Equatable, Sendable {
        public enum Source: Equatable, Sendable {
            case card(SourceFile)
            /// A Google Photos copy is made from the frame's archive JPG, which must still hash to what was
            /// read from the card.
            case archive(ArchiveLocation)
        }

        public let owner: Owner
        public let role: FileRole
        public let source: Source
        public let size: Int64
        public let to: ArchiveLocation
        /// The new file is created with exactly this tag state (SR12).
        public let favourite: Bool
    }

    public struct TagChange: Equatable, Sendable {
        public let location: ArchiveLocation
        /// True adds "Favourite"; false removes it.
        public let favourite: Bool
    }

    /// The archive files of a frame rejected after it was archived (D6, R26).
    public struct Removal: Equatable, Sendable {
        public let frame: FrameID
        public let files: [ArchiveLocation]
    }

    public struct CardDelete: Equatable, Sendable {
        public let frame: FrameID
        public let paths: [String]
    }

    public enum DeleteMode: Equatable, Sendable {
        case permanent
        case trash
    }

    public struct NotDeleted: Equatable, Sendable {
        public enum Reason: Equatable, Sendable {
            case cardLocked
            /// Without a capture time a frame can't be proven to be the one that was rejected (SR2).
            case noCaptureDate
        }

        public let frame: FrameID
        public let reason: Reason
    }

    public struct LeftOnCard: Equatable, Sendable {
        public var undecided: [FrameID] = []
        public var otherFiles: [String] = []
        public var skippedItems = 0
    }

    public var destinationState: DestinationState = .new
    public var copies: [Copy] = []
    /// Verified files replaced by a re-homed copy: they stay on the archive and are never removed (SR26).
    public var superseded: [ArchiveLocation] = []
    public var tagChanges: [TagChange] = []
    public var removals: [Removal] = []
    public var cardDeletes: [CardDelete] = []
    public var deleteMode: DeleteMode = .permanent
    public var notDeleted: [NotDeleted] = []
    public var leftOnCard = LeftOnCard()
    /// Destinations the journal refers to that couldn't be listed. Card deletion isn't offered while any
    /// is unreachable (SR17).
    public var unreachableDestinations: [Ledger.Destination] = []
    /// Space the copies need on the archive, including the margin (SR14).
    public var requiredBytes: Int64 = 0
}

/// Why a plan can't be made at all.
public enum ApplyError: Error, Equatable, Sendable {
    case invalidTripName(TripName.Problem)
    /// The card and the archive are the same volume (SR8).
    case sameVolume
    /// A folder holds entries whose names differ only by case, so "is this name taken" has no single
    /// answer. Apply stops and asks (SR10).
    case ambiguousNames([String])
    case insufficientSpace(needed: Int64, available: Int64)
}

/// The rules a trip folder's name must meet to be safe on exFAT and readable on Windows (DESIGN §5.7).
public enum TripName {
    public enum Problem: Equatable, Sendable {
        case empty
        case forbiddenCharacter
        case startsOrEndsWithSpaceOrDot
        case reserved
        case tooLong
    }

    public static func problem(with name: String) -> Problem? {
        if name.isEmpty { return .empty }
        if name.unicodeScalars.contains(where: {
            $0.value < 0x20 || $0.value == 0x7F || "\"*/:<>?\\|".unicodeScalars.contains($0)
        }) {
            return .forbiddenCharacter
        }
        if let first = name.first, let last = name.last, " .".contains(first) || " .".contains(last) {
            return .startsOrEndsWithSpaceOrDot
        }
        let upper = name.uppercased()
        let stem =
            upper.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? upper
        let devices = ["CON", "PRN", "AUX", "NUL"] + (1...9).flatMap { ["COM\($0)", "LPT\($0)"] }
        if devices.contains(stem) || upper == "SYSTEM VOLUME INFORMATION" { return .reserved }
        if name.utf16.count > 200 { return .tooLong }
        return nil
    }
}
