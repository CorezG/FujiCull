import Foundation

/// Where a Fuji RAF keeps its embedded full-size JPEG preview, so RAF-only frames can be shown (R4; DESIGN §5.4).
/// Layout (spike S1, checked on X-T50 files): "FUJIFILMCCD-RAW " at byte 0, then the JPEG's offset and length
/// as big-endian UInt32 at bytes 84 and 88.
public struct RAFHeader: Equatable, Sendable {
    public let jpegOffset: Int
    public let jpegLength: Int

    public init(jpegOffset: Int, jpegLength: Int) {
        self.jpegOffset = jpegOffset
        self.jpegLength = jpegLength
    }

    /// The bytes needed to read the header.
    public static let size = 92
    private static let magic = Array("FUJIFILMCCD-RAW ".utf8)
    /// Embedded previews are a few MB; anything far larger means a damaged header.
    private static let maxPlausibleLength = 64 << 20

    public static func isRAF(_ head: Data) -> Bool {
        head.count >= magic.count && head.prefix(magic.count).elementsEqual(magic)
    }

    /// The embedded JPEG's location, or nil if `head` isn't a RAF header describing a plausible preview.
    public static func parse(_ head: Data) -> RAFHeader? {
        guard isRAF(head), head.count >= size else { return nil }
        let bytes = [UInt8](head.prefix(size))
        func u32(_ at: Int) -> Int {
            Int(bytes[at]) << 24 | Int(bytes[at + 1]) << 16 | Int(bytes[at + 2]) << 8 | Int(bytes[at + 3])
        }
        let offset = u32(84)
        let length = u32(88)
        guard offset >= size, length > 0, length <= maxPlausibleLength else { return nil }
        return RAFHeader(jpegOffset: offset, jpegLength: length)
    }
}
