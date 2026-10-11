import Foundation

/// One Apply from start to finish, off the main thread: pre-flight, copy, confirm, remove (DESIGN §5.7).
/// The screens drive it in that order and show what each step returns; it holds the journal, the archive
/// lock and the open folders for as long as it lives.
///
/// To cancel, cancel the task that is awaiting `copy` or `finish`.
public actor ApplyRun {
    public struct Setup: Sendable {
        /// The card's root: the session's identity base.
        public var cardRoot: URL
        /// The frames the owner culled, as scanned when the card was opened.
        public var frames: [Frame]
        public var marks: [FrameID: FrameMark]
        public var captureTimes: [FrameID: CaptureTime]
        public var source: ApplyInput.Source
        public var destination: Ledger.Destination
        /// Where each archive volume is mounted right now, by volume UUID.
        public var archiveRoots: [String: String]
        public var journalURL: URL
        public var locksDirectory: URL

        public init(
            cardRoot: URL, frames: [Frame], marks: [FrameID: FrameMark], captureTimes: [FrameID: CaptureTime],
            source: ApplyInput.Source, destination: Ledger.Destination, archiveRoots: [String: String], journalURL: URL,
            locksDirectory: URL
        ) {
            self.cardRoot = cardRoot
            self.frames = frames
            self.marks = marks
            self.captureTimes = captureTimes
            self.source = source
            self.destination = destination
            self.archiveRoots = archiveRoots
            self.journalURL = journalURL
            self.locksDirectory = locksDirectory
        }
    }

    public enum StartError: Error, Equatable, Sendable {
        /// The card no longer holds exactly the files that were culled (SR16). Close it and open it again.
        case cardChanged
        /// Another Apply is using this trip folder (SR3).
        case busy
        case stopped(ApplyStop)
        case failed(String)
    }

    /// What pre-flight shows before anything is copied.
    public struct Preflight: Equatable, Sendable {
        public let plan: ApplyPlan
        public let recovery: ApplyExecutor.Recovery
        public let keepers: Int
        public let favourites: Int
        /// Keepers flagged for editing whose RAW will be filed under `RAW/Edit Me` in this run (R28).
        public let toEdit: Int
        public let rejects: Int
        public let undecided: Int
        public let videos: Int
        public var copyBytes: Int64 { plan.copies.reduce(0) { $0 + $1.size } }
    }

    /// The state after copying: what was done, what the archive holds, and what may now be removed.
    public struct CopyReport: Equatable, Sendable {
        public let outcome: ApplyExecutor.CopyOutcome
        public let check: ApplyExecutor.FinalCheck
        public let blockers: [ApplyExecutor.Gate.Blocker]
        /// What the owner is asked to confirm; nil when there is nothing to remove or the gate is closed.
        public let confirmation: ApplyExecutor.Confirmation?
    }

    private let executor: ApplyExecutor
    private let lock: ArchiveLock
    private let setup: Setup
    private var plan: ApplyPlan?
    private var recovery = ApplyExecutor.Recovery()
    private var copied: (outcome: ApplyExecutor.CopyOutcome, check: ApplyExecutor.FinalCheck, gate: ApplyExecutor.Gate)?

    public init(fs: any FileSystem = LocalFileSystem(), setup: Setup) throws(StartError) {
        self.setup = setup
        // Apply works from a fresh look at the card, and only if it is still what was culled (SR16).
        let scan: ScanResult
        do {
            scan = try SourceScanner.scan(setup.cardRoot, identityBase: setup.cardRoot)
        } catch {
            throw .failed("The card couldn't be read: \(error)")
        }
        guard scan.frames == setup.frames else { throw .cardChanged }
        do {
            lock = try ArchiveLock.acquire(in: setup.locksDirectory, for: setup.destination)
        } catch {
            throw error == .busy ? .busy : .failed("\(error)")
        }
        let opened: (journal: LedgerJournal, records: [LedgerRecord])
        do {
            opened = try LedgerJournal.open(at: setup.journalURL)
        } catch {
            throw .stopped(.journal(error))
        }
        do {
            executor = try ApplyExecutor(
                fs: fs, journal: opened.journal, records: opened.records,
                card: try fs.openFolder(at: setup.cardRoot.path),
                context: ApplyExecutor.Context(
                    frames: scan.frames, videos: scan.videos, otherFiles: scan.otherFiles, marks: setup.marks,
                    captureTimes: setup.captureTimes, source: setup.source, destination: setup.destination,
                    archiveRoots: setup.archiveRoots))
        } catch let stop as ApplyStop {
            throw .stopped(stop)
        } catch {
            throw .failed("The card couldn't be opened: \(error)")
        }
    }

    /// Settles whatever an interrupted run left, then plans this one. Nothing is copied or removed.
    public func preflight(copyAgain: Set<Owner> = []) throws(ApplyStop) -> Preflight {
        recovery = try executor.recover()
        let plan = try executor.makePlan(copyAgain: copyAgain)
        self.plan = plan
        let decisions = setup.frames.map { setup.marks[$0.id] ?? FrameMark() }
        return Preflight(
            plan: plan, recovery: recovery, keepers: decisions.count { $0.decision == .keep },
            favourites: decisions.count { $0.isFavourite },
            toEdit: plan.copies.count { $0.to.subfolder == ArchiveLayout.rawToEdit },
            rejects: decisions.count { $0.decision == .reject },
            undecided: decisions.count { $0.decision == .undecided },
            videos: plan.copies.count { $0.role == .video })
    }

    /// Removes the leftover partial files pre-flight listed, once the owner has agreed.
    public func removeStrayPartials() throws(ApplyStop) {
        try executor.removeStrayPartials(recovery.strayPartials)
        recovery.strayPartials = []
    }

    /// Copies, verifies and tags, then checks every keeper on the archive and works out whether anything
    /// may be removed. Deletes nothing. `addToExistingFolder` is the owner's answer when the trip folder
    /// already exists and this card's journal doesn't know it.
    public func copy(
        addToExistingFolder: Bool = false,
        onProgress: @Sendable (_ bytesDone: Int64, _ bytesTotal: Int64) -> Void = { _, _ in }
    ) throws(ApplyStop) -> CopyReport {
        guard var plan else { throw .gateClosed }
        if plan.destinationState == .existsNotOurs, !addToExistingFolder {
            throw .destinationAppeared(setup.destination)
        }

        var outcome = executor.copy(plan, onProgress: onProgress)
        // A name taken between planning and copying skips its frame. Planning again sees the name and gives
        // the frame a new one (SR26); a few passes are enough for anything but a folder under constant change.
        var passes = 1
        while outcome.stopped == nil, outcome.skipped.contains(where: { $0.reason == .nameConflict }), passes < 3 {
            passes += 1
            plan = try executor.makePlan()
            let again = executor.copy(plan, onProgress: onProgress)
            outcome.copied += again.copied
            outcome.tagFailures += again.tagFailures
            outcome.skipped = again.skipped
            outcome.stopped = again.stopped
        }
        self.plan = plan

        let check = try executor.finalCheck()
        let gate = try executor.gate(plan: plan, outcome: outcome, check: check)
        copied = (outcome, check, gate)
        let toTrash = plan.removals.flatMap(\.files)
        let toDelete = plan.cardDeletes.flatMap(\.paths)
        let nothing = toTrash.isEmpty && toDelete.isEmpty
        return CopyReport(
            outcome: outcome, check: check, blockers: gate.blockers,
            confirmation: gate.allowsRemoval && !nothing
                ? ApplyExecutor.Confirmation(toTrash: toTrash, toDelete: toDelete, deleteMode: plan.deleteMode) : nil)
    }

    /// Removes what was confirmed, if the gate allows it, and returns the summary of the whole run.
    public func finish(confirmed: Bool) -> ApplySummary {
        guard let plan, let copied else {
            return ApplySummary(
                plan: plan ?? ApplyPlan(), copy: ApplyExecutor.CopyOutcome(), check: ApplyExecutor.FinalCheck(),
                gate: nil,
                removal: nil)
        }
        let removal = executor.removeAndDelete(plan, gate: copied.gate, confirm: { _ in confirmed })
        return ApplySummary(plan: plan, copy: copied.outcome, check: copied.check, gate: copied.gate, removal: removal)
    }

    /// The journal as it stands, for the app to bring its session up to date afterwards.
    public var ledger: Ledger { executor.ledger }
}
