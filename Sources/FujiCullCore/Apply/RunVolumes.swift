import Foundation

/// Which volume unmounts stop a running Apply (R23).
public enum RunVolumes {
    /// True when the volume that went away is the card or the archive, or when the notice doesn't say which
    /// volume it was. macOS mounts and unmounts volumes of its own at any time (the hidden Recovery volume,
    /// Time Machine snapshots, disk images); those must not stop a copy.
    public static func unmountStopsRun(_ unmounted: URL?, card: URL?, archive: URL?) -> Bool {
        guard let unmounted else { return true }
        let gone = unmounted.standardizedFileURL.path
        return [card, archive].contains { $0?.standardizedFileURL.path == gone }
    }
}
