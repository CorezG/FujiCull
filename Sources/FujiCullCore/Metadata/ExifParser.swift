import Foundation

/// An EXIF RATIONAL. Equality compares values, so 1/250 == 4/1000.
public struct Rational: Hashable, Sendable, Codable {
    public let numerator: UInt32
    public let denominator: UInt32

    public init(_ numerator: UInt32, _ denominator: UInt32) {
        self.numerator = numerator
        self.denominator = denominator
    }

    /// nil when the denominator is 0.
    public var value: Double? { denominator == 0 ? nil : Double(numerator) / Double(denominator) }

    public static func == (lhs: Rational, rhs: Rational) -> Bool {
        UInt64(lhs.numerator) * UInt64(rhs.denominator) == UInt64(rhs.numerator) * UInt64(lhs.denominator)
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(value)
    }
}

/// DateTimeOriginal ("YYYY:MM:DD HH:MM:SS", camera local time, no zone) plus SubSecTimeOriginal.
/// Kept as text: it's an identity component (SR2), not something FujiCull does date arithmetic on.
public struct CaptureTime: Hashable, Sendable, Codable {
    public let dateTime: String
    public let subsecond: String?

    public init(dateTime: String, subsecond: String?) {
        self.dateTime = dateTime
        self.subsecond = subsecond
    }
}

/// What FujiCull needs from a JPEG's EXIF (DESIGN §5.4 T0, §5.6). Every field is optional except
/// orientation, which defaults to 1 (upright) when absent or invalid.
public struct ExifSummary: Hashable, Sendable {
    public var orientation = 1
    public var exposureTime: Rational?
    public var fNumber: Double?
    public var iso: Int?
    public var focalLength: Double?
    public var captureTime: CaptureTime?
    /// Byte range of the embedded IFD1 JPEG thumbnail within the data that was parsed.
    public var thumbnail: Range<Int>?

    public init() {}
}

public enum ExifParseResult: Equatable, Sendable {
    case parsed(ExifSummary)
    /// The EXIF segment (or the marker before it) ends past the data given; read at least this many bytes.
    case needMoreBytes(atLeast: Int)
    case notJPEG
    /// The image data starts before any EXIF segment.
    case noExif
    /// The EXIF structure is inconsistent (bad header, out-of-range offsets, a loop).
    case malformed

    public var summary: ExifSummary? {
        if case .parsed(let summary) = self { return summary }
        return nil
    }
}

/// Reads EXIF from the first bytes of a JPEG without ImageIO, which can't parse a truncated file (spike S1).
/// Pure and bounds-checked: corrupt input yields a result value, never a crash.
public enum ExifParser {
    public static func parse(jpegHead: Data) -> ExifParseResult {
        let bytes = [UInt8](jpegHead)
        guard bytes.count >= 2, bytes[0] == 0xFF, bytes[1] == 0xD8 else { return .notJPEG }
        var index = 2
        while true {
            guard index < bytes.count else { return .needMoreBytes(atLeast: index + 4) }
            guard bytes[index] == 0xFF else { return .malformed }
            var markerIndex = index
            while markerIndex < bytes.count, bytes[markerIndex] == 0xFF { markerIndex += 1 }
            guard markerIndex < bytes.count else { return .needMoreBytes(atLeast: markerIndex + 3) }
            let marker = bytes[markerIndex]
            if marker == 0xDA || marker == 0xD9 { return .noExif }
            if (0xD0...0xD7).contains(marker) || marker == 0x01 {
                index = markerIndex + 1
                continue
            }
            guard markerIndex + 2 < bytes.count else { return .needMoreBytes(atLeast: markerIndex + 3) }
            let length = Int(bytes[markerIndex + 1]) << 8 | Int(bytes[markerIndex + 2])
            guard length >= 2 else { return .malformed }
            let payload = markerIndex + 3
            let segmentEnd = markerIndex + 1 + length
            if marker == 0xE1 {
                guard payload + 6 <= bytes.count else { return .needMoreBytes(atLeast: segmentEnd) }
                if bytes[payload..<payload + 6].elementsEqual([0x45, 0x78, 0x69, 0x66, 0x00, 0x00]) {
                    guard segmentEnd <= bytes.count else { return .needMoreBytes(atLeast: segmentEnd) }
                    return TIFFReader(bytes: bytes, start: payload + 6, end: segmentEnd).summary()
                }
            }
            index = segmentEnd
        }
    }
}

/// Walks the TIFF structure inside an APP1 "Exif" segment. Offsets are relative to `start`.
private struct TIFFReader {
    let bytes: [UInt8]
    let start: Int
    let end: Int
    var littleEndian = true

    private enum Tag {
        static let orientation: UInt16 = 0x0112
        static let exifIFD: UInt16 = 0x8769
        static let thumbnailOffset: UInt16 = 0x0201
        static let thumbnailLength: UInt16 = 0x0202
        static let exposureTime: UInt16 = 0x829A
        static let fNumber: UInt16 = 0x829D
        static let iso: UInt16 = 0x8827
        static let dateTimeOriginal: UInt16 = 0x9003
        static let subSecTimeOriginal: UInt16 = 0x9291
        static let focalLength: UInt16 = 0x920A
    }

    private struct Entry {
        let type: UInt16
        let count: Int
        /// Offset (relative to `start`) of the 4-byte value-or-offset field.
        let field: Int
    }

    init(bytes: [UInt8], start: Int, end: Int) {
        self.bytes = bytes
        self.start = start
        self.end = end
    }

    func summary() -> ExifParseResult {
        var reader = self
        guard let order = reader.u16(0) else { return .malformed }
        switch order {
        case 0x4949: reader.littleEndian = true
        case 0x4D4D: reader.littleEndian = false
        default: return .malformed
        }
        guard reader.u16(2) == 42, let ifd0Offset = reader.u32(4) else { return .malformed }

        var visited: Set<Int> = []
        guard let (ifd0, ifd1Offset) = reader.ifd(at: ifd0Offset, visited: &visited) else { return .malformed }

        var summary = ExifSummary()
        if let raw = reader.unsigned(ifd0[Tag.orientation]), (1...8).contains(raw) { summary.orientation = raw }

        if let pointer = reader.unsigned(ifd0[Tag.exifIFD]) {
            guard let (exif, _) = reader.ifd(at: pointer, visited: &visited) else { return .malformed }
            summary.exposureTime = reader.rational(exif[Tag.exposureTime]).flatMap { $0.denominator == 0 ? nil : $0 }
            summary.fNumber = reader.rational(exif[Tag.fNumber])?.value
            summary.iso = reader.unsigned(exif[Tag.iso])
            summary.focalLength = reader.rational(exif[Tag.focalLength])?.value
            if let dateTime = reader.ascii(exif[Tag.dateTimeOriginal]), !dateTime.isEmpty {
                let subsecond = reader.ascii(exif[Tag.subSecTimeOriginal]).flatMap { $0.isEmpty ? nil : $0 }
                summary.captureTime = CaptureTime(dateTime: dateTime, subsecond: subsecond)
            }
        }

        if ifd1Offset != 0, let (ifd1, _) = reader.ifd(at: ifd1Offset, visited: &visited),
            let offset = reader.unsigned(ifd1[Tag.thumbnailOffset]),
            let length = reader.unsigned(ifd1[Tag.thumbnailLength]), length > 0
        {
            let lower = start + offset
            let (upper, overflow) = lower.addingReportingOverflow(length)
            if !overflow, lower >= start, upper <= end { summary.thumbnail = lower..<upper }
        }
        return .parsed(summary)
    }

    // MARK: Structure

    /// Reads the IFD at `offset`: its entries by tag, and the next-IFD offset. nil if out of range or revisited.
    private func ifd(at offset: Int, visited: inout Set<Int>) -> ([UInt16: Entry], Int)? {
        guard !visited.contains(offset), let count = u16(offset), count <= 1000 else { return nil }
        visited.insert(offset)
        var entries: [UInt16: Entry] = [:]
        for index in 0..<count {
            let entryOffset = offset + 2 + index * 12
            guard let tag = u16(entryOffset), let type = u16(entryOffset + 2), let itemCount = u32(entryOffset + 4)
            else { return nil }
            entries[UInt16(tag)] = Entry(type: UInt16(type), count: itemCount, field: entryOffset + 8)
        }
        guard let next = u32(offset + 2 + count * 12) else { return nil }
        return (entries, next)
    }

    /// Where an entry's value lives: inline in the field when it fits in 4 bytes, otherwise at an offset.
    private func valueOffset(_ entry: Entry, unitSize: Int) -> Int? {
        let (size, overflow) = unitSize.multipliedReportingOverflow(by: entry.count)
        guard !overflow else { return nil }
        return size <= 4 ? entry.field : u32(entry.field)
    }

    // MARK: Typed values

    /// SHORT (3) or LONG (4); the first value.
    private func unsigned(_ entry: Entry?) -> Int? {
        guard let entry, entry.count >= 1 else { return nil }
        switch entry.type {
        case 3: return valueOffset(entry, unitSize: 2).flatMap { u16($0) }
        case 4: return valueOffset(entry, unitSize: 4).flatMap { u32($0) }
        default: return nil
        }
    }

    /// RATIONAL (5); the first value.
    private func rational(_ entry: Entry?) -> Rational? {
        guard let entry, entry.type == 5, entry.count >= 1, let at = valueOffset(entry, unitSize: 8),
            let numerator = u32(at), let denominator = u32(at + 4)
        else { return nil }
        return Rational(UInt32(numerator), UInt32(denominator))
    }

    /// ASCII (2), trimmed of NULs and surrounding spaces.
    private func ascii(_ entry: Entry?) -> String? {
        guard let entry, entry.type == 2, entry.count >= 1, entry.count <= 256,
            let at = valueOffset(entry, unitSize: 1), at >= 0, start + at + entry.count <= end
        else { return nil }
        let raw = bytes[(start + at)..<(start + at + entry.count)]
        let text = String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        return text.trimmingCharacters(in: .whitespaces)
    }

    // MARK: Bounds-checked integers (offsets relative to `start`)

    private func u16(_ offset: Int) -> Int? {
        let at = start + offset
        guard offset >= 0, at + 2 <= end else { return nil }
        let a = Int(bytes[at])
        let b = Int(bytes[at + 1])
        return littleEndian ? a | b << 8 : a << 8 | b
    }

    private func u32(_ offset: Int) -> Int? {
        let at = start + offset
        guard offset >= 0, at + 4 <= end else { return nil }
        let b0 = Int(bytes[at])
        let b1 = Int(bytes[at + 1])
        let b2 = Int(bytes[at + 2])
        let b3 = Int(bytes[at + 3])
        return littleEndian ? b0 | b1 << 8 | b2 << 16 | b3 << 24 : b0 << 24 | b1 << 16 | b2 << 8 | b3
    }
}
