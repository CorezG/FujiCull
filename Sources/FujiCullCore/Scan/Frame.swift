import Foundation

/// Stable identity of a frame: its path relative to the identity base (the volume root for a card),
/// without extension for a pair or a lone file, or with the exact filename for a split orphan (SR2).
public struct FrameID: Hashable, Comparable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: String

    public init(_ rawValue: String) { self.rawValue = rawValue }

    public var description: String { rawValue }

    // Stored as a plain string in session and ledger files.
    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public static func < (lhs: FrameID, rhs: FrameID) -> Bool {
        NaturalSortKey(lhs.rawValue) < NaturalSortKey(rhs.rawValue)
    }
}

/// One file as the scan saw it. `size` and `modified` are the snapshot Apply re-checks before deleting.
public struct SourceFile: Hashable, Sendable, Codable {
    /// Path relative to the identity base, with `/` separators and the exact on-disk case.
    public let relativePath: String
    public let size: Int64
    public let modified: Date

    public init(relativePath: String, size: Int64, modified: Date) {
        self.relativePath = relativePath
        self.size = size
        self.modified = modified
    }

    /// The containing folder relative to the identity base, or "" at the base itself.
    var folder: String {
        guard let slash = relativePath.lastIndex(of: "/") else { return "" }
        return String(relativePath[..<slash])
    }

    var filename: String {
        guard let slash = relativePath.lastIndex(of: "/") else { return relativePath }
        return String(relativePath[relativePath.index(after: slash)...])
    }

    var stem: String {
        let name = filename
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return name }
        return String(name[..<dot])
    }

    var lowercasedExtension: String {
        let name = filename
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return "" }
        return name[name.index(after: dot)...].lowercased()
    }
}

/// One cull decision unit: a JPG and RAF with the same name in the same folder, or a single file (R2–R4).
public struct Frame: Hashable, Sendable, Identifiable {
    public let id: FrameID
    /// nil for a RAF-only frame.
    public let jpg: SourceFile?
    /// nil for a JPG-only frame.
    public let raf: SourceFile?

    public var isUnpaired: Bool { jpg == nil || raf == nil }
}

/// Everything a scan found, in cull order (DESIGN §5.1).
public struct ScanResult: Sendable {
    public let frames: [Frame]
    /// `.MOV` / `.MP4` files: never culled, archived to `Videos/` (R27).
    public let videos: [SourceFile]
    /// Every other regular file: listed as left on the card (SR13).
    public let otherFiles: [SourceFile]
}
