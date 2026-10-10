import Foundation
import Testing

@testable import FujiCullCore

/// A RAF header: the 16-byte magic, then big-endian JPEG offset and length at bytes 84 and 88.
private func rafHeader(offset: UInt32, length: UInt32, magic: String = "FUJIFILMCCD-RAW ") -> Data {
    var bytes = [UInt8](repeating: 0, count: 92)
    bytes.replaceSubrange(0..<16, with: Array(magic.utf8.prefix(16)))
    for (index, value) in [(84, offset), (88, length)] {
        bytes[index] = UInt8(value >> 24)
        bytes[index + 1] = UInt8((value >> 16) & 0xFF)
        bytes[index + 2] = UInt8((value >> 8) & 0xFF)
        bytes[index + 3] = UInt8(value & 0xFF)
    }
    return Data(bytes)
}

// The embedded JPEG inside a Fuji RAF, for RAF-only frames (R4; DESIGN §5.4).
@Suite struct RAFHeaderTests {

    @Test func findsTheEmbeddedJPEGInARealXT50RAF() throws {
        let head = try Fixture.data("DSCF3404-head70k.RAF")

        let header = try #require(RAFHeader.parse(head))

        #expect(header == RAFHeader(jpegOffset: 148, jpegLength: 4_857_388))
        #expect(head[148] == 0xFF && head[149] == 0xD8, "a JPEG starts there")
    }

    @Test func recognisesARAFByItsMagic() throws {
        #expect(RAFHeader.isRAF(try Fixture.data("DSCF3404-head70k.RAF")))
        #expect(!RAFHeader.isRAF(try Fixture.data("DSCF3404-head64k.JPG")))
        #expect(!RAFHeader.isRAF(Data()))
    }

    @Test func readsASyntheticHeader() {
        #expect(RAFHeader.parse(rafHeader(offset: 160, length: 2_000)) == RAFHeader(jpegOffset: 160, jpegLength: 2_000))
    }

    @Test func rejectsAnythingThatIsNotAUsableRAFHeader() {
        #expect(RAFHeader.parse(rafHeader(offset: 160, length: 2_000).prefix(91)) == nil, "too short")
        #expect(RAFHeader.parse(rafHeader(offset: 160, length: 2_000, magic: "FUJIFILMCCD-RAX ")) == nil)
        #expect(RAFHeader.parse(rafHeader(offset: 160, length: 0)) == nil, "no embedded JPEG")
        #expect(RAFHeader.parse(rafHeader(offset: 40, length: 2_000)) == nil, "inside the header")
        #expect(RAFHeader.parse(rafHeader(offset: 160, length: 200_000_000)) == nil, "implausibly large")
    }
}
