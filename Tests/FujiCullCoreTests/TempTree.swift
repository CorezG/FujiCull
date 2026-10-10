import Foundation

/// A throwaway directory tree for scanner tests. Removed when the value is released.
final class TempTree {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FujiCullTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit {
        do {
            try FileManager.default.removeItem(at: root)
        } catch {
            // deinit can't throw; report instead of silently leaving test files behind.
            FileHandle.standardError.write(Data("TempTree: could not remove \(root.path): \(error)\n".utf8))
        }
    }

    /// Creates a file of `bytes` bytes at `path` (relative to the root), creating folders as needed.
    @discardableResult
    func file(_ path: String, bytes: Int = 1, modified: Date? = nil) throws -> URL {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0xAB, count: bytes).write(to: url)
        if let modified {
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        }
        return url
    }

    func url(_ path: String) -> URL { root.appendingPathComponent(path) }
}
