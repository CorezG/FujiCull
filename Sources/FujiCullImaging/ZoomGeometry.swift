import CoreGraphics

/// Where the 100% image sits under the mouse (R12, D5): the point of the photo under the cursor is the same
/// fraction across the photo as the cursor is across the view, so moving to an edge reveals that edge.
/// An axis where the photo is smaller than the view stays centred. Coordinates are view points, y up.
public enum ZoomGeometry {
    /// The most the scroll wheel zooms in: 200% (R12 asks for 100%; a little beyond helps judge focus).
    public static let maxScale: CGFloat = 2

    /// The frame at 100%.
    public static func frame(imageSize: CGSize, viewSize: CGSize, mouse: CGPoint) -> CGRect {
        frame(imageSize: imageSize, scale: 1, viewSize: viewSize, mouse: mouse)
    }

    /// The frame at `scale` × 100% (`imageSize` is the 100% size in points).
    public static func frame(imageSize: CGSize, scale: CGFloat, viewSize: CGSize, mouse: CGPoint) -> CGRect {
        let imageSize = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(
            x: origin(image: imageSize.width, view: viewSize.width, mouse: mouse.x),
            y: origin(image: imageSize.height, view: viewSize.height, mouse: mouse.y),
            width: imageSize.width, height: imageSize.height)
    }

    /// The largest scale that shows the whole photo, never above 100%: the zoom level that "fit" means.
    public static func fitScale(imageSize: CGSize, viewSize: CGSize) -> CGFloat {
        guard imageSize.width > 0, imageSize.height > 0 else { return 1 }
        return min(1, viewSize.width / imageSize.width, viewSize.height / imageSize.height)
    }

    /// The zoom after scrolling `steps` (positive = in) from `current` (nil = fit). Returns nil once it's
    /// back at or below fit, and never exceeds `maxScale`.
    public static func scale(after steps: CGFloat, from current: CGFloat?, fit: CGFloat) -> CGFloat? {
        let next = (current ?? fit) * exp(steps * 0.1)
        guard next > fit * 1.001 else { return nil }
        return min(next, maxScale)
    }

    /// 100% means one image pixel per device pixel, so a Retina screen shows it at half its pixel size in points.
    public static func pointSize(pixelWidth: Int, pixelHeight: Int, scale: CGFloat) -> CGSize {
        CGSize(width: CGFloat(pixelWidth) / scale, height: CGFloat(pixelHeight) / scale)
    }

    private static func origin(image: CGFloat, view: CGFloat, mouse: CGFloat) -> CGFloat {
        guard image > view, view > 0 else { return (view - image) / 2 }
        let position = min(max(mouse, 0), view)
        return position - position / view * image
    }
}
