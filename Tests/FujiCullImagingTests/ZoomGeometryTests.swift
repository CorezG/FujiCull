import CoreGraphics
import Testing

@testable import FujiCullImaging

// Where the 100% image sits for a given mouse position (R12, D5).
@Suite struct ZoomGeometryTests {
    let view = CGSize(width: 1000, height: 600)
    let image = CGSize(width: 2736, height: 1824)  // a 5472 × 3648 frame on a 2× Retina screen, in points

    @Test func theMouseAtTheCentreShowsTheCentreOfThePhoto() {
        let frame = ZoomGeometry.frame(imageSize: image, viewSize: view, mouse: CGPoint(x: 500, y: 300))

        #expect(frame.midX == 500 && frame.midY == 300)
        #expect(frame.size == image)
    }

    @Test func theMouseAtTheLeftEdgeShowsTheLeftEdgeOfThePhoto() {
        let frame = ZoomGeometry.frame(imageSize: image, viewSize: view, mouse: CGPoint(x: 0, y: 300))

        #expect(frame.minX == 0)
    }

    @Test func theMouseAtTheTopRightShowsTheTopRightCorner() {
        let frame = ZoomGeometry.frame(imageSize: image, viewSize: view, mouse: CGPoint(x: 1000, y: 600))

        #expect(frame.maxX == 1000 && frame.maxY == 600)
    }

    @Test func aPhotoNarrowerThanTheViewStaysCentredOnThatAxis() {
        let portrait = CGSize(width: 400, height: 1200)
        let frame = ZoomGeometry.frame(imageSize: portrait, viewSize: view, mouse: CGPoint(x: 0, y: 0))

        #expect(frame.midX == 500, "400 pt wide in a 1000 pt view: centred, not pinned to the mouse")
        #expect(frame.minY == 0)
    }

    @Test func aMouseOutsideTheViewIsClampedToItsEdges() {
        let frame = ZoomGeometry.frame(imageSize: image, viewSize: view, mouse: CGPoint(x: -50, y: 900))

        #expect(frame.minX == 0 && frame.maxY == 600)
    }

    @Test func atHalfZoomThePhotoIsHalfItsFullSize() {
        let frame = ZoomGeometry.frame(imageSize: image, scale: 0.5, viewSize: view, mouse: CGPoint(x: 500, y: 300))

        #expect(frame.size == CGSize(width: 1368, height: 912))
        #expect(frame.midX == 500 && frame.midY == 300)
    }

    @Test func fitScaleIsTheLargestScaleThatShowsTheWholePhoto() {
        #expect(ZoomGeometry.fitScale(imageSize: image, viewSize: view) == CGFloat(600) / 1824)
        #expect(ZoomGeometry.fitScale(imageSize: CGSize(width: 400, height: 300), viewSize: view) == 1)
    }

    @Test func scrollingUpZoomsInAndDownZoomsOut() throws {
        let fit = 0.3
        let zoomedIn = try #require(ZoomGeometry.scale(after: 5, from: nil, fit: fit))
        let zoomedOut = try #require(ZoomGeometry.scale(after: -2, from: zoomedIn, fit: fit))

        #expect(zoomedIn > fit)
        #expect(zoomedOut < zoomedIn)
    }

    @Test func zoomingOutToFitReturnsToFitMode() {
        #expect(ZoomGeometry.scale(after: -50, from: 0.5, fit: 0.3) == nil)
    }

    @Test func zoomStopsAtTwoHundredPercent() {
        #expect(ZoomGeometry.scale(after: 500, from: 1.9, fit: 0.3) == ZoomGeometry.maxScale)
        #expect(ZoomGeometry.maxScale == 2)
    }

    @Test func aPhotoSmallerThanTheViewCanStillBeZoomedFromFullSize() throws {
        // Fit scale is capped at 100%, so zooming in starts from 100%.
        let zoomed = try #require(ZoomGeometry.scale(after: 5, from: nil, fit: 1))
        #expect(zoomed > 1)
    }

    @Test func pointSizeIsPixelsDividedByTheScreenScale() {
        #expect(ZoomGeometry.pointSize(pixelWidth: 5472, pixelHeight: 3648, scale: 2) == image)
    }
}
