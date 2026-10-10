import Testing

@testable import FujiCullImaging

// Which frames to load around the cursor, and how urgently (DESIGN §5.4: current, +1…+3, −1).
@Suite struct PrefetchWindowTests {

    @Test func loadsTheCurrentFrameThenThreeAheadThenOneBehind() {
        let requests = PrefetchWindow.requests(cursor: 10, count: 100)

        #expect(requests.map(\.index) == [10, 11, 12, 13, 9])
        #expect(requests.map(\.priority) == [.current, .ahead1, .ahead2, .ahead3, .behind1])
    }

    @Test func staysInsideTheListAtTheStart() {
        #expect(PrefetchWindow.requests(cursor: 0, count: 100).map(\.index) == [0, 1, 2, 3])
    }

    @Test func staysInsideTheListAtTheEnd() {
        #expect(PrefetchWindow.requests(cursor: 99, count: 100).map(\.index) == [99, 98])
    }

    @Test func aShortListLoadsWhatExists() {
        #expect(PrefetchWindow.requests(cursor: 0, count: 2).map(\.index) == [0, 1])
    }

    @Test func anEmptyListOrOutOfRangeCursorLoadsNothing() {
        #expect(PrefetchWindow.requests(cursor: 0, count: 0).isEmpty)
        #expect(PrefetchWindow.requests(cursor: 5, count: 3).isEmpty)
        #expect(PrefetchWindow.requests(cursor: -1, count: 3).isEmpty)
    }
}
