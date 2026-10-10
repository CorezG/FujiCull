import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
import os

@testable import FujiCullImaging

/// Records the order in which jobs ran, from any thread.
private final class RunLog: Sendable {
    private let entries = OSAllocatedUnfairLock<[String]>(initialState: [])
    func append(_ key: String) { entries.withLock { $0.append(key) } }
    var all: [String] { entries.withLock { $0 } }
}

/// Holds the reader busy until released, so later requests queue up behind it.
private struct Gate: Sendable {
    let release = DispatchSemaphore(value: 0)

    /// A job that logs that it has started, then blocks the reader's queue until released.
    func job(log: RunLog, key: String) -> @Sendable () -> String {
        {
            log.append(key)
            release.wait()
            return key
        }
    }
}

private func waitUntil(_ condition: @escaping @Sendable () async -> Bool) async throws {
    for _ in 0..<2_000 {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(1))
    }
    Issue.record("condition not met within 2 s")
}

// CardReader: one read at a time, highest priority first, stale requests cancelled (DESIGN §5.4, T5).
@Suite struct CardReaderTests {

    @Test func runsQueuedRequestsInPriorityOrder() async throws {
        let reader = CardReader()
        let log = RunLog()
        let gate = Gate()
        let blocker = Task {
            try await reader.submit(key: "busy", priority: .current, work: gate.job(log: log, key: "busy"))
        }
        try await waitUntil { log.all.contains("busy") }

        let queued: [(String, ReadPriority)] = [
            ("background", .background), ("thumb", .thumbnail), ("behind1", .behind1),
            ("ahead3", .ahead3), ("ahead1", .ahead1), ("current", .current), ("ahead2", .ahead2),
        ]
        var tasks: [Task<String, Error>] = []
        for (key, priority) in queued {
            tasks.append(
                Task {
                    try await reader.submit(key: key, priority: priority) {
                        log.append(key)
                        return key
                    }
                })
        }
        try await waitUntil { await reader.pendingCount == queued.count }
        gate.release.signal()

        _ = try await blocker.value
        for task in tasks { _ = try await task.value }
        #expect(log.all == ["busy", "current", "ahead1", "ahead2", "ahead3", "behind1", "thumb", "background"])
    }

    @Test func equalPrioritiesRunInTheOrderTheyWereSubmitted() async throws {
        let reader = CardReader()
        let log = RunLog()
        let gate = Gate()
        let blocker = Task {
            try await reader.submit(key: "busy", priority: .current, work: gate.job(log: log, key: "busy"))
        }
        try await waitUntil { log.all.contains("busy") }

        var tasks: [Task<Void, Error>] = []
        for n in 1...3 {
            tasks.append(Task { try await reader.submit(key: "t\(n)", priority: .thumbnail) { log.append("t\(n)") } })
            try await waitUntil { await reader.pendingCount == n }
        }
        gate.release.signal()

        _ = try await blocker.value
        for task in tasks { try await task.value }
        #expect(log.all == ["busy", "t1", "t2", "t3"])
    }

    @Test func aCancelledRequestNeverRunsAndReportsCancellation() async throws {
        let reader = CardReader()
        let log = RunLog()
        let gate = Gate()
        let blocker = Task {
            try await reader.submit(key: "busy", priority: .current, work: gate.job(log: log, key: "busy"))
        }
        try await waitUntil { log.all.contains("busy") }

        let stale = Task { try await reader.submit(key: "DSCF0002", priority: .ahead1) { log.append("DSCF0002") } }
        let kept = Task { try await reader.submit(key: "DSCF0005", priority: .ahead2) { log.append("DSCF0005") } }
        try await waitUntil { await reader.pendingCount == 2 }
        await reader.cancelPending(except: ["DSCF0005"])
        gate.release.signal()

        _ = try await blocker.value
        try await kept.value
        await #expect(throws: CancellationError.self) { try await stale.value }
        #expect(log.all == ["busy", "DSCF0005"])
    }

    @Test func cancellingTheViewerWindowLeavesBackgroundWorkQueued() async throws {
        let reader = CardReader()
        let log = RunLog()
        let gate = Gate()
        let blocker = Task {
            try await reader.submit(key: "busy", priority: .current, work: gate.job(log: log, key: "busy"))
        }
        try await waitUntil { log.all.contains("busy") }

        let prefetch = Task { try await reader.submit(key: "t1:old", priority: .ahead1) { log.append("t1:old") } }
        let metadata = Task { try await reader.submit(key: "t0:42", priority: .background) { log.append("t0:42") } }
        try await waitUntil { await reader.pendingCount == 2 }
        await reader.cancelPending(except: [], upTo: .behind1)
        gate.release.signal()

        _ = try await blocker.value
        try await metadata.value
        await #expect(throws: CancellationError.self) { try await prefetch.value }
        #expect(log.all == ["busy", "t0:42"])
    }

    @Test func onlyOneRequestRunsAtATime() async throws {
        let reader = CardReader()
        let inFlight = OSAllocatedUnfairLock(initialState: (now: 0, peak: 0))
        try await withThrowingTaskGroup(of: Void.self) { group in
            for n in 0..<20 {
                group.addTask {
                    try await reader.submit(key: "\(n)", priority: .thumbnail) {
                        inFlight.withLock {
                            $0.now += 1
                            $0.peak = max($0.peak, $0.now)
                        }
                        usleep(500)
                        inFlight.withLock { $0.now -= 1 }
                    }
                }
            }
            try await group.waitForAll()
        }
        #expect(inFlight.withLock { $0.peak } == 1)
    }

    @Test func errorsFromAJobReachItsCaller() async {
        struct ReadFailed: Error {}
        let reader = CardReader()
        await #expect(throws: ReadFailed.self) {
            try await reader.submit(key: "bad", priority: .current) { () throws -> Int in throw ReadFailed() }
        }
    }
}

// PreviewCache: least-recently-used, bounded by bytes (DESIGN §5.4 memory budget).
@Suite struct PreviewCacheTests {

    @Test func evictsTheLeastRecentlyUsedEntryWhenOverBudget() {
        var cache = PreviewCache<String, String>(byteBudget: 100)
        cache.insert("a", for: "A", cost: 40)
        cache.insert("b", for: "B", cost: 40)
        cache.insert("c", for: "C", cost: 40)

        #expect(cache.value(for: "A") == nil)
        #expect(cache.value(for: "B") == "b")
        #expect(cache.value(for: "C") == "c")
        #expect(cache.totalCost == 80)
    }

    @Test func readingAnEntryMakesItRecent() {
        var cache = PreviewCache<String, String>(byteBudget: 100)
        cache.insert("a", for: "A", cost: 40)
        cache.insert("b", for: "B", cost: 40)
        _ = cache.value(for: "A")
        cache.insert("c", for: "C", cost: 40)

        #expect(cache.value(for: "A") == "a")
        #expect(cache.value(for: "B") == nil)
    }

    @Test func replacingAnEntryUpdatesItsCost() {
        var cache = PreviewCache<String, String>(byteBudget: 100)
        cache.insert("small", for: "A", cost: 10)
        cache.insert("large", for: "A", cost: 70)

        #expect(cache.value(for: "A") == "large")
        #expect(cache.totalCost == 70)
    }

    @Test func anEntryLargerThanTheWholeBudgetIsNotKept() {
        var cache = PreviewCache<String, String>(byteBudget: 100)
        cache.insert("a", for: "A", cost: 40)
        cache.insert("huge", for: "H", cost: 101)

        #expect(cache.value(for: "H") == nil)
        #expect(cache.value(for: "A") == "a")
    }

    @Test func removeAllEmptiesTheCache() {
        var cache = PreviewCache<String, String>(byteBudget: 100)
        cache.insert("a", for: "A", cost: 40)
        cache.removeAll()

        #expect(cache.value(for: "A") == nil)
        #expect(cache.totalCost == 0)
    }

    @Test func removeDropsOneEntry() {
        var cache = PreviewCache<String, String>(byteBudget: 100)
        cache.insert("a", for: "A", cost: 40)
        cache.insert("b", for: "B", cost: 30)
        cache.remove("A")

        #expect(cache.value(for: "A") == nil)
        #expect(cache.totalCost == 30)
    }
}

// PreviewPipeline: T1 display decode (DESIGN §5.4).
@Suite struct PreviewPipelineTests {

    @Test func decodesDownsampledToTheRequestedLongEdge() throws {
        let jpeg = try syntheticJPEG(width: 1200, height: 800, orientation: 1)

        let image = try PreviewPipeline.decodeDisplay(jpeg, maxPixelSize: 300)

        #expect(image.width == 300 && image.height == 200)
    }

    @Test func appliesTheExifOrientation() throws {
        let jpeg = try syntheticJPEG(width: 1200, height: 800, orientation: 6)

        let image = try PreviewPipeline.decodeDisplay(jpeg, maxPixelSize: 300)

        #expect(image.width == 200 && image.height == 300)
    }

    @Test func neverUpscalesASmallImage() throws {
        let jpeg = try syntheticJPEG(width: 400, height: 300, orientation: 1)

        let image = try PreviewPipeline.decodeDisplay(jpeg, maxPixelSize: 2560)

        #expect(image.width == 400 && image.height == 300)
    }

    @Test func rejectsDataThatIsNotAnImage() {
        #expect(throws: PreviewPipeline.DecodeError.self) {
            try PreviewPipeline.decodeDisplay(Data("not a jpeg".utf8), maxPixelSize: 300)
        }
    }

    @Test func readsAndDecodesAFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("FujiCull-\(UUID().uuidString).JPG")
        try syntheticJPEG(width: 1200, height: 800, orientation: 1).write(to: url)
        defer {
            do { try FileManager.default.removeItem(at: url) } catch { Issue.record("cleanup failed: \(error)") }
        }

        let image = try PreviewPipeline.loadDisplay(url, maxPixelSize: 600)

        #expect(image.width == 600)
    }
}

private func syntheticJPEG(width: Int, height: Int, orientation: Int) throws -> Data {
    let context = try #require(
        CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
    context.setFillColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let image = try #require(context.makeImage())
    let data = NSMutableData()
    let destination = try #require(
        CGImageDestinationCreateWithData(data as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: orientation] as CFDictionary)
    #expect(CGImageDestinationFinalize(destination))
    return data as Data
}
