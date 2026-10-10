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

    /// What a source's FrameIDs are relative to, and what is scanned (SR1, SR2). For any folder on a
    /// camera card that is the whole card, so the card yields the same frames however it was opened.
    /// Every other folder is its own base.
    public static func identityBase(for folder: URL) -> URL {
        let keys: Set<URLResourceKey> = [.volumeURLKey, .volumeIsRemovableKey, .volumeIsEjectableKey]
        guard let values = try? folder.resourceValues(forKeys: keys), let volume = values.volume else { return folder }
        return identityBase(
            for: folder, volume: volume,
            isRemovable: values.volumeIsRemovable == true || values.volumeIsEjectable == true)
    }

    /// The decision behind `identityBase(for:)`, given what the volume reported. A card reader reports its
    /// cards as removable; a USB SSD doesn't (measured 2026-10-10), so a `DCIM` tree copied onto one is
    /// just a folder.
    static func identityBase(for folder: URL, volume: URL, isRemovable: Bool) -> URL {
        isRemovable && isCameraCard(volume) ? volume : folder
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
