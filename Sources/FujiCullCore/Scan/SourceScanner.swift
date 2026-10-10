import Foundation

/// Lists a card or folder and sorts every regular file into frames, videos and other files (DESIGN §5.1).
/// Reads directory entries only, never file contents.
public enum SourceScanner {

    public enum ScanError: Error, Equatable {
        case notAFolder(path: String)
        case notInsideIdentityBase(folder: String, base: String)
        case unreadable(path: String, reason: String)
    }

    /// Camera and OS system folders, skipped only when they sit directly in the identity base (R5).
    static let systemFolders: Set<String> = [
        "System Volume Information", "$RECYCLE.BIN", "FFDB", "ACTIVITY", "UPD",
    ]
    static let jpgExtensions: Set<String> = ["jpg", "jpeg"]
    static let rafExtensions: Set<String> = ["raf"]
    static let videoExtensions: Set<String> = ["mov", "mp4"]

    /// Scans `folder` recursively. Paths and FrameIDs are relative to `identityBase`, which must be
    /// `folder` itself or one of its ancestors (the volume root for a card, SR2).
    public static func scan(_ folder: URL, identityBase: URL) throws -> ScanResult {
        let prefix = try relativePrefix(of: folder, within: identityBase)
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        let failure = FirstError()
        guard
            let walker = FileManager.default.enumerator(
                at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants],
                errorHandler: { url, error in
                    failure.record(.unreadable(path: url.path, reason: error.localizedDescription))
                    return false
                })
        else { throw ScanError.unreadable(path: folder.path, reason: "could not list folder") }

        let keySet = Set(keys)
        let basePath = folder.standardizedFileURL.path
        let baseWithSlash = basePath.hasSuffix("/") ? basePath : basePath + "/"
        var photos: [SourceFile] = []
        var videos: [SourceFile] = []
        var others: [SourceFile] = []

        for case let url as URL in walker {
            let values = try url.resourceValues(forKeys: keySet)
            let relative = prefix + relativePath(of: url, under: baseWithSlash)
            if values.isDirectory == true {
                if !relative.contains("/") && systemFolders.contains(relative) { walker.skipDescendants() }
                continue
            }
            guard values.isRegularFile == true else { continue }
            let file = SourceFile(
                relativePath: relative,
                size: Int64(values.fileSize ?? 0),
                modified: values.contentModificationDate ?? .distantPast)
            let ext = file.lowercasedExtension
            if jpgExtensions.contains(ext) || rafExtensions.contains(ext) {
                photos.append(file)
            } else if videoExtensions.contains(ext) {
                videos.append(file)
            } else {
                others.append(file)
            }
        }
        if let error = failure.error { throw error }

        return ScanResult(frames: group(photos), videos: sortedByPath(videos), otherFiles: sortedByPath(others))
    }

    /// Groups photo files into frames and returns them in cull order (pure; DESIGN §5.1 pairing rules).
    /// Exactly one JPG + one RAF with the same folder and case-folded name form a pair; a lone file is an
    /// unpaired frame; any other group is split so every file is its own frame with an exact-filename ID.
    static func group(_ files: [SourceFile]) -> [Frame] {
        var groups: [String: [SourceFile]] = [:]
        for file in files {
            groups[file.folder + "/" + file.stem.lowercased(), default: []].append(file)
        }

        var frames: [Frame] = []
        for members in groups.values {
            let jpgs = members.filter { jpgExtensions.contains($0.lowercasedExtension) }
            let rafs = members.filter { rafExtensions.contains($0.lowercasedExtension) }
            if members.count == 2, jpgs.count == 1, rafs.count == 1 {
                frames.append(Frame(id: stemID(jpgs[0]), jpg: jpgs[0], raf: rafs[0]))
            } else if members.count == 1 {
                let only = members[0]
                frames.append(Frame(id: stemID(only), jpg: jpgs.first, raf: rafs.first))
            } else {
                for file in members {
                    let isJPG = jpgExtensions.contains(file.lowercasedExtension)
                    frames.append(
                        Frame(id: FrameID(file.relativePath), jpg: isJPG ? file : nil, raf: isJPG ? nil : file))
                }
            }
        }
        return frames.map { (NaturalSortKey($0.id.rawValue), $0) }.sorted { $0.0 < $1.0 }.map(\.1)
    }

    // MARK: Helpers

    private static func stemID(_ file: SourceFile) -> FrameID {
        let stem = file.stem.uppercased()
        return FrameID(file.folder.isEmpty ? stem : file.folder + "/" + stem)
    }

    private static func sortedByPath(_ files: [SourceFile]) -> [SourceFile] {
        files.map { (NaturalSortKey($0.relativePath), $0) }.sorted { $0.0 < $1.0 }.map(\.1)
    }

    /// The folder's path relative to the identity base, with a trailing "/" (or "" when they're the same).
    private static func relativePrefix(of folder: URL, within base: URL) throws -> String {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue
        else { throw ScanError.notAFolder(path: folder.path) }
        let folderPath = folder.resolvingSymlinksInPath().standardizedFileURL.path
        let basePath = base.resolvingSymlinksInPath().standardizedFileURL.path
        if folderPath == basePath { return "" }
        let baseWithSlash = basePath.hasSuffix("/") ? basePath : basePath + "/"
        guard folderPath.hasPrefix(baseWithSlash) else {
            throw ScanError.notInsideIdentityBase(folder: folderPath, base: basePath)
        }
        return String(folderPath.dropFirst(baseWithSlash.count)) + "/"
    }

    /// `url`'s path below the scanned folder. The enumerator builds child URLs from the folder it was given,
    /// so a prefix check is enough; the standardised fallback only runs if that ever stops being true.
    private static func relativePath(of url: URL, under baseWithSlash: String) -> String {
        let path = url.path
        if path.hasPrefix(baseWithSlash) { return String(path.dropFirst(baseWithSlash.count)) }
        let standardized = url.standardizedFileURL.path
        return standardized.hasPrefix(baseWithSlash)
            ? String(standardized.dropFirst(baseWithSlash.count)) : url.lastPathComponent
    }
}

/// Holds the first error reported by the directory enumerator's callback.
private final class FirstError {
    private(set) var error: SourceScanner.ScanError?
    func record(_ error: SourceScanner.ScanError) {
        if self.error == nil { self.error = error }
    }
}
