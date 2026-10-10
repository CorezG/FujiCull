import CryptoKit
import Foundation

/// Copies one file onto the archive and proves the copy before giving it its final name (DESIGN §5.7,
/// executor step 2). Either the final file is there, complete and verified, or nothing this call created
/// is left behind.
public enum SafeCopy {
    public struct Request: Sendable {
        public var sourceFolder: OpenFolder
        /// Relative to `sourceFolder`.
        public var sourcePath: String
        /// The size the scan saw; a different number of bytes means the file changed under us (SR16).
        public var expectedSize: Int64
        /// Set when the source must be a known file: a Google Photos copy is made from the archive JPG only
        /// if it still hashes to what was read from the card.
        public var expectedSHA256: String?
        public var destination: OpenFolder
        public var finalName: String
        /// The modification date to give the copy (the source's).
        public var modified: Date
        public var chunkSize: Int

        public init(
            sourceFolder: OpenFolder, sourcePath: String, expectedSize: Int64, expectedSHA256: String? = nil,
            destination: OpenFolder, finalName: String, modified: Date, chunkSize: Int = 8 * 1024 * 1024
        ) {
            self.sourceFolder = sourceFolder
            self.sourcePath = sourcePath
            self.expectedSize = expectedSize
            self.expectedSHA256 = expectedSHA256
            self.destination = destination
            self.finalName = finalName
            self.modified = modified
            self.chunkSize = chunkSize
        }
    }

    public struct Result: Equatable, Sendable {
        /// Lower-case hex.
        public let sha256: String
        public let size: Int64
    }

    public enum Reason: Error, Equatable, Sendable {
        case cancelled
        /// The volume already has an entry with this name (SR10). Nothing was overwritten.
        case nameTaken(String)
        case sourceChanged(expectedSize: Int64, actualSize: Int64)
        /// The source doesn't hash to `expectedSHA256`.
        case sourceMismatch
        /// What was read back from the destination isn't what was read from the source.
        case verificationFailed
        case io(FileSystemError)
    }

    public struct Failure: Error, Equatable, Sendable {
        public let reason: Reason
        /// Names this call created in the destination and couldn't remove, because the drive had gone.
        /// The next run's recovery deals with them (DESIGN §5.7, executor step 1).
        public let leftBehind: [String]
    }

    /// The temporary name a file is written under. Only FujiCull uses this pattern.
    public static func partialName(for finalName: String) -> String {
        ".\(finalName).fujicull-partial"
    }

    public static func copy(
        _ request: Request, using fs: some FileSystem, isCancelled: () -> Bool = { Task.isCancelled }
    ) throws(Failure) -> Result {
        // Names this call creates in the destination, so a failure can remove exactly those and nothing else.
        var created: [String] = []
        do {
            return try run(request, fs, isCancelled, &created)
        } catch {
            throw Failure(reason: error, leftBehind: cleanUp(created, in: request.destination, fs))
        }
    }

    private static func run(
        _ request: Request, _ fs: some FileSystem, _ isCancelled: () -> Bool, _ created: inout [String]
    ) throws(Reason) -> Result {
        let partial = partialName(for: request.finalName)
        let folder = request.destination

        let written = try writePartial(request, partial, fs, isCancelled, &created)
        guard written.size == request.expectedSize else {
            throw .sourceChanged(expectedSize: request.expectedSize, actualSize: written.size)
        }
        if let expected = request.expectedSHA256, expected != written.sha256 { throw .sourceMismatch }

        // The first read of the partial. It was written uncached, so these bytes come from the device.
        let readBack = try io(try fs.openForReading(partial, in: folder))
        var check = SHA256()
        while true {
            if isCancelled() { throw .cancelled }
            let chunk = try io(try fs.read(readBack, upTo: request.chunkSize))
            if chunk.isEmpty { break }
            check.update(data: chunk)
        }
        guard hex(check.finalize()) == written.sha256 else { throw .verificationFailed }

        try io(try fs.setModified(request.modified, of: partial, in: folder))

        // Claim the final name with an empty file of our own, then rename over it. The volume has no
        // "rename only if free" (measured), and this way the rename can only ever replace our placeholder.
        _ = try claim(request.finalName, in: folder, fs, uncached: false)
        created.append(request.finalName)
        try io(try fs.rename(partial, to: request.finalName, in: folder))
        try io(try fs.syncToDevice(folder))

        let final = try io(try fs.entry(request.finalName, in: folder))
        guard final?.size == written.size else { throw .verificationFailed }
        return written
    }

    /// Streams the source into the partial, hashing as it goes, and makes it durable.
    private static func writePartial(
        _ request: Request, _ partial: String, _ fs: some FileSystem, _ isCancelled: () -> Bool,
        _ created: inout [String]
    ) throws(Reason) -> Result {
        let source = try io(try fs.openForReading(request.sourcePath, in: request.sourceFolder))
        let out = try claim(partial, in: request.destination, fs, uncached: true)
        created.append(partial)
        var hasher = SHA256()
        var size: Int64 = 0
        while true {
            if isCancelled() { throw .cancelled }
            let chunk = try io(try fs.read(source, upTo: request.chunkSize))
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
            size += Int64(chunk.count)
            try io(try fs.write(chunk, to: out))
        }
        try io(try fs.syncToDevice(out))
        return Result(sha256: hex(hasher.finalize()), size: size)
    }

    /// Creates `name`, which must not exist; "already exists" is the volume's answer (SR10).
    private static func claim(
        _ name: String, in folder: OpenFolder, _ fs: some FileSystem, uncached: Bool
    ) throws(Reason) -> OpenFile {
        do {
            return try fs.createExclusively(name, in: folder, uncached: uncached)
        } catch {
            throw error.alreadyExists ? .nameTaken(name) : .io(error)
        }
    }

    /// Removes what this call created; returns the names it couldn't remove.
    private static func cleanUp(_ created: [String], in folder: OpenFolder, _ fs: some FileSystem) -> [String] {
        var leftBehind: [String] = []
        for name in created {
            do {
                if try fs.entry(name, in: folder) != nil { try fs.remove(name, in: folder) }
            } catch {
                leftBehind.append(name)
            }
        }
        return leftBehind
    }

    private static func io<T>(_ body: @autoclosure () throws(FileSystemError) -> T) throws(Reason) -> T {
        do {
            return try body()
        } catch {
            throw .io(error)
        }
    }

    private static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}
