import Dispatch

/// Priority of a card read; lower raw values run first (DESIGN §5.4).
public enum ReadPriority: Int, Comparable, Sendable {
    case current = 0
    case ahead1, ahead2, ahead3
    case behind1
    case thumbnail
    case background

    public static func < (lhs: ReadPriority, rhs: ReadPriority) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Serialises every read from the card: one at a time, highest priority first, ties in submission order.
/// Parallel random reads on an SD card are slower than serial ones (ADR-002), and the current frame must
/// never wait behind prefetches. The blocking work runs on one background queue, off the cooperative pool.
public actor CardReader {
    private struct Job {
        let key: String
        let priority: ReadPriority
        let sequence: Int
        let run: @Sendable () -> Void
        let cancel: @Sendable () -> Void
    }

    private let ioQueue = DispatchQueue(label: "FujiCull.CardReader", qos: .userInitiated)
    private var pending: [Job] = []
    private var busy = false
    private var nextSequence = 0

    public init() {}

    /// Number of requests waiting to start (not counting the one running).
    public var pendingCount: Int { pending.count }

    /// Queues `work` and returns its result. Throws `CancellationError` if the request is cancelled before
    /// it starts; a request that has started always runs to completion.
    public func submit<T: Sendable>(
        key: String, priority: ReadPriority, work: @escaping @Sendable () throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
            pending.append(
                Job(
                    key: key, priority: priority, sequence: nextSequence,
                    run: {
                        do { continuation.resume(returning: try work()) } catch { continuation.resume(throwing: error) }
                    },
                    cancel: { continuation.resume(throwing: CancellationError()) }))
            nextSequence += 1
            startNextIfIdle()
        }
    }

    /// Cancels every waiting request whose key isn't in `keep` and whose priority is at most `upTo`, for example
    /// the viewer's prefetch window when the cursor moves, while the background metadata pass carries on.
    public func cancelPending(except keep: Set<String>, upTo: ReadPriority = .background) {
        let (stay, drop) = pending.reduce(into: ([Job](), [Job]())) { result, job in
            if keep.contains(job.key) || job.priority > upTo { result.0.append(job) } else { result.1.append(job) }
        }
        pending = stay
        for job in drop { job.cancel() }
    }

    private func startNextIfIdle() {
        guard !busy,
            let index = pending.indices.min(by: {
                (pending[$0].priority, pending[$0].sequence) < (pending[$1].priority, pending[$1].sequence)
            })
        else { return }
        let job = pending.remove(at: index)
        busy = true
        ioQueue.async {
            job.run()
            Task { await self.finished() }
        }
    }

    private func finished() {
        busy = false
        startNextIfIdle()
    }
}
