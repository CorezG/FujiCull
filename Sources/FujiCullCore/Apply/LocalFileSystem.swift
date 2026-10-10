import Foundation

/// The real file system, through POSIX calls relative to an open folder (SR7).
public struct LocalFileSystem: FileSystem {
    public init() {}

    public func openFolder(at path: String) throws(FileSystemError) -> OpenFolder {
        let descriptor = open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        try Self.check(descriptor >= 0, .openFolder, path)
        return OpenFolder(path: path, descriptor: descriptor)
    }

    public func volumeUUID(of folder: OpenFolder) throws(FileSystemError) -> String? {
        var request = attrlist()
        request.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        request.volattr = attrgroup_t(ATTR_VOL_INFO) | attrgroup_t(ATTR_VOL_UUID)
        // The reply is a 4-byte length, then the 16-byte UUID.
        var reply = [UInt8](repeating: 0, count: 20)
        if fgetattrlist(folder.descriptor, &request, &reply, reply.count, 0) != 0 {
            // A volume with no UUID answers "invalid argument" (measured on a camera-formatted FAT32 card).
            try Self.check(errno == EINVAL, .volumeUUID, folder.path)
            return nil
        }
        return NSUUID(uuidBytes: Array(reply[4...])).uuidString
    }

    public func entry(_ name: String, in folder: OpenFolder) throws(FileSystemError) -> EntryInfo? {
        var info = stat()
        if fstatat(folder.descriptor, name, &info, AT_SYMLINK_NOFOLLOW) != 0 {
            try Self.check(errno == ENOENT, .entry, name)
            return nil
        }
        let modified = Date(
            timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec) + TimeInterval(info.st_mtimespec.tv_nsec)
                / 1e9)
        return EntryInfo(size: Int64(info.st_size), modified: modified, isRegularFile: info.st_mode & S_IFMT == S_IFREG)
    }

    public func createExclusively(
        _ name: String, in folder: OpenFolder, uncached: Bool
    ) throws(FileSystemError) -> OpenFile {
        let descriptor = openat(folder.descriptor, name, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o644)
        try Self.check(descriptor >= 0, .create, name)
        let file = OpenFile(name: name, descriptor: descriptor)
        if uncached { try Self.check(fcntl(descriptor, F_NOCACHE, 1) == 0, .create, name) }
        return file
    }

    public func openForReading(_ path: String, in folder: OpenFolder) throws(FileSystemError) -> OpenFile {
        let descriptor = openat(folder.descriptor, path, O_RDONLY | O_CLOEXEC)
        try Self.check(descriptor >= 0, .openForReading, path)
        return OpenFile(name: path, descriptor: descriptor)
    }

    public func read(_ file: OpenFile, upTo count: Int) throws(FileSystemError) -> Data {
        var buffer = [UInt8](repeating: 0, count: count)
        var got = Darwin.read(file.descriptor, &buffer, count)
        while got < 0 && errno == EINTR { got = Darwin.read(file.descriptor, &buffer, count) }
        try Self.check(got >= 0, .read, file.name)
        return Data(buffer[..<got])
    }

    public func write(_ data: Data, to file: OpenFile) throws(FileSystemError) {
        var written = 0
        while written < data.count {
            let count = data.withUnsafeBytes { bytes in
                Darwin.write(file.descriptor, bytes.baseAddress.map { $0 + written }, bytes.count - written)
            }
            if count < 0 && errno == EINTR { continue }
            try Self.check(count >= 0, .write, file.name)
            written += count
        }
    }

    public func syncToDevice(_ file: OpenFile) throws(FileSystemError) {
        try Self.check(fcntl(file.descriptor, F_FULLFSYNC) != -1, .syncFile, file.name)
    }

    public func syncToDevice(_ folder: OpenFolder) throws(FileSystemError) {
        try Self.check(fcntl(folder.descriptor, F_FULLFSYNC) != -1, .syncFolder, folder.path)
    }

    public func setModified(_ date: Date, of name: String, in folder: OpenFolder) throws(FileSystemError) {
        let seconds = date.timeIntervalSince1970.rounded(.down)
        let nanoseconds = ((date.timeIntervalSince1970 - seconds) * 1e9).rounded()
        // Leave the access time alone; set the modification time.
        let times = [
            timespec(tv_sec: 0, tv_nsec: Int(UTIME_OMIT)), timespec(tv_sec: Int(seconds), tv_nsec: Int(nanoseconds)),
        ]
        try Self.check(utimensat(folder.descriptor, name, times, AT_SYMLINK_NOFOLLOW) == 0, .setModified, name)
    }

    public func rename(_ name: String, to newName: String, in folder: OpenFolder) throws(FileSystemError) {
        try Self.check(renameat(folder.descriptor, name, folder.descriptor, newName) == 0, .rename, name)
    }

    public func remove(_ name: String, in folder: OpenFolder) throws(FileSystemError) {
        try Self.check(unlinkat(folder.descriptor, name, 0) == 0, .remove, name)
    }

    /// Throws the current `errno` as a `FileSystemError` unless `succeeded`.
    private static func check(_ succeeded: Bool, _ operation: FileOperation, _ name: String) throws(FileSystemError) {
        if !succeeded { throw FileSystemError(operation: operation, name: name, code: errno) }
    }
}
