import CoreGraphics
import Foundation
import FujiCullCore
import ImageIO

/// T0 as read from the card: the embedded thumbnail still compressed (about 9 KB), plus EXIF.
/// Kept like this for every frame; only visible ones are decoded (DESIGN §5.4 memory budget).
public struct ThumbnailHeader: Sendable {
    public let thumbnailJPEG: Data?
    public let exif: ExifSummary
}

/// The T0 tier: the camera's embedded thumbnail, upright, plus EXIF (DESIGN §5.4).
public struct Thumbnail {
    /// nil when the file has no usable embedded thumbnail.
    public let image: CGImage?
    public let exif: ExifSummary
}

public enum ThumbnailLoader {
    public enum LoadError: Error, Equatable {
        case notJPEG(path: String)
    }

    /// The X-T50 APP1 segment is 65,468 bytes, so one 64 KB read normally covers it (spike S1).
    static let firstRead = 65_536
    /// Upper bound when another segment pushes EXIF further in.
    static let maxRead = 262_144

    /// Reads only the start of the file, parses EXIF, decodes the embedded thumbnail and turns it upright.
    public static func load(_ url: URL) throws -> Thumbnail {
        let header = try loadHeader(url)
        let image = header.thumbnailJPEG.flatMap { decodeThumbnail($0, orientation: header.exif.orientation) }
        return Thumbnail(image: image, exif: header.exif)
    }

    /// Decodes a compressed T0 thumbnail and turns it upright.
    public static func decodeThumbnail(_ jpeg: Data, orientation: Int) -> CGImage? {
        decode(jpeg).flatMap { oriented($0, orientation: orientation) }
    }

    /// Reads only the start of the file and returns the thumbnail still compressed, plus EXIF. For a RAF,
    /// reads the start of its embedded JPEG instead (RAF-only frames, R4).
    public static func loadHeader(_ url: URL) throws -> ThumbnailHeader {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var head = try handle.read(upToCount: firstRead) ?? Data()
        // The JPEG to parse: the file itself, or the preview embedded in a RAF, which may not run to the end.
        var jpegLimit = Int.max
        if RAFHeader.isRAF(head) {
            guard let raf = RAFHeader.parse(head) else {
                return ThumbnailHeader(thumbnailJPEG: nil, exif: ExifSummary())
            }
            try handle.seek(toOffset: UInt64(raf.jpegOffset))
            jpegLimit = raf.jpegLength
            head = try handle.read(upToCount: min(firstRead, jpegLimit)) ?? Data()
        }
        var result = ExifParser.parse(jpegHead: head)
        // The parser only learns how far EXIF extends one segment at a time, so keep reading until it has
        // enough, the file ends, or the cap is reached.
        while case .needMoreBytes(let needed) = result, needed <= min(maxRead, jpegLimit),
            let more = try handle.read(upToCount: needed - head.count), !more.isEmpty
        {
            head += more
            result = ExifParser.parse(jpegHead: head)
        }

        switch result {
        case .notJPEG:
            throw LoadError.notJPEG(path: url.path)
        case .parsed(let exif):
            return ThumbnailHeader(thumbnailJPEG: exif.thumbnail.map { head.subdata(in: $0) }, exif: exif)
        case .needMoreBytes, .noExif, .malformed:
            return ThumbnailHeader(thumbnailJPEG: nil, exif: ExifSummary())
        }
    }

    private static func decode(_ jpeg: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// Returns `image` drawn the way EXIF `orientation` (1–8) says it should be seen.
    /// The embedded thumbnail is stored unrotated, so portrait frames need this (T4).
    static func oriented(_ image: CGImage, orientation: Int) -> CGImage? {
        guard (2...8).contains(orientation) else { return image }
        let w = CGFloat(image.width)
        let h = CGFloat(image.height)
        let swapsAxes = orientation >= 5
        let outWidth = swapsAxes ? image.height : image.width
        let outHeight = swapsAxes ? image.width : image.height

        // Maps a point of the stored image (y up) to where it belongs in the upright output.
        let transform: CGAffineTransform
        switch orientation {
        case 2: transform = CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: w, ty: 0)
        case 3: transform = CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: w, ty: h)
        case 4: transform = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: h)
        case 5: transform = CGAffineTransform(a: 0, b: -1, c: -1, d: 0, tx: h, ty: w)
        case 6: transform = CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: w)
        case 7: transform = CGAffineTransform(a: 0, b: 1, c: 1, d: 0, tx: 0, ty: 0)
        default: transform = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: h, ty: 0)  // 8
        }

        guard
            let context = CGContext(
                data: nil, width: outWidth, height: outHeight, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        context.concatenate(transform)
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return context.makeImage()
    }
}
