import Foundation

/// The executor's destructive half (DESIGN §5.7 steps 5–8): the gate, moving rejected frames' archive
/// copies to the Trash, and deleting rejects from the card. Nothing here runs without a gate that allows
/// it, and a gate can only be made by this executor from its own final check.
extension ApplyExecutor {
    /// Whether anything may be removed (SR17).
    public struct Gate: Equatable, Sendable {
        public enum Blocker: Equatable, Sendable {
            case copyStopped(ApplyStop)
            case keeperNotOnArchive(FinalCheck.Problem)
            /// A keeper's archive file verified in an earlier run no longer hashes to what was recorded.
            case earlierCopyChanged(ArchiveLocation)
            case destinationUnreachable(Ledger.Destination)
        }

        public let blockers: [Blocker]
        public var allowsRemoval: Bool { blockers.isEmpty }

        fileprivate init(blockers: [Blocker]) {
            self.blockers = blockers
        }
    }

    /// What the owner is asked to confirm (step 6): every file that will leave the archive or the card.
    public struct Confirmation: Equatable, Sendable {
        public let toTrash: [ArchiveLocation]
        public let toDelete: [String]
        /// `.permanent` on a camera card: this cannot be undone.
        public let deleteMode: ApplyPlan.DeleteMode
    }

    public struct RemovalOutcome: Equatable, Sendable {
        public struct Trashed: Equatable, Sendable {
            public let location: ArchiveLocation
            public let trashPath: String?
        }

        public struct SkippedFrame: Equatable, Sendable {
            public enum Reason: Equatable, Sendable {
                case notRejected
                case noCaptureDate
                case cardLocked
                /// The plan names a file the journal doesn't record as this frame's.
                case notThisFramesFile(String)
                case archiveFileMissing(ArchiveLocation)
                case archiveFileChanged(ArchiveLocation)
                case trashFailed(ArchiveLocation)
                case cardFileChanged(String)
                case cardFileLocked(String)
                case deleteFailed(String)
                /// One file of the pair was deleted and the other couldn't be. Run Apply again.
                case pairSplit(remaining: String)
            }

            public let frame: FrameID
            public let reason: Reason
        }

        public var declined = false
        public var trashed: [Trashed] = []
        public var deleted: [String] = []
        public var skipped: [SkippedFrame] = []
        public var stopped: ApplyStop?
    }

    // MARK: Step 5: the gate (SR17)

    /// Removal is allowed only if the copy run finished, every destination was reachable, the final check
    /// found every keeper on the archive, and every keeper file that this run didn't itself hash from the
    /// device still hashes to what was recorded.
    public func gate(
        plan: ApplyPlan, outcome: CopyOutcome, check: FinalCheck, isCancelled: () -> Bool = { Task.isCancelled }
    ) throws(ApplyStop) -> Gate {
        var blockers: [Gate.Blocker] = []
        if let stopped = outcome.stopped { blockers.append(.copyStopped(stopped)) }
        blockers += plan.unreachableDestinations.map { .destinationUnreachable($0) }
        blockers += check.problems.map { .keeperNotOnArchive($0) }
        guard blockers.isEmpty else { return Gate(blockers: blockers) }

        for keeper in keeperFiles() {
            if isCancelled() { throw .cancelled }
            guard
                let archived = ledger.boundFile(
                    among: ledger.files(of: keeper.owner), role: keeper.role, to: keeper.file, captured: keeper.captured
                ),
                !verifiedThisRun.contains(archived.location),
                let folder = try folder(for: archived.location, create: false)
            else { continue }
            if try hash(archived.location.name, in: folder) != archived.sha256 {
                blockers.append(.earlierCopyChanged(archived.location))
            }
        }
        return Gate(blockers: blockers)
    }

    struct KeeperFile {
        let owner: Owner
        let role: FileRole
        let file: SourceFile
        let captured: CaptureTime?
    }

    /// Every card file that must be on the archive: each Keep frame's files, and every video.
    func keeperFiles() -> [KeeperFile] {
        var files: [KeeperFile] = []
        for frame in context.frames where context.marks[frame.id]?.decision == .keep {
            let captured = context.captureTimes[frame.id]
            if let raf = frame.raf {
                files.append(KeeperFile(owner: .frame(frame.id), role: .raw, file: raf, captured: captured))
            }
            if let jpg = frame.jpg {
                files.append(KeeperFile(owner: .frame(frame.id), role: .jpg, file: jpg, captured: captured))
            }
        }
        for video in context.videos {
            files.append(KeeperFile(owner: .video(video.relativePath), role: .video, file: video, captured: nil))
        }
        return files
    }

    // MARK: Steps 6–8: confirm, remove archive copies, delete from the card

    /// Asks for confirmation, then moves rejected frames' archive copies to the Trash, then deletes rejects
    /// from the card, in that order. If the gate doesn't allow removal, or `confirm` returns false,
    /// nothing is touched.
    public func removeAndDelete(
        _ plan: ApplyPlan, gate: Gate, confirm: (Confirmation) -> Bool, isCancelled: () -> Bool = { Task.isCancelled }
    ) -> RemovalOutcome {
        var outcome = RemovalOutcome()
        guard gate.allowsRemoval else {
            outcome.stopped = .gateClosed
            return outcome
        }
        let confirmation = Confirmation(
            toTrash: plan.removals.flatMap(\.files), toDelete: plan.cardDeletes.flatMap(\.paths),
            deleteMode: plan.deleteMode)
        if confirmation.toTrash.isEmpty && confirmation.toDelete.isEmpty { return outcome }
        guard confirm(confirmation) else {
            outcome.declined = true
            return outcome
        }
        do {
            try removeArchiveCopies(plan, isCancelled, &outcome)
            try deleteFromCard(plan, isCancelled, &outcome)
        } catch {
            outcome.stopped = error
        }
        return outcome
    }

    /// Step 7 (D6, R26, SR18). Per frame: check every file first, then Trash each, recording the intent
    /// before and the outcome after. A file is never unlinked instead.
    private func removeArchiveCopies(
        _ plan: ApplyPlan, _ isCancelled: () -> Bool, _ outcome: inout RemovalOutcome
    ) throws(ApplyStop) {
        for removal in plan.removals {
            if isCancelled() { throw .cancelled }
            guard context.marks[removal.frame]?.decision == .reject else {
                outcome.skipped.append(.init(frame: removal.frame, reason: .notRejected))
                continue
            }
            var ready: [(file: Ledger.ArchiveFile, folder: OpenFolder)] = []
            var problem: RemovalOutcome.SkippedFrame.Reason?
            for location in removal.files {
                // Only a file this journal records as verified for this very frame.
                guard let file = ledger.file(at: location), file.owner == .frame(removal.frame),
                    file.status == .verified || file.status == .trashing
                else {
                    problem = .notThisFramesFile(location.name)
                    break
                }
                let unchanged = try unchangedFolder(of: file)
                if let folder = unchanged.folder {
                    ready.append((file, folder))
                } else if file.role != .googlePhotos {
                    problem = unchanged.missing ? .archiveFileMissing(location) : .archiveFileChanged(location)
                    break
                }
                // A staging copy that has gone or changed is simply left out; it holds nothing up.
            }
            if let problem {
                outcome.skipped.append(.init(frame: removal.frame, reason: problem))
                continue
            }
            for (file, folder) in ready {
                if file.status == .verified { try record(.trashing(location: file.location)) }
                let trashPath: String?
                do {
                    trashPath = try fs.moveToTrash(file.location.name, in: folder)
                } catch {
                    outcome.skipped.append(.init(frame: removal.frame, reason: .trashFailed(file.location)))
                    break
                }
                try record(.trashed(location: file.location, trashPath: trashPath))
                outcome.trashed.append(.init(location: file.location, trashPath: trashPath))
            }
        }
    }

    /// The file's folder if the file is there with its recorded size and still hashes to its recorded
    /// SHA-256; otherwise whether it is missing or merely changed.
    private func unchangedFolder(of file: Ledger.ArchiveFile) throws(ApplyStop) -> (folder: OpenFolder?, missing: Bool)
    {
        guard let folder = try folder(for: file.location, create: false),
            let entry = try io(try fs.entry(file.location.name, in: folder))
        else { return (nil, true) }
        guard entry.size == file.size, try hash(file.location.name, in: folder) == file.sha256 else {
            return (nil, false)
        }
        return (folder, false)
    }

    /// Step 8 (SR19, SR27). Per frame: the decision must still be Reject, the frame must have a capture
    /// time, and every file must be exactly what the scan saw and deletable. Then each file is deleted,
    /// with the intent recorded before and the outcome after.
    private func deleteFromCard(
        _ plan: ApplyPlan, _ isCancelled: () -> Bool, _ outcome: inout RemovalOutcome
    ) throws(ApplyStop) {
        var unsynced: Set<String> = []
        var sinceSync = 0
        for delete in plan.cardDeletes {
            if isCancelled() {
                try syncCardFolders(&unsynced)
                throw .cancelled
            }
            if let reason = try reasonNotToDelete(delete) {
                outcome.skipped.append(.init(frame: delete.frame, reason: reason))
                continue
            }
            for (index, path) in delete.paths.enumerated() {
                try record(.deleting(path: path))
                do {
                    if plan.deleteMode == .permanent {
                        try fs.remove(path, in: card)
                    } else {
                        _ = try fs.moveToTrash(path, in: card)
                    }
                } catch {
                    outcome.skipped.append(
                        .init(
                            frame: delete.frame, reason: index == 0 ? .deleteFailed(path) : .pairSplit(remaining: path))
                    )
                    break
                }
                try record(.deleted(path: path))
                outcome.deleted.append(path)
                let parent = path.split(separator: "/").dropLast().joined(separator: "/")
                // A new folder, or 100 files since the last sync: make what has been deleted so far durable,
                // so an unplug can only affect the last few directory updates (SR27).
                sinceSync += 1
                if !unsynced.contains(parent) || sinceSync >= 100 {
                    try syncCardFolders(&unsynced)
                    sinceSync = 0
                }
                unsynced.insert(parent)
            }
        }
        try syncCardFolders(&unsynced)
    }

    private func reasonNotToDelete(_ delete: ApplyPlan.CardDelete) throws(ApplyStop) -> RemovalOutcome.SkippedFrame
        .Reason?
    {
        guard context.marks[delete.frame]?.decision == .reject,
            let frame = context.frames.first(where: { $0.id == delete.frame })
        else { return .notRejected }
        if context.source.isReadOnly { return .cardLocked }
        guard context.captureTimes[delete.frame] != nil else { return .noCaptureDate }
        let scanned = [frame.raf, frame.jpg].compactMap { $0 }
        for path in delete.paths {
            guard let file = scanned.first(where: { $0.relativePath == path }) else { return .notThisFramesFile(path) }
            // Exactly the file the scan saw, by size and date (SR16), and not locked.
            guard let entry = try io(try fs.entry(path, in: card)), entry.size == file.size,
                entry.modified == file.modified
            else { return .cardFileChanged(path) }
            if entry.isImmutable { return .cardFileLocked(path) }
        }
        return nil
    }

    private func syncCardFolders(_ unsynced: inout Set<String>) throws(ApplyStop) {
        for parent in unsynced.sorted() {
            let folder = parent.isEmpty ? card : try io(try fs.openFolder(parent, in: card))
            try io(try fs.syncToDevice(folder))
        }
        unsynced.removeAll()
    }
}
