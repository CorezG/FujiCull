import CryptoKit
import Foundation

/// The key a session is saved under (SR1): the volume UUID for anything on removable media, so a card
/// gets one session however it was opened; otherwise a hash of the folder's canonical path.
public enum SessionKey {
    public static func `for`(source: URL) throws -> String {
        let base = SourceLocator.identityBase(for: source)
        let values = try base.resourceValues(forKeys: [.volumeUUIDStringKey, .volumeURLKey])
        return make(
            volumeUUID: values.volumeUUIDString,
            baseIsVolumeRoot: base.standardizedFileURL == values.volume?.standardizedFileURL,
            canonicalPath: base.resolvingSymlinksInPath().standardizedFileURL.path)
    }

    /// The key from what the file system reported; pure, so both branches are testable without a card.
    /// The identity base is the volume root only for removable media (`SourceLocator.identityBase`).
    static func make(volumeUUID: String?, baseIsVolumeRoot: Bool, canonicalPath: String) -> String {
        if baseIsVolumeRoot, let volumeUUID { return "vol-\(volumeUUID)" }
        let digest = SHA256.hash(data: Data(canonicalPath.utf8)).prefix(12).map { String(format: "%02x", $0) }
        return "path-\(digest.joined())"
    }
}
