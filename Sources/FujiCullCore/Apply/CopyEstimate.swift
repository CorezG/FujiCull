import Foundation

/// What pre-flight says about how long a copy will take on a slow connection.
public enum CopyEstimate {
    /// Overall copy rate through a USB 2.0 link, with every file written and read back. Measured on
    /// 2026-11-16 from 990 files (36.7 GB): 17–19 MB/s, against a card that reads at 93 MB/s.
    public static let slowLinkBytesPerSecond: Int64 = 17_000_000

    /// True for a drive known to be on USB 2.0 (480 Mb/s) or slower. A drive whose link speed can't be read
    /// (Thunderbolt, internal) is not called slow.
    public static func isSlowLink(bitsPerSecond: Int64?) -> Bool {
        guard let bitsPerSecond else { return false }
        return bitsPerSecond <= 480_000_000
    }

    /// Whole minutes, rounded up, to copy `bytes` at the measured slow-link rate.
    public static func minutesOverSlowLink(bytes: Int64) -> Int {
        guard bytes > 0 else { return 0 }
        let seconds = Double(bytes) / Double(slowLinkBytesPerSecond)
        return Int((seconds / 60).rounded(.up))
    }
}
