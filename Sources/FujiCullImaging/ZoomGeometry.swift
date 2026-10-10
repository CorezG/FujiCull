import CoreGraphics

/// Where the 100% image sits under the mouse (R12, D5): the point of the photo under the cursor is the same
/// fraction across the photo as the cursor is across the view, so moving to an edge reveals that edge.
/// An axis where the photo is smaller than the view stays centred. Coordinates are view points, y up.
public enum ZoomGeometry {
    public static func frame(imageSize: CGSize, viewSize: CGSize, mouse: CGPoint) -> CGRect {
        CGRect(
            x: origin(image: imageSize.width, view: viewSize.width, mouse: mouse.x),
            y: origin(image: imageSize.height, view: viewSize.height, mouse: mouse.y),
            width: imageSize.width, height: imageSize.height)
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
