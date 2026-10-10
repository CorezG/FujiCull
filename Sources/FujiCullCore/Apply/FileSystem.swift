import Foundation

/// What a file-system call was doing when it failed. Used in messages, and by tests to inject faults.
public enum FileOperation: String, Sendable, CaseIterable {
    case openFolder
    case volumeUUID
    case entry
    case create
    case openForReading
    case read
    case write
    case syncFile
    case syncFolder
    case setModified
    case rename
    case remove
    case createFolder
    case list
    case volumeSpace
    case readTags
    case writeTags
    case trash
}

/// A failed file-system call: what was attempted, on which name, and the `errno` it gave.
public struct FileSystemError: Error, Equatable, Sendable {
    public let operation: FileOperation
    public let name: String
    public let code: Int32

    public init(operation: FileOperation, name: String, code: Int32) {
        self.operation = operation
        self.name = name
        self.code = code
    }

    public var alreadyExists: Bool { code == EEXIST }
}

/// An open folder. Apply names every file relative to one of these, never by full path, so nothing can
/// land on another volume if a mount point changes underneath it (SR7). Closed when released.
public final class OpenFolder: Sendable {
    /// For messages only.
    public let path: String
    let descriptor: Int32

    init(path: String, descriptor: Int32) {
        self.path = path
        self.descriptor = descriptor
    }

    deinit { _ = close(descriptor) }
}

/// An open file. Closed when released.
public final class OpenFile: Sendable {
    /// For messages only.
    public let name: String
    let descriptor: Int32

    init(name: String, descriptor: Int32) {
        self.name = name
        self.descriptor = descriptor
    }

    deinit { _ = close(descriptor) }
}

/// What a folder says about one of its entries.
public struct EntryInfo: Equatable, Sendable {
    public let size: Int64
    public let modified: Date
    public let isRegularFile: Bool

    public init(size: Int64, modified: Date, isRegularFile: Bool) {
        self.size = size
        self.modified = modified
        self.isRegularFile = isRegularFile
    }
}

/// The file operations Apply is built from (DESIGN §5.7). `LocalFileSystem` performs them; tests wrap it
/// in a double that makes any chosen call fail, so every failure path can be exercised.
public protocol FileSystem: Sendable {
    func openFolder(at path: String) throws(FileSystemError) -> OpenFolder

    /// Opens a folder inside an open folder, by name.
    func openFolder(_ name: String, in folder: OpenFolder) throws(FileSystemError) -> OpenFolder

    /// The UUID of the volume the folder is on, read from the open folder itself; nil if the volume has
    /// none (a FAT32 card formatted in the camera doesn't).
    func volumeUUID(of folder: OpenFolder) throws(FileSystemError) -> String?

    /// The entry called `name`, or nil if the volume says there isn't one. The volume decides what counts
    /// as the same name (SR10).
    func entry(_ name: String, in folder: OpenFolder) throws(FileSystemError) -> EntryInfo?

    /// Creates `name` for writing, failing with `alreadyExists` if the volume already has that name.
    /// `uncached` keeps the written data out of the system cache, so a later read comes from the device.
    func createExclusively(_ name: String, in folder: OpenFolder, uncached: Bool) throws(FileSystemError) -> OpenFile

    /// Opens `path`, which may contain subfolders, for reading.
    func openForReading(_ path: String, in folder: OpenFolder) throws(FileSystemError) -> OpenFile

    /// Up to `count` bytes from the file's current position; empty at the end of the file.
    func read(_ file: OpenFile, upTo count: Int) throws(FileSystemError) -> Data

    /// Appends all of `data`.
    func write(_ data: Data, to file: OpenFile) throws(FileSystemError)

    /// Makes the file's data durable on the device (`F_FULLFSYNC`).
    func syncToDevice(_ file: OpenFile) throws(FileSystemError)

    /// Makes the folder's entries (names, sizes, dates) durable on the device.
    func syncToDevice(_ folder: OpenFolder) throws(FileSystemError)

    func setModified(_ date: Date, of name: String, in folder: OpenFolder) throws(FileSystemError)

    /// Renames within the folder. Replaces an existing `newName`, so callers claim the name first (SR10).
    func rename(_ name: String, to newName: String, in folder: OpenFolder) throws(FileSystemError)

    /// Permanently removes a file.
    func remove(_ name: String, in folder: OpenFolder) throws(FileSystemError)

    /// Creates a folder, failing with `alreadyExists` if the volume already has that name (SR10).
    func createFolder(_ name: String, in folder: OpenFolder) throws(FileSystemError)

    /// Every name in the folder, as stored, including hidden ones.
    func names(in folder: OpenFolder) throws(FileSystemError) -> [String]

    /// Free space on the folder's volume and the size of one allocation unit (SR14).
    func volumeSpace(of folder: OpenFolder) throws(FileSystemError) -> VolumeSpace

    /// The file's Finder tags.
    func tags(of name: String, in folder: OpenFolder) throws(FileSystemError) -> Set<String>

    func setTags(_ tags: Set<String>, of name: String, in folder: OpenFolder) throws(FileSystemError)

    /// Moves a file to its own volume's Trash and returns where it went, if known. It is never deleted
    /// instead: if the move fails, this throws and the file stays (SR18).
    func moveToTrash(_ name: String, in folder: OpenFolder) throws(FileSystemError) -> String?
}

public struct VolumeSpace: Equatable, Sendable {
    public let freeBytes: Int64
    public let allocationSize: Int64

    public init(freeBytes: Int64, allocationSize: Int64) {
        self.freeBytes = freeBytes
        self.allocationSize = allocationSize
    }
}
