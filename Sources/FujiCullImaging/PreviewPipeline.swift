import CoreGraphics
import Foundation
import ImageIO

/// T1, the display tier: the whole JPG decoded to fit the window (DESIGN §5.4).
public enum PreviewPipeline {
    public enum DecodeError: Error, Equatable {
        case notAnImage
    }

    /// Reads the whole file, then decodes it with `decodeDisplay`. Blocking: call it through `CardReader`.
    public static func loadDisplay(_ url: URL, maxPixelSize: Int) throws -> CGImage {
        try decodeDisplay(Data(contentsOf: url), maxPixelSize: maxPixelSize)
    }

    /// Reads the whole file and decodes every pixel, upright: T2, for 100% zoom only (DESIGN §5.4).
    /// About 45 ms to decode at size M on the M2 (spike S4). Blocking: call it through `CardReader`.
    public static func loadFull(_ url: URL) throws -> CGImage {
        try decodeFull(Data(contentsOf: url))
    }

    /// Decodes every pixel of `jpeg`, upright.
    public static func decodeFull(_ jpeg: Data) throws -> CGImage {
        try decodeDisplay(jpeg, maxPixelSize: Int.max)
    }

    /// Decodes `jpeg` upright (EXIF orientation applied) with its long edge at most `maxPixelSize`.
    /// Never upscales.
    public static func decodeDisplay(_ jpeg: Data, maxPixelSize: Int) throws -> CGImage {
        guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? Int,
            let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { throw DecodeError.notAnImage }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: min(maxPixelSize, max(width, height)),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw DecodeError.notAnImage
        }
        return image
    }
}
