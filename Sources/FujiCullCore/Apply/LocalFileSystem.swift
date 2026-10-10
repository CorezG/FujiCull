import Foundation

/// The real file system, through POSIX calls relative to an open folder (SR7).
public struct LocalFileSystem: FileSystem {
    public init() {}

    public func openFolder(at path: String) throws(FileSystemError) -> OpenFolder {
        let descriptor = open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        try Self.check(descriptor >= 0, .openFolder, path)
        return OpenFolder(path: path, descriptor: descriptor)
    }

    public func openFolder(_ name: String, in folder: OpenFolder) throws(FileSystemError) -> OpenFolder {
        let descriptor = openat(folder.descriptor, name, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        try Self.check(descriptor >= 0, .openFolder, name)
        return OpenFolder(path: folder.path + "/" + name, descriptor: descriptor)
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
        return EntryInfo(
            size: Int64(info.st_size), modified: modified, isRegularFile: info.st_mode & S_IFMT == S_IFREG,
            isImmutable: info.st_flags & UInt32(UF_IMMUTABLE | SF_IMMUTABLE) != 0)
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

    public func createFolder(_ name: String, in folder: OpenFolder) throws(FileSystemError) {
        try Self.check(mkdirat(folder.descriptor, name, 0o755) == 0, .createFolder, name)
    }

    public func names(in folder: OpenFolder) throws(FileSystemError) -> [String] {
        // A second descriptor, because closing the directory stream closes the descriptor it was given.
        let copy = dup(folder.descriptor)
        try Self.check(copy >= 0, .list, folder.path)
        guard let stream = fdopendir(copy) else { throw Self.closing(copy, .list, folder.path) }
        defer { closedir(stream) }
        rewinddir(stream)
        var names: [String] = []
        while let entry = readdir(stream) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) { String(cString: $0) }
            }
            if name != "." && name != ".." { names.append(name) }
        }
        return names
    }

    public func volumeSpace(of folder: OpenFolder) throws(FileSystemError) -> VolumeSpace {
        var info = statfs()
        try Self.check(fstatfs(folder.descriptor, &info) == 0, .volumeSpace, folder.path)
        return VolumeSpace(
            freeBytes: Int64(info.f_bavail) * Int64(info.f_bsize), allocationSize: Int64(info.f_bsize))
    }

    public func tags(of name: String, in folder: OpenFolder) throws(FileSystemError) -> Set<String> {
        let url = try Self.url(of: name, in: folder, for: .readTags)
        return try Self.foundation(.readTags, name) {
            Set(try url.resourceValues(forKeys: [.tagNamesKey]).tagNames ?? [])
        }
    }

    public func setTags(_ tags: Set<String>, of name: String, in folder: OpenFolder) throws(FileSystemError) {
        let url = try Self.url(of: name, in: folder, for: .writeTags)
        try Self.foundation(.writeTags, name) {
            try (url as NSURL).setResourceValue(tags.sorted(), forKey: .tagNamesKey)
        }
    }

    public func moveToTrash(_ name: String, in folder: OpenFolder) throws(FileSystemError) -> String? {
        let url = try Self.url(of: name, in: folder, for: .trash)
        return try Self.foundation(.trash, name) {
            var result: NSURL?
            try FileManager.default.trashItem(at: url, resultingItemURL: &result)
            return result?.path
        }
    }

    /// Tags and the Trash take a path, not a descriptor. This builds the path from where the open folder
    /// is **now**, and confirms it names the very file the folder sees, so a mount point that changed
    /// underneath can't redirect the call to another volume (SR7).
    private static func url(
        of name: String, in folder: OpenFolder, for operation: FileOperation
    ) throws(FileSystemError) -> URL {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        try check(fcntl(folder.descriptor, F_GETPATH, &buffer) == 0, operation, name)
        let path = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self) + "/" + name
        var viaFolder = stat()
        var viaPath = stat()
        try check(fstatat(folder.descriptor, name, &viaFolder, AT_SYMLINK_NOFOLLOW) == 0, operation, name)
        try check(lstat(path, &viaPath) == 0, operation, name)
        let same = viaFolder.st_dev == viaPath.st_dev && viaFolder.st_ino == viaPath.st_ino
        guard same else { throw FileSystemError(operation: operation, name: name, code: ESTALE) }
        return URL(fileURLWithPath: path)
    }

    /// Runs a Foundation call, reporting its failure as a `FileSystemError` with the underlying POSIX
    /// code when there is one.
    private static func foundation<T>(
        _ operation: FileOperation, _ name: String, _ body: () throws -> T
    ) throws(FileSystemError) -> T {
        do {
            return try body()
        } catch {
            let underlying = (error as NSError).userInfo[NSUnderlyingErrorKey] as? NSError
            let code = underlying?.domain == NSPOSIXErrorDomain ? Int32(underlying?.code ?? 0) : EIO
            throw FileSystemError(operation: operation, name: name, code: code == 0 ? EIO : code)
        }
    }

    private static func closing(_ descriptor: Int32, _ operation: FileOperation, _ name: String) -> FileSystemError {
        let code = errno
        _ = close(descriptor)
        return FileSystemError(operation: operation, name: name, code: code)
    }

    /// Throws the current `errno` as a `FileSystemError` unless `succeeded`.
    private static func check(_ succeeded: Bool, _ operation: FileOperation, _ name: String) throws(FileSystemError) {
        if !succeeded { throw FileSystemError(operation: operation, name: name, code: errno) }
    }
}
