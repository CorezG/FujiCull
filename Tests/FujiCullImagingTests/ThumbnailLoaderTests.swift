import CoreGraphics
import Foundation
import FujiCullCore
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import FujiCullImaging

private func fixtureURL(_ name: String) -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/X-T50/\(name)")
}

// T0 thumbnails + EXIF (DESIGN §5.4 T0; T4).
@Suite struct ThumbnailLoaderTests {

    // MARK: Real X-T50 headers

    @Test func loadsTheLandscapeThumbnailUpright() throws {
        let t0 = try ThumbnailLoader.load(fixtureURL("DSCF3404-head64k.JPG"))

        let image = try #require(t0.image)
        #expect(image.width == 160 && image.height == 120)
        #expect(t0.exif.iso == 500)
    }

    @Test func rotatesThePortraitThumbnailThatTheCameraStoresSideways() throws {
        let t0 = try ThumbnailLoader.load(fixtureURL("DSCF3406-head64k.JPG"))

        let image = try #require(t0.image)
        #expect(t0.exif.orientation == 6)
        #expect(image.width == 120 && image.height == 160)
    }

    @Test func theHeaderCanBeKeptCompressedAndDecodedLater() throws {
        let header = try ThumbnailLoader.loadHeader(fixtureURL("DSCF3406-head64k.JPG"))

        let jpeg = try #require(header.thumbnailJPEG)
        #expect(jpeg.count < 20_000, "about 9 KB, so 2,000 frames fit in ~20 MB (DESIGN §5.4)")
        let image = try #require(ThumbnailLoader.decodeThumbnail(jpeg, orientation: header.exif.orientation))
        #expect(image.width == 120 && image.height == 160)
    }

    @Test func decodingSomethingThatIsNotAJPEGGivesNoImage() {
        #expect(ThumbnailLoader.decodeThumbnail(Data("nope".utf8), orientation: 1) == nil)
    }

    @Test func aRAFOnlyFrameGetsItsThumbnailFromTheEmbeddedJPEG() throws {
        let t0 = try ThumbnailLoader.load(fixtureURL("DSCF3404-head70k.RAF"))

        let image = try #require(t0.image)
        #expect(image.width == 160 && image.height == 120)
        #expect(t0.exif.filmSimulation == "Classic Chrome")
    }

    @Test func theDisplayImageOfARAFIsItsEmbeddedJPEG() throws {
        let tree = try TempFolder()
        let jpeg = try Data(contentsOf: try syntheticJPEGFile(in: tree))
        var raf = Data("FUJIFILMCCD-RAW ".utf8) + Data(repeating: 0, count: 144)
        let offset = UInt32(raf.count)
        let length = UInt32(jpeg.count)
        for (index, value) in [(84, offset), (88, length)] {
            raf[index] = UInt8(value >> 24)
            raf[index + 1] = UInt8((value >> 16) & 0xFF)
            raf[index + 2] = UInt8((value >> 8) & 0xFF)
            raf[index + 3] = UInt8(value & 0xFF)
        }
        raf += jpeg + Data(repeating: 0x55, count: 1_000)  // raw data would follow
        let url = tree.url.appendingPathComponent("DSCF9999.RAF")
        try raf.write(to: url)

        #expect(try PreviewPipeline.readJPEG(url) == jpeg)
        #expect(try ThumbnailLoader.load(url).image != nil)
    }

    @Test func readingAJPEGFileReturnsTheWholeFile() throws {
        let tree = try TempFolder()
        let url = try syntheticJPEGFile(in: tree)

        #expect(try PreviewPipeline.readJPEG(url) == Data(contentsOf: url))
    }

    @Test func aMissingFileThrows() {
        #expect(throws: (any Error).self) {
            try ThumbnailLoader.load(URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString).JPG"))
        }
    }

    // MARK: Orientation, checked by pixel colour (left half red, right half blue in the stored image)

    @Test func orientationOneLeavesTheImageAlone() throws {
        let out = try #require(ThumbnailLoader.oriented(try splitImage(), orientation: 1))
        #expect(out.width == 4 && out.height == 2)
        #expect(try colour(out, x: 0, y: 0) == .red && colour(out, x: 3, y: 0) == .blue)
    }

    @Test func orientationSixRotatesClockwiseSoTheStoredLeftEdgeIsOnTop() throws {
        let out = try #require(ThumbnailLoader.oriented(try splitImage(), orientation: 6))
        #expect(out.width == 2 && out.height == 4)
        #expect(try colour(out, x: 0, y: 0) == .red && colour(out, x: 0, y: 3) == .blue)
    }

    @Test func orientationEightRotatesAnticlockwiseSoTheStoredLeftEdgeIsAtTheBottom() throws {
        let out = try #require(ThumbnailLoader.oriented(try splitImage(), orientation: 8))
        #expect(out.width == 2 && out.height == 4)
        #expect(try colour(out, x: 0, y: 0) == .blue && colour(out, x: 0, y: 3) == .red)
    }

    @Test func orientationThreeTurnsTheImageUpsideDown() throws {
        let out = try #require(ThumbnailLoader.oriented(try splitImage(), orientation: 3))
        #expect(out.width == 4 && out.height == 2)
        #expect(try colour(out, x: 0, y: 0) == .blue && colour(out, x: 3, y: 0) == .red)
    }

    @Test func orientationTwoMirrorsLeftToRight() throws {
        let out = try #require(ThumbnailLoader.oriented(try splitImage(), orientation: 2))
        #expect(try colour(out, x: 0, y: 0) == .blue && colour(out, x: 3, y: 0) == .red)
    }

    // MARK: Round trip through a JPEG written with known EXIF

    @Test func readsBackExifWrittenIntoASyntheticJPEG() throws {
        let tree = try TempFolder()
        let url = tree.url.appendingPathComponent("synthetic.JPG")
        try writeJPEG(to: url, orientation: 6)

        let t0 = try ThumbnailLoader.load(url)

        #expect(t0.exif.orientation == 6)
        #expect(t0.exif.iso == 800)
        #expect(t0.exif.fNumber == 2.8)
        #expect(t0.exif.focalLength == 23)
        #expect(t0.exif.captureTime == CaptureTime(dateTime: "2026:09:20 10:11:12", subsecond: "45"))
        let seconds = try #require(t0.exif.exposureTime?.value)
        #expect(abs(seconds - 1.0 / 250.0) < 0.000_01)
        let image = try #require(t0.image)
        #expect(image.height > image.width, "orientation 6 thumbnail should come back portrait")
    }

    @Test func readsFurtherWhenTheExifStartsAfterTheFirst64KB() throws {
        let tree = try TempFolder()
        let plain = tree.url.appendingPathComponent("plain.JPG")
        try writeJPEG(to: plain, orientation: 1)
        // Insert two 40 KB comment segments after SOI, pushing APP1 past the first 64 KB.
        var bytes = [UInt8](try Data(contentsOf: plain))
        let comment: [UInt8] = [0xFF, 0xFE, 0x9C, 0x42] + [UInt8](repeating: 0x20, count: 40_000)
        bytes.insert(contentsOf: comment + comment, at: 2)
        let pushed = tree.url.appendingPathComponent("pushed.JPG")
        try Data(bytes).write(to: pushed)

        let t0 = try ThumbnailLoader.load(pushed)

        #expect(t0.exif.iso == 800)
        #expect(t0.image != nil)
    }
}

// MARK: Helpers

private enum Colour { case red, blue, other }

/// A 4 × 2 image: left two columns red, right two columns blue.
private func splitImage() throws -> CGImage {
    let context = try #require(rgbaContext(width: 4, height: 2))
    context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
    context.setFillColor(red: 0, green: 0, blue: 1, alpha: 1)
    context.fill(CGRect(x: 2, y: 0, width: 2, height: 2))
    return try #require(context.makeImage())
}

private func rgbaContext(width: Int, height: Int) -> CGContext? {
    CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
}

/// Colour of the pixel at (x, y), with y = 0 the top row.
private func colour(_ image: CGImage, x: Int, y: Int) throws -> Colour {
    let context = try #require(rgbaContext(width: image.width, height: image.height))
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    let data = try #require(context.data).assumingMemoryBound(to: UInt8.self)
    let pixel = data + (y * image.width + x) * 4
    if pixel[0] > 200 && pixel[2] < 60 { return .red }
    if pixel[2] > 200 && pixel[0] < 60 { return .blue }
    return .other
}

/// Writes a 640 × 480 split-colour JPEG with EXIF and an embedded thumbnail.
private func writeJPEG(to url: URL, orientation: Int) throws {
    let context = try #require(rgbaContext(width: 640, height: 480))
    context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: 320, height: 480))
    context.setFillColor(red: 0, green: 0, blue: 1, alpha: 1)
    context.fill(CGRect(x: 320, y: 0, width: 320, height: 480))
    let image = try #require(context.makeImage())
    let destination = try #require(
        CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
    let exif: [CFString: Any] = [
        kCGImagePropertyExifExposureTime: 1.0 / 250.0,
        kCGImagePropertyExifFNumber: 2.8,
        kCGImagePropertyExifISOSpeedRatings: [800],
        kCGImagePropertyExifFocalLength: 23.0,
        kCGImagePropertyExifDateTimeOriginal: "2026:09:20 10:11:12",
        kCGImagePropertyExifSubsecTimeOriginal: "45",
    ]
    let properties: [CFString: Any] = [
        kCGImagePropertyOrientation: orientation,
        kCGImagePropertyExifDictionary: exif,
        kCGImageDestinationEmbedThumbnail: true,
    ]
    CGImageDestinationAddImage(destination, image, properties as CFDictionary)
    #expect(CGImageDestinationFinalize(destination))
}

private func syntheticJPEGFile(in tree: TempFolder) throws -> URL {
    let url = tree.url.appendingPathComponent("synthetic-\(UUID().uuidString).JPG")
    try writeJPEG(to: url, orientation: 1)
    return url
}

/// A temporary folder removed when released.
private final class TempFolder {
    let url: URL
    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("FujiCullImagingTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    deinit {
        do { try FileManager.default.removeItem(at: url) } catch {
            FileHandle.standardError.write(Data("TempFolder: could not remove \(url.path): \(error)\n".utf8))
        }
    }
}
