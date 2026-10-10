import CryptoKit
import Foundation

/// Held for a whole Apply run so that two runs can never write to the same trip folder at once (SR3).
/// Released when the value is released, or when the app exits for any reason.
public final class ArchiveLock: Sendable {
    public enum LockError: Error, Equatable {
        /// Another Apply is using this trip folder.
        case busy
        case io(String)
    }

    private let descriptor: Int32

    private init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    deinit { _ = close(descriptor) }

    /// `directory` is FujiCull's own `Locks` folder. The lock is per archive volume and trip folder,
    /// ignoring case as the volume does.
    public static func acquire(in directory: URL, for destination: Ledger.Destination) throws(LockError) -> ArchiveLock
    {
        let name = Data("\(destination.volumeUUID)/\(destination.folder.lowercased())".utf8)
        let digest = SHA256.hash(data: name).prefix(12).map { String(format: "%02x", $0) }.joined()
        let path = directory.appendingPathComponent("archive-\(digest).lock").path
        let descriptor = open(path, O_CREAT | O_RDWR | O_EXLOCK | O_NONBLOCK | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else {
            throw errno == EWOULDBLOCK ? .busy : .io("could not lock \(path): errno \(errno)")
        }
        return ArchiveLock(descriptor: descriptor)
    }
}
