import Foundation
import Testing

@testable import FujiCullCore

// Film simulation from Fuji's MakerNote (R17; spike S2), and the EXIF line's text.
@Suite struct FujiMakerNoteTests {

    @Test(arguments: [
        ("DSCF3404-head64k.JPG", "Classic Chrome"),
        ("DSCF3406-head64k.JPG", "Classic Chrome"),
        ("DSCF4006-head64k.JPG", "Astia"),
        ("DSCF4136-head64k.JPG", "Acros + Ye"),
    ])
    func everySampleFilmSimulationDecodes(file: String, expected: String) throws {
        let summary = try #require(ExifParser.parse(jpegHead: try Fixture.data(file)).summary)

        #expect(summary.filmSimulation == expected)
    }

    @Test(arguments: [
        (0x000, "Provia"), (0x120, "Astia"), (0x200, "Velvia"), (0x400, "Velvia"), (0x500, "Pro Neg. Std"),
        (0x501, "Pro Neg. Hi"), (0x600, "Classic Chrome"), (0x700, "Eterna"), (0x800, "Classic Neg."),
        (0x900, "Eterna Bleach Bypass"), (0xA00, "Nostalgic Neg."), (0xB00, "Reala Ace"),
    ])
    func colourFilmModesMapToTheirNames(code: Int, name: String) {
        #expect(FujiMakerNote.filmSimulation(filmMode: code, saturation: 0xE0) == name)
    }

    @Test(arguments: [
        (0x300, "Monochrome"), (0x301, "Monochrome + R"), (0x302, "Monochrome + Ye"), (0x303, "Monochrome + G"),
        (0x310, "Sepia"), (0x500, "Acros"), (0x501, "Acros + R"), (0x502, "Acros + Ye"), (0x503, "Acros + G"),
    ])
    func monochromeIsReadFromSaturationWhenThereIsNoFilmMode(code: Int, name: String) {
        #expect(FujiMakerNote.filmSimulation(filmMode: nil, saturation: code) == name)
    }

    @Test func unknownValuesGiveNoName() {
        #expect(FujiMakerNote.filmSimulation(filmMode: 0xF00, saturation: nil) == nil)
        #expect(FujiMakerNote.filmSimulation(filmMode: nil, saturation: 0xE0) == nil)
        #expect(FujiMakerNote.filmSimulation(filmMode: nil, saturation: nil) == nil)
    }

    @Test func aMakerNoteFromAnotherBrandIsIgnored() {
        #expect(FujiMakerNote.read(Data("Nikon\0\u{2}\u{10}\0\0MM\0*".utf8)) == nil)
        #expect(FujiMakerNote.read(Data()) == nil)
    }

    @Test func aTruncatedOrCorruptMakerNoteNeverCrashes() throws {
        let head = try Fixture.data("DSCF4006-head64k.JPG")
        guard let start = head.range(of: Data("FUJIFILM".utf8))?.lowerBound else {
            Issue.record("fixture has no Fuji MakerNote")
            return
        }
        let note = head[start...].prefix(1_600)
        for cut in stride(from: 0, to: note.count, by: 7) {
            _ = FujiMakerNote.read(Data(note.prefix(cut)))
            var damaged = [UInt8](note)
            damaged[min(cut, damaged.count - 1)] ^= 0xFF
            _ = FujiMakerNote.read(Data(damaged))
        }
    }

    // MARK: The EXIF line (R17)

    @Test func theExifLineReadsLikeTheCameraShowsIt() throws {
        let summary = try #require(ExifParser.parse(jpegHead: try Fixture.data("DSCF3404-head64k.JPG")).summary)

        #expect(ExifLine.parts(summary) == ["1/1700 s", "f/8", "ISO 500", "23 mm", "Classic Chrome"])
    }

    @Test func longExposuresShowSeconds() {
        var summary = ExifSummary()
        summary.exposureTime = Rational(15, 2)
        summary.fNumber = 1.4

        #expect(ExifLine.parts(summary) == ["7.5 s", "f/1.4", "—"])
    }

    @Test func anUnknownFilmSimulationShowsADash() {
        var summary = ExifSummary()
        summary.iso = 12_800

        #expect(ExifLine.parts(summary) == ["ISO 12800", "—"])
    }
}
