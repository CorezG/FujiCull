import Testing

@testable import FujiCullImaging

// The background T0 pass fills thumbnails near the cursor first (DESIGN §5.4).
@Suite struct MetadataPassTests {

    @Test func startsAtTheCursorAndWrapsAround() {
        #expect(MetadataPass.order(count: 6, startingAt: 3) == [3, 4, 5, 0, 1, 2])
    }

    @Test func coversEveryFrameExactlyOnce() {
        let order = MetadataPass.order(count: 2_091, startingAt: 1_500)

        #expect(order.count == 2_091)
        #expect(Set(order).count == 2_091)
    }

    @Test func anOutOfRangeStartBeginsAtTheFirstFrame() {
        #expect(MetadataPass.order(count: 3, startingAt: 7) == [0, 1, 2])
        #expect(MetadataPass.order(count: 0, startingAt: 0).isEmpty)
    }
}
