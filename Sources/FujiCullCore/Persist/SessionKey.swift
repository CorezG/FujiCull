import CryptoKit
import Foundation

/// The key a session is saved under (SR1). A camera card gets one session however it was opened, and keeps
/// it when it's renamed or moved to another reader; any other folder is keyed by its path.
public enum SessionKey {
    public static func `for`(source: URL) throws -> String {
        let base = SourceLocator.identityBase(for: source)
        let values = try base.resourceValues(forKeys: [
            .volumeUUIDStringKey, .volumeURLKey, .volumeCreationDateKey, .volumeTotalCapacityKey,
        ])
        // The identity base is the volume root only for a camera card (`SourceLocator.identityBase`).
        return make(
            volumeUUID: values.volumeUUIDString,
            isCard: base.standardizedFileURL == values.volume?.standardizedFileURL,
            formatted: values.volumeCreationDate, capacity: values.volumeTotalCapacity,
            canonicalPath: base.resolvingSymlinksInPath().standardizedFileURL.path)
    }

    /// The key from what the file system reported; pure, so every branch is testable without a card.
    ///
    /// - A card with a volume UUID: `vol-<UUID>`.
    /// - A card without one: `card-<capacity>-<when it was formatted>`. The X-T50 formats small (FAT32) cards
    ///   with no volume serial, so macOS reports no UUID and names them all "NO NAME" (measured 2026-10-10).
    ///   FAT stores local time with no zone, so the wall-clock digits are used: they stay the same when the
    ///   Mac changes time zone, while the instant macOS reports does not.
    /// - Anything else: a hash of the folder's path.
    static func make(
        volumeUUID: String?, isCard: Bool, formatted: Date?, capacity: Int?, canonicalPath: String,
        timeZone: TimeZone = .current
    ) -> String {
        if isCard {
            if let volumeUUID, volumeUUID.contains(where: { $0 != "0" && $0 != "-" }) { return "vol-\(volumeUUID)" }
            if let formatted, let capacity {
                let stamp = DateFormatter()
                stamp.locale = Locale(identifier: "en_US_POSIX")
                stamp.calendar = Calendar(identifier: .gregorian)
                stamp.timeZone = timeZone
                stamp.dateFormat = "yyyyMMdd'T'HHmmss"
                return "card-\(capacity)-\(stamp.string(from: formatted))"
            }
        }
        let digest = SHA256.hash(data: Data(canonicalPath.utf8)).prefix(12).map { String(format: "%02x", $0) }
        return "path-\(digest.joined())"
    }
}
