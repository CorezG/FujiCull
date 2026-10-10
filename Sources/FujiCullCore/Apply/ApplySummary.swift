import Foundation

/// What one Apply run did, for the summary screen (DESIGN §5.7 step 9). Every number comes from what was
/// actually done or actually found, never from what was planned.
public struct ApplySummary: Equatable, Sendable {
    public var copiedFiles: Int
    public var copiedBytes: Int64
    /// Keep frames and videos found whole on the archive by the final check (SR28).
    public var keepersOnArchive: Int
    public var problems: [ApplyExecutor.FinalCheck.Problem]
    public var skippedCopies: [ApplyExecutor.CopyOutcome.Skipped]
    public var tagFailures: [ArchiveLocation]
    /// Files left in place when a frame was copied again under a new name (SR26).
    public var duplicatesLeft: [ArchiveLocation]
    public var trashed: [ApplyExecutor.RemovalOutcome.Trashed]
    public var deletedFromCard: [String]
    public var skippedRemovals: [ApplyExecutor.RemovalOutcome.SkippedFrame]
    public var notDeleted: [ApplyPlan.NotDeleted]
    /// Undecided frames and other files: still on the card, not archived. Formatting the card loses them.
    public var leftOnCard: ApplyPlan.LeftOnCard
    /// Why nothing was removed, if the gate was closed.
    public var gateBlockers: [ApplyExecutor.Gate.Blocker]
    public var declined: Bool
    public var stopped: ApplyStop?

    public init(
        plan: ApplyPlan, copy: ApplyExecutor.CopyOutcome, check: ApplyExecutor.FinalCheck, gate: ApplyExecutor.Gate?,
        removal: ApplyExecutor.RemovalOutcome?
    ) {
        let copied = Set(copy.copied)
        copiedFiles = copy.copied.count
        copiedBytes = plan.copies.filter { copied.contains($0.to) }.reduce(0) { $0 + $1.size }
        keepersOnArchive = check.keepersOnArchive
        problems = check.problems
        skippedCopies = copy.skipped
        tagFailures = copy.tagFailures
        duplicatesLeft = plan.superseded
        trashed = removal?.trashed ?? []
        deletedFromCard = removal?.deleted ?? []
        skippedRemovals = removal?.skipped ?? []
        notDeleted = plan.notDeleted
        leftOnCard = plan.leftOnCard
        gateBlockers = gate?.blockers ?? []
        declined = removal?.declined ?? false
        stopped = copy.stopped ?? removal?.stopped
    }
}
