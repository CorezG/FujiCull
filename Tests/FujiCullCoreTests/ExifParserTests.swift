import Foundation
import Testing

@testable import FujiCullCore

/// Real X-T50 headers in Tests/Fixtures/X-T50 (see the README there).
enum Fixture {
    static func data(_ name: String) throws -> Data {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/X-T50/\(name)")
        return try Data(contentsOf: url)
    }
}

// T0 metadata from the first 64 KB of a JPEG (DESIGN §5.4, §5.6; spike S1).
@Suite struct ExifParserTests {

    // MARK: Real X-T50 files

    @Test func readsExposureAndCaptureTimeFromALandscapeXT50Header() throws {
        let summary = try #require(ExifParser.parse(jpegHead: try Fixture.data("DSCF3404-head64k.JPG")).summary)

        #expect(summary.orientation == 1)
        #expect(summary.exposureTime == Rational(1, 1700))
        #expect(summary.fNumber == 8)
        #expect(summary.iso == 500)
        #expect(summary.focalLength == 23)
        #expect(summary.captureTime == CaptureTime(dateTime: "2026:09:20 05:08:41", subsecond: "82"))
    }

    @Test func readsTheFullPixelSizeSoZoomCanBeSizedBeforeTheImageLoads() throws {
        let landscape = try #require(ExifParser.parse(jpegHead: try Fixture.data("DSCF3404-head64k.JPG")).summary)
        let portrait = try #require(ExifParser.parse(jpegHead: try Fixture.data("DSCF3406-head64k.JPG")).summary)

        #expect(landscape.pixelSize == PixelSize(width: 5472, height: 3648))
        #expect(portrait.pixelSize == PixelSize(width: 5472, height: 3648), "as stored, before orientation")
        #expect(portrait.uprightPixelSize == PixelSize(width: 3648, height: 5472))
    }

    @Test func readsOrientationSixFromAPortraitXT50Header() throws {
        let summary = try #require(ExifParser.parse(jpegHead: try Fixture.data("DSCF3406-head64k.JPG")).summary)

        #expect(summary.orientation == 6)
        #expect(summary.exposureTime == Rational(1, 900))
    }

    @Test func locatesTheEmbeddedThumbnailInsideTheHeader() throws {
        let head = try Fixture.data("DSCF3404-head64k.JPG")
        let summary = try #require(ExifParser.parse(jpegHead: head).summary)

        let range = try #require(summary.thumbnail)
        #expect(range.upperBound <= head.count)
        // A JPEG thumbnail starts with SOI (FF D8) and ends with EOI (FF D9).
        #expect(head[range.lowerBound] == 0xFF && head[range.lowerBound + 1] == 0xD8)
        #expect(head[range.upperBound - 2] == 0xFF && head[range.upperBound - 1] == 0xD9)
    }

    // MARK: Inputs that aren't a complete, valid EXIF header

    @Test func reportsWhenAPP1EndsBeyondTheBytesRead() throws {
        let head = try Fixture.data("DSCF3404-head64k.JPG").prefix(30_000)

        #expect(ExifParser.parse(jpegHead: Data(head)) == .needMoreBytes(atLeast: 65_472))
    }

    @Test func reportsWhenAnEarlierSegmentPushesAPP1PastTheBytesRead() {
        // SOI, then a 60,000-byte comment segment, then nothing: APP1 hasn't even started yet.
        var bytes: [UInt8] = [0xFF, 0xD8, 0xFF, 0xFE, 0xEA, 0x62]
        bytes += [UInt8](repeating: 0x20, count: 60_000 - 2)

        guard case .needMoreBytes(let atLeast) = ExifParser.parse(jpegHead: Data(bytes)) else {
            Issue.record("expected needMoreBytes")
            return
        }
        #expect(atLeast > bytes.count)
    }

    @Test func rejectsDataThatIsNotAJPEG() {
        #expect(ExifParser.parse(jpegHead: Data("FUJIFILMCCD-RAW 0201".utf8)) == .notJPEG)
        #expect(ExifParser.parse(jpegHead: Data()) == .notJPEG)
    }

    @Test func reportsNoExifWhenTheImageDataStartsFirst() {
        let bytes: [UInt8] = [0xFF, 0xD8, 0xFF, 0xDA, 0x00, 0x08, 1, 2, 3, 4, 5, 6]

        #expect(ExifParser.parse(jpegHead: Data(bytes)) == .noExif)
    }

    @Test func aHeaderWithoutAThumbnailStillYieldsExposureData() {
        let tiff = TIFFBuilder(littleEndian: true)
            .ifd0(entries: [.short(0x0112, 8)], exif: [.rational(0x829A, 1, 250), .short(0x8827, 1600)])
        let summary = ExifParser.parse(jpegHead: tiff.asJPEGHead()).summary

        #expect(summary?.orientation == 8)
        #expect(summary?.exposureTime == Rational(1, 250))
        #expect(summary?.iso == 1600)
        #expect(summary?.thumbnail == nil)
    }

    @Test func bigEndianTIFFIsReadCorrectly() {
        let tiff = TIFFBuilder(littleEndian: false)
            .ifd0(entries: [.short(0x0112, 3)], exif: [.rational(0x829D, 28, 10)])
        let summary = ExifParser.parse(jpegHead: tiff.asJPEGHead()).summary

        #expect(summary?.orientation == 3)
        #expect(summary?.fNumber == 2.8)
    }

    @Test func truncatedOrCorruptHeadersNeverCrash() throws {
        let real = try Fixture.data("DSCF3404-head64k.JPG")
        // Cut the EXIF segment at many points and flip bytes inside it; every result must be a value, not a trap.
        for cut in stride(from: 4, to: 6_000, by: 37) {
            var bytes = [UInt8](real.prefix(65_472))
            bytes.replaceSubrange(
                cut..<min(cut + 8, bytes.count), with: [0xFF, 0x00, 0x7F, 0x80, 0x01, 0xFE, 0x10, 0xEE])
            _ = ExifParser.parse(jpegHead: Data(bytes))
            _ = ExifParser.parse(jpegHead: real.prefix(cut))
        }
    }

    @Test func anIFDThatPointsToItselfDoesNotLoopForever() {
        let tiff = TIFFBuilder(littleEndian: true).selfReferencingIFD()

        #expect(ExifParser.parse(jpegHead: tiff.asJPEGHead()) == .malformed)
    }
}

/// Builds small TIFF/EXIF blocks for edge cases the real fixtures don't cover.
struct TIFFBuilder {
    enum Entry {
        case short(UInt16, UInt16)
        case rational(UInt16, UInt32, UInt32)
    }

    let littleEndian: Bool
    private var bytes: [UInt8] = []

    init(littleEndian: Bool) { self.littleEndian = littleEndian }

    private func u16(_ v: UInt16) -> [UInt8] {
        littleEndian ? [UInt8(v & 0xFF), UInt8(v >> 8)] : [UInt8(v >> 8), UInt8(v & 0xFF)]
    }
    private func u32(_ v: UInt32) -> [UInt8] {
        let le = [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8(v >> 24)]
        return littleEndian ? le : le.reversed()
    }
    private var header: [UInt8] { (littleEndian ? [0x49, 0x49] : [0x4D, 0x4D]) + u16(42) + u32(8) }

    /// IFD0 at offset 8 with `entries` plus an ExifIFD pointer, then the ExifIFD, then rational values.
    func ifd0(entries: [Entry], exif: [Entry]) -> TIFFBuilder {
        var out = header
        let ifd0Size = 2 + (entries.count + 1) * 12 + 4
        let exifOffset = 8 + ifd0Size
        let exifSize = 2 + exif.count * 12 + 4
        var dataOffset = exifOffset + exifSize
        var data: [UInt8] = []

        func encode(_ list: [Entry]) -> [UInt8] {
            var block: [UInt8] = []
            for entry in list {
                switch entry {
                case .short(let tag, let value):
                    block += u16(tag) + u16(3) + u32(1) + u16(value) + [0, 0]
                case .rational(let tag, let n, let d):
                    block += u16(tag) + u16(5) + u32(1) + u32(UInt32(dataOffset))
                    data += u32(n) + u32(d)
                    dataOffset += 8
                }
            }
            return block
        }

        out += u16(UInt16(entries.count + 1)) + encode(entries)
        out += u16(0x8769) + u16(4) + u32(1) + u32(UInt32(exifOffset)) + u32(0)
        out += u16(UInt16(exif.count)) + encode(exif) + u32(0)
        var copy = self
        copy.bytes = out + data
        return copy
    }

    /// IFD0 whose "next IFD" pointer and ExifIFD pointer both point back at IFD0.
    func selfReferencingIFD() -> TIFFBuilder {
        var copy = self
        copy.bytes = header + u16(1) + u16(0x8769) + u16(4) + u32(1) + u32(8) + u32(8)
        return copy
    }

    /// Wraps the TIFF block in SOI + APP1 "Exif\0\0".
    func asJPEGHead() -> Data {
        let payload: [UInt8] = Array("Exif".utf8) + [0, 0] + bytes
        let length = UInt16(payload.count + 2)
        return Data([0xFF, 0xD8, 0xFF, 0xE1, UInt8(length >> 8), UInt8(length & 0xFF)] + payload)
    }
}
