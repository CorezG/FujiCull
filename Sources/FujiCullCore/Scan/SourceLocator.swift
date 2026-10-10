import Foundation

/// Finds camera cards among mounted volumes and decides what FrameIDs are relative to (R1, SR1, SR2).
public enum SourceLocator {

    /// A camera card has `DCIM/` at its root containing at least one `NNN_FUJI` folder.
    /// The archive SSD's own `DCIM/` (JPGs directly inside) therefore doesn't count.
    public static func isCameraCard(_ root: URL) -> Bool {
        guard let dcim = child(of: root, named: "DCIM") else { return false }
        return listing(of: dcim).contains { entry in
            isDirectory(entry) && entry.lastPathComponent.uppercased().hasSuffix("_FUJI")
        }
    }

    /// The camera cards among `volumes`, in the order given.
    public static func cameraCards(among volumes: [URL]) -> [URL] {
        volumes.filter(isCameraCard)
    }

    /// Mounted volumes the user can see (not the boot volume's system partitions).
    public static func mountedVolumes() -> [URL] {
        FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: [.skipHiddenVolumes]) ?? []
    }

    /// For a folder on removable media, the volume root, so a card yields the same FrameIDs however it
    /// was opened; otherwise the folder itself (SR2).
    public static func identityBase(for folder: URL) -> URL {
        let keys: Set<URLResourceKey> = [.volumeURLKey, .volumeIsRemovableKey, .volumeIsEjectableKey]
        guard let values = try? folder.resourceValues(forKeys: keys), let volume = values.volume,
            values.volumeIsRemovable == true || values.volumeIsEjectable == true
        else { return folder }
        return volume
    }

    /// The entry in `folder` whose name matches `name` ignoring case (exFAT is case-insensitive).
    private static func child(of folder: URL, named name: String) -> URL? {
        listing(of: folder).first { $0.lastPathComponent.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// A folder's visible entries. A folder that can't be read is treated as empty: detection only ever
    /// answers "is this a card?", and an unreadable folder isn't one.
    private static func listing(of folder: URL) -> [URL] {
        do {
            return try FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        } catch {
            return []
        }
    }

    private static func isDirectory(_ url: URL) -> Bool {
        do {
            return try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
        } catch {
            return false
        }
    }
}
