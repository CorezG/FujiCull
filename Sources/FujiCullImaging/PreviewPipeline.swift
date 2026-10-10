import CoreGraphics
import Foundation
import ImageIO

/// T1, the display tier: the whole JPG decoded to fit the window (DESIGN §5.4).
public enum PreviewPipeline {
    public enum DecodeError: Error, Equatable {
        case notAnImage
    }

    /// Decodes every pixel of `jpeg`, upright.
    public static func decodeFull(_ jpeg: Data) throws -> CGImage {
        try decodeDisplay(jpeg, maxPixelSize: Int.max)
    }

    /// Decodes `jpeg` upright (EXIF orientation applied) for a screen whose long edge is `maxPixelSize`.
    ///
    /// JPEG can decode at 1/2, 1/4 or 1/8 size directly, several times faster than decoding and scaling
    /// (on Fuji SD: 29 ms instead of 88 ms). So this uses the largest of those reductions that is still at
    /// least `maxPixelSize` (2736 px for a 2560 px screen at size M) and lets the layer scale the rest.
    /// Images that are already small enough are decoded as they are; it never upscales.
    public static func decodeDisplay(_ jpeg: Data, maxPixelSize: Int) throws -> CGImage {
        guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? Int,
            let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { throw DecodeError.notAnImage }
        let longEdge = max(width, height)
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        let factor = [8, 4, 2].first { longEdge / $0 >= maxPixelSize } ?? 1

        if factor == 1, longEdge > maxPixelSize {
            // No whole reduction fits: decode and scale in one step.
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
                kCGImageSourceShouldCacheImmediately: true,
            ]
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
                throw DecodeError.notAnImage
            }
            return image
        }
        let options: [CFString: Any] = [
            kCGImageSourceSubsampleFactor: factor, kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let decoded = CGImageSourceCreateImageAtIndex(source, 0, options as CFDictionary),
            let upright = ThumbnailLoader.oriented(decoded, orientation: orientation)
        else { throw DecodeError.notAnImage }
        return upright
    }
}
