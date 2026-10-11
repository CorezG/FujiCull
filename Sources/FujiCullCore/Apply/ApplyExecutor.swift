import CryptoKit
import Foundation

/// Why a run stopped before it finished. Whenever one of these is reported, nothing has been deleted.
public enum ApplyStop: Error, Equatable, Sendable {
    case cancelled
    case journal(LedgerJournal.JournalError)
    case plan(ApplyError)
    /// The card isn't the one this session belongs to (SR16).
    case wrongCard
    case archiveNotConnected(volumeUUID: String)
    /// What is mounted where the archive should be is another volume (SR7).
    case wrongArchive(expected: String, found: String?)
    /// The trip folder was going to be created, but something with that name is there now (SR10).
    case destinationAppeared(Ledger.Destination)
    case verificationFailed(ArchiveLocation)
    case io(FileSystemError)
    /// Removal was asked for without a gate that allows it.
    case gateClosed
}

/// Carries out Apply (DESIGN §5.7, Executor): recover, copy and verify, tag, check, and only then remove.
///
/// Every archive and card operation goes through folders opened once and checked to be on the expected
/// volume (SR7, SR16). An open folder belongs to the volume that was mounted when it was opened, so a
/// drive that is swapped afterwards makes calls fail; it can never redirect them.
///
/// Every step is recorded in the journal as it happens, and `ledger` always reflects the journal.
public final class ApplyExecutor {
    public struct Context: Sendable {
        // The fresh scan of the card (SR16), the decisions, and each frame's capture time.
        public var frames: [Frame]
        public var videos: [SourceFile]
        public var otherFiles: [SourceFile]
        public var skippedItems: Int
        public var marks: [FrameID: FrameMark]
        public var captureTimes: [FrameID: CaptureTime]
        public var source: ApplyInput.Source
        /// The trip folder chosen for new copies.
        public var destination: Ledger.Destination
        /// Where each archive volume is mounted right now, by volume UUID. Looked up for every run.
        public var archiveRoots: [String: String]

        public init(
            frames: [Frame], videos: [SourceFile] = [], otherFiles: [SourceFile] = [], skippedItems: Int = 0,
            marks: [FrameID: FrameMark], captureTimes: [FrameID: CaptureTime], source: ApplyInput.Source,
            destination: Ledger.Destination, archiveRoots: [String: String]
        ) {
            self.frames = frames
            self.videos = videos
            self.otherFiles = otherFiles
            self.skippedItems = skippedItems
            self.marks = marks
            self.captureTimes = captureTimes
            self.source = source
            self.destination = destination
            self.archiveRoots = archiveRoots
        }
    }

    /// What recovery found and settled (executor step 1).
    public struct Recovery: Equatable, Sendable {
        /// Copies that had finished but weren't recorded; now recorded as verified.
        public var adopted: [ArchiveLocation] = []
        /// Interrupted copies whose leftovers were removed.
        public var released: [ArchiveLocation] = []
        public var settledTrashes: [ArchiveLocation] = []
        public var settledDeletes: [String] = []
        /// Other `*.fujicull-partial` files in the folders. They are listed, and removed only after the
        /// owner confirms.
        public var strayPartials: [ArchiveLocation] = []
        /// Folders the journal refers to that couldn't be reached, so their reservations stay open.
        public var unreachable: [Ledger.Destination] = []
    }

    public struct CopyOutcome: Equatable, Sendable {
        public struct Skipped: Equatable, Sendable {
            public enum Reason: Equatable, Sendable {
                /// The card file isn't what the scan saw (SR16).
                case sourceChanged
                /// Something took the name between planning and copying; the next plan re-homes the frame.
                case nameConflict
                /// The archive JPG a Google Photos copy is made from wasn't there to copy, or had changed.
                case archiveJPGUnavailable
            }

            public let owner: Owner
            public let reason: Reason
        }

        public var copied: [ArchiveLocation] = []
        public var skipped: [Skipped] = []
        /// Tags that couldn't be set. The next run plans them again.
        public var tagFailures: [ArchiveLocation] = []
        /// Set when the run stopped early. Everything recorded up to then stands.
        public var stopped: ApplyStop?
    }

    /// The state of every keeper on the archive right now (executor step 4, SR28).
    public struct FinalCheck: Equatable, Sendable {
        public struct Problem: Equatable, Sendable {
            public enum Kind: Equatable, Sendable {
                case notArchived(FileRole)
                case missing(ArchiveLocation)
                case changed(ArchiveLocation)
                case unreachable(Ledger.Destination)
            }

            public let owner: Owner
            public let kind: Kind
        }

        /// Keep frames and videos whose every file is on the archive with its recorded size.
        public var keepersOnArchive = 0
        public var problems: [Problem] = []
    }

    static let favouriteTag = "Favourite"
    static let partialSuffix = ".fujicull-partial"

    public private(set) var ledger: Ledger
    let fs: any FileSystem
    private let journal: LedgerJournal
    let card: OpenFolder
    let context: Context
    /// Files hashed from the device in this run: copied, or adopted in recovery. The gate re-hashes the rest.
    var verifiedThisRun: Set<ArchiveLocation> = []
    private var roots: [String: OpenFolder] = [:]
    private var folders: [FolderKey: OpenFolder] = [:]

    private struct FolderKey: Hashable {
        let destination: Ledger.Destination
        let subfolder: String?
    }

    /// `card` is the card's root, already open. `records` are the journal's records as loaded.
    public init(
        fs: any FileSystem, journal: LedgerJournal, records: [LedgerRecord], card: OpenFolder, context: Context
    ) throws(ApplyStop) {
        self.fs = fs
        self.journal = journal
        self.card = card
        self.context = context
        ledger = Ledger(records)
        // A card with a volume UUID must be the one the session was opened for. A card without one (a
        // small card formatted in the camera) is covered by the per-file checks before every read and delete.
        if let expected = context.source.volumeUUID {
            guard try io(try fs.volumeUUID(of: card)) == expected else { throw .wrongCard }
        }
    }

    // MARK: Step 1: recover, then sweep (SR25)

    /// Settles everything an interrupted run left open, so the planner only ever sees settled state.
    public func recover() throws(ApplyStop) -> Recovery {
        var recovery = Recovery()
        for file in ledger.openReservations {
            guard let folder = try folder(for: file.location, create: false) else {
                if context.archiveRoots[file.location.volumeUUID] == nil {
                    if !recovery.unreachable.contains(file.destination) {
                        recovery.unreachable.append(file.destination)
                    }
                } else {
                    // The drive is here and the folder isn't: nothing of ours can be in it.
                    try record(.released(location: file.location))
                    recovery.released.append(file.location)
                }
                continue
            }
            var adopted = false
            if let entry = try io(try fs.entry(file.location.name, in: folder)) {
                if entry.size == 0 {
                    // Our own placeholder: the run stopped between claiming the name and the rename.
                    try io(try fs.remove(file.location.name, in: folder))
                } else if let verified = try completedCopy(file, size: entry.size, in: folder) {
                    // The rename had happened; only the record was missing.
                    try record(verified)
                    verifiedThisRun.insert(file.location)
                    recovery.adopted.append(file.location)
                    adopted = true
                }
                // Otherwise the file at that name isn't provably this frame's. It is left exactly as it is.
            }
            if try io(try fs.entry(file.partial, in: folder)) != nil { try io(try fs.remove(file.partial, in: folder)) }
            if !adopted {
                try record(.released(location: file.location))
                recovery.released.append(file.location)
            }
        }

        for file in ledger.unsettledTrashes {
            guard let folder = try folder(for: file.location, create: false),
                try io(try fs.entry(file.location.name, in: folder)) == nil
            else { continue }
            // The move happened; where it went wasn't recorded.
            try record(.trashed(location: file.location, trashPath: nil))
            recovery.settledTrashes.append(file.location)
        }
        for path in ledger.unsettledDeletes where try io(try fs.entry(path, in: card)) == nil {
            try record(.deleted(path: path))
            recovery.settledDeletes.append(path)
        }

        recovery.strayPartials = try strayPartials()
        return recovery
    }

    /// Removes leftover partial files that recovery listed, once the owner has confirmed. Only names ending
    /// in FujiCull's own suffix are ever removed.
    public func removeStrayPartials(_ partials: [ArchiveLocation]) throws(ApplyStop) {
        for partial in partials where partial.name.hasSuffix(Self.partialSuffix) {
            guard let folder = try folder(for: partial, create: false) else { continue }
            if try io(try fs.entry(partial.name, in: folder)) != nil { try io(try fs.remove(partial.name, in: folder)) }
        }
    }

    /// The `verified` record for a reservation whose file turns out to be complete: it must hash to what
    /// its source hashes to now. Anything less and the file isn't adopted.
    private func completedCopy(_ file: Ledger.ArchiveFile, size: Int64, in folder: OpenFolder) throws(ApplyStop)
        -> LedgerRecord?
    {
        let source: SourceIdentity
        if file.role == .googlePhotos {
            // Made from the frame's archive JPG, so it must hash to what that JPG was verified as.
            guard let jpg = ledger.files(of: file.owner).last(where: { $0.role == .jpg && $0.status == .verified }),
                let identity = jpg.source
            else { return nil }
            source = identity
        } else {
            guard let cardFile = cardFile(of: file.owner, role: file.role), cardFile.size == size,
                let entry = try io(try fs.entry(cardFile.relativePath, in: card)), entry.size == cardFile.size
            else { return nil }
            let captured: CaptureTime? = file.owner.kind == .frame ? context.captureTimes[FrameID(file.owner.id)] : nil
            source = SourceIdentity(
                path: cardFile.relativePath, size: cardFile.size, modified: cardFile.modified, captureTime: captured,
                sha256: try hash(cardFile.relativePath, in: card))
        }
        guard source.size == size, try hash(file.location.name, in: folder) == source.sha256 else { return nil }
        return .verified(
            owner: file.owner, role: file.role, location: file.location, source: source, size: size,
            sha256: source.sha256)
    }

    private func strayPartials() throws(ApplyStop) -> [ArchiveLocation] {
        var strays: [ArchiveLocation] = []
        var destinations = ledger.allFiles.map(\.destination)
        destinations.append(context.destination)
        var seen: Set<Ledger.Destination> = []
        for destination in destinations where seen.insert(destination).inserted {
            for subfolder in [nil] + ArchiveLayout.subfolders {
                let anchor = ArchiveLocation(
                    volumeUUID: destination.volumeUUID, folder: destination.folder, subfolder: subfolder, name: "")
                guard let folder = try folder(for: anchor, create: false) else { continue }
                for name in try io(try fs.names(in: folder)).sorted() where name.hasSuffix(Self.partialSuffix) {
                    strays.append(
                        ArchiveLocation(
                            volumeUUID: destination.volumeUUID, folder: destination.folder, subfolder: subfolder,
                            name: name))
                }
            }
        }
        return strays
    }

    // MARK: Planning

    /// Lists the archive as it is now and plans the run. Call after `recover()`.
    public func makePlan(copyAgain: Set<Owner> = []) throws(ApplyStop) -> ApplyPlan {
        guard let rootPath = context.archiveRoots[context.destination.volumeUUID] else {
            throw .archiveNotConnected(volumeUUID: context.destination.volumeUUID)
        }
        let root = try root(context.destination.volumeUUID, at: rootPath)
        let space = try io(try fs.volumeSpace(of: root))
        let input = ApplyInput(
            frames: context.frames, videos: context.videos, otherFiles: context.otherFiles,
            skippedItems: context.skippedItems, marks: context.marks, captureTimes: context.captureTimes,
            ledger: ledger,
            source: context.source, destination: context.destination, listings: try listings(),
            freeBytes: space.freeBytes, allocationSize: space.allocationSize, copyAgain: copyAgain)
        do {
            return try ApplyPlanner.plan(input)
        } catch {
            throw .plan(error)
        }
    }

    /// What is in every trip folder the plan may refer to: the chosen one and each one in the journal.
    private func listings() throws(ApplyStop) -> [Ledger.Destination: ApplyInput.Listing] {
        var result: [Ledger.Destination: ApplyInput.Listing] = [:]
        var destinations = ledger.allFiles.map(\.destination)
        destinations.append(context.destination)
        for destination in destinations where result[destination] == nil {
            guard let trip = try tripFolder(destination, create: false) else { continue }
            var listing = ApplyInput.Listing(names: [nil: Self.visible(try io(try fs.names(in: trip)))])
            for subfolder in ArchiveLayout.subfolders {
                let anchor = ArchiveLocation(
                    volumeUUID: destination.volumeUUID, folder: destination.folder, subfolder: subfolder, name: "")
                guard let folder = try folder(for: anchor, create: false) else { continue }
                listing.names[subfolder] = Self.visible(try io(try fs.names(in: folder)))
            }
            // Tags are read only for archive files this journal owns; other people's files aren't looked at.
            for file in ledger.allFiles
            where file.destination == destination && (file.role == .raw || file.role == .jpg)
                && (file.status == .verified || file.status == .trashing)
                && listing.names(in: file.location.subfolder).contains(where: {
                    $0.lowercased() == file.location.name.lowercased()
                })
            {
                guard let folder = try folder(for: file.location, create: false) else { continue }
                if try io(try fs.tags(of: file.location.name, in: folder)).contains(Self.favouriteTag) {
                    listing.favourites.insert(file.location.pathInTrip)
                }
            }
            result[destination] = listing
        }
        return result
    }

    private static func visible(_ names: [String]) -> [String] {
        names.filter { !$0.hasPrefix(".") }.sorted()
    }

    // MARK: Steps 2 and 3: copy, verify, tag

    /// Copies and tags what the plan says. Stops at the first I/O error or failed verification; a frame
    /// whose card file changed or whose name was taken is skipped and the rest carry on. Deletes nothing.
    public func copy(
        _ plan: ApplyPlan, isCancelled: () -> Bool = { Task.isCancelled },
        onProgress: (_ bytesDone: Int64, _ bytesTotal: Int64) -> Void = { _, _ in }
    ) -> CopyOutcome {
        var outcome = CopyOutcome()
        do {
            try copy(plan, isCancelled, onProgress, &outcome)
        } catch {
            outcome.stopped = error
        }
        return outcome
    }

    private func copy(
        _ plan: ApplyPlan, _ isCancelled: () -> Bool, _ onProgress: (Int64, Int64) -> Void, _ outcome: inout CopyOutcome
    ) throws(ApplyStop) {
        if !plan.copies.isEmpty, ledger.chosenDestination != context.destination {
            try record(.destination(volumeUUID: context.destination.volumeUUID, folder: context.destination.folder))
        }
        for location in plan.superseded { try record(.superseded(location: location)) }
        // A folder planned as new is created here, by us. If the name exists by now, pre-flight never asked
        // about adding to it, so the run stops (SR10).
        if plan.destinationState == .new, !plan.copies.isEmpty {
            guard try tripFolder(context.destination, create: true, mustBeNew: true) != nil else {
                throw .archiveNotConnected(volumeUUID: context.destination.volumeUUID)
            }
        }

        let total = plan.copies.reduce(Int64(0)) { $0 + $1.size }
        var done: Int64 = 0
        var skippedOwners: Set<Owner> = []
        for copy in plan.copies {
            if isCancelled() { throw .cancelled }
            defer { done += copy.size }
            if skippedOwners.contains(copy.owner) { continue }
            guard let request = try request(for: copy) else {
                let reason: CopyOutcome.Skipped.Reason
                if case .archive = copy.source { reason = .archiveJPGUnavailable } else { reason = .sourceChanged }
                outcome.skipped.append(CopyOutcome.Skipped(owner: copy.owner, reason: reason))
                skippedOwners.insert(copy.owner)
                continue
            }
            try record(
                .reserve(
                    owner: copy.owner, role: copy.role, location: copy.to,
                    partial: SafeCopy.partialName(for: copy.to.name)))
            do {
                let result = try SafeCopy.copy(
                    request.copy, using: fs, isCancelled: isCancelled, onProgress: { onProgress(done + $0, total) })
                let source = SourceIdentity(
                    path: request.identity.path, size: request.identity.size, modified: request.identity.modified,
                    captureTime: request.identity.captureTime, sha256: result.sha256)
                try record(
                    .verified(
                        owner: copy.owner, role: copy.role, location: copy.to, source: source, size: result.size,
                        sha256: result.sha256))
                verifiedThisRun.insert(copy.to)
                outcome.copied.append(copy.to)
                try tagNewFile(copy, in: request.copy.destination, &outcome)
            } catch let failure as SafeCopy.Failure {
                // With leftovers on the drive the reservation stays open, so the next run's recovery finds them.
                if failure.leftBehind.isEmpty { try record(.released(location: copy.to)) }
                switch failure.reason {
                case .cancelled: throw .cancelled
                case .verificationFailed: throw .verificationFailed(copy.to)
                case .io(let error): throw .io(error)
                case .nameTaken:
                    outcome.skipped.append(CopyOutcome.Skipped(owner: copy.owner, reason: .nameConflict))
                    skippedOwners.insert(copy.owner)
                case .sourceChanged:
                    outcome.skipped.append(CopyOutcome.Skipped(owner: copy.owner, reason: .sourceChanged))
                    skippedOwners.insert(copy.owner)
                case .sourceMismatch:
                    outcome.skipped.append(CopyOutcome.Skipped(owner: copy.owner, reason: .archiveJPGUnavailable))
                    skippedOwners.insert(copy.owner)
                }
            } catch let stop as ApplyStop {
                throw stop
            } catch {
                throw .io(FileSystemError(operation: .write, name: copy.to.name, code: EIO))
            }
        }
        onProgress(total, total)

        for change in plan.tagChanges {
            guard let folder = try folder(for: change.location, create: false) else { continue }
            do {
                var tags = try fs.tags(of: change.location.name, in: folder)
                if change.favourite { tags.insert(Self.favouriteTag) } else { tags.remove(Self.favouriteTag) }
                try fs.setTags(tags, of: change.location.name, in: folder)
            } catch {
                outcome.tagFailures.append(change.location)
                continue
            }
            try record(change.favourite ? .tagged(location: change.location) : .untagged(location: change.location))
        }
    }

    private struct PreparedCopy {
        let copy: SafeCopy.Request
        let identity: SourceIdentity
    }

    /// The copy request for one planned file, or nil if its source isn't what the plan expects.
    private func request(for copy: ApplyPlan.Copy) throws(ApplyStop) -> PreparedCopy? {
        guard let destination = try folder(for: copy.to, create: true) else {
            throw .archiveNotConnected(volumeUUID: copy.to.volumeUUID)
        }
        switch copy.source {
        case .card(let file):
            // The file must still be what the scan saw, by size and date (SR16).
            guard let entry = try io(try fs.entry(file.relativePath, in: card)), entry.size == file.size,
                entry.modified == file.modified
            else { return nil }
            let captured: CaptureTime? = copy.owner.kind == .frame ? context.captureTimes[FrameID(copy.owner.id)] : nil
            return PreparedCopy(
                copy: SafeCopy.Request(
                    sourceFolder: card, sourcePath: file.relativePath, expectedSize: file.size,
                    destination: destination,
                    finalName: copy.to.name, modified: file.modified),
                identity: SourceIdentity(
                    path: file.relativePath, size: file.size, modified: file.modified, captureTime: captured, sha256: ""
                ))
        case .archive(let location):
            // The archive JPG as verified, in this run or an earlier one. It must still hash to that.
            guard let jpg = ledger.file(at: location), jpg.status == .verified, let identity = jpg.source,
                let sha256 = jpg.sha256, let folder = try folder(for: location, create: false)
            else { return nil }
            return PreparedCopy(
                copy: SafeCopy.Request(
                    sourceFolder: folder, sourcePath: location.name, expectedSize: identity.size,
                    expectedSHA256: sha256,
                    destination: destination, finalName: copy.to.name, modified: identity.modified),
                identity: identity)
        }
    }

    /// A file FujiCull has just created gets exactly the tags FujiCull intends (SR12). A new name can
    /// inherit a stale tag from an orphaned `._` companion left by a file that used to be there.
    private func tagNewFile(_ copy: ApplyPlan.Copy, in folder: OpenFolder, _ outcome: inout CopyOutcome)
        throws(ApplyStop)
    {
        do {
            let wanted: Set<String> = copy.favourite ? [Self.favouriteTag] : []
            if try fs.tags(of: copy.to.name, in: folder) != wanted {
                try fs.setTags(wanted, of: copy.to.name, in: folder)
            }
        } catch {
            outcome.tagFailures.append(copy.to)
            return
        }
        if copy.favourite { try record(.tagged(location: copy.to)) }
    }

    // MARK: Step 4: final check (SR28)

    /// Looks up every keeper's files on the archive now. The summary's numbers come from here, never from
    /// the journal alone. Runs whether or not anything is to be deleted.
    public func finalCheck() throws(ApplyStop) -> FinalCheck {
        var result = FinalCheck()
        for frame in context.frames where context.marks[frame.id]?.decision == .keep {
            let owner = Owner.frame(frame.id)
            let files: [(FileRole, SourceFile)] = [(.raw, frame.raf), (.jpg, frame.jpg)].compactMap { role, file in
                file.map { (role, $0) }
            }
            try checkFiles(of: owner, files, captured: context.captureTimes[frame.id], &result)
        }
        for video in context.videos {
            try checkFiles(of: .video(video.relativePath), [(.video, video)], captured: nil, &result)
        }
        return result
    }

    private func checkFiles(
        of owner: Owner, _ files: [(FileRole, SourceFile)], captured: CaptureTime?, _ result: inout FinalCheck
    ) throws(ApplyStop) {
        var problems: [FinalCheck.Problem.Kind] = []
        for (role, file) in files {
            guard
                let archived = ledger.boundFile(
                    among: ledger.files(of: owner), role: role, to: file, captured: captured)
            else {
                problems.append(.notArchived(role))
                continue
            }
            guard let folder = try folder(for: archived.location, create: false) else {
                problems.append(.unreachable(archived.destination))
                continue
            }
            guard let entry = try io(try fs.entry(archived.location.name, in: folder)) else {
                problems.append(.missing(archived.location))
                continue
            }
            if entry.size != archived.size { problems.append(.changed(archived.location)) }
        }
        if problems.isEmpty { result.keepersOnArchive += 1 }
        result.problems += problems.map { FinalCheck.Problem(owner: owner, kind: $0) }
    }

    // MARK: Folders (SR7)

    private func root(_ volumeUUID: String, at path: String) throws(ApplyStop) -> OpenFolder {
        if let known = roots[volumeUUID] { return known }
        let root = try io(try fs.openFolder(at: path))
        let found = try io(try fs.volumeUUID(of: root))
        guard found == volumeUUID else { throw .wrongArchive(expected: volumeUUID, found: found) }
        roots[volumeUUID] = root
        return root
    }

    /// The trip folder, opened once. nil when the drive isn't connected, or the folder isn't there and
    /// `create` is false.
    private func tripFolder(
        _ destination: Ledger.Destination, create: Bool, mustBeNew: Bool = false
    ) throws(ApplyStop) -> OpenFolder? {
        let key = FolderKey(destination: destination, subfolder: nil)
        if let known = folders[key] { return known }
        guard let rootPath = context.archiveRoots[destination.volumeUUID] else { return nil }
        let root = try root(destination.volumeUUID, at: rootPath)
        let exists = try io(try fs.entry(destination.folder, in: root)) != nil
        if exists, mustBeNew { throw .destinationAppeared(destination) }
        if !exists {
            guard create else { return nil }
            do {
                try fs.createFolder(destination.folder, in: root)
            } catch {
                // "Already exists" is the volume's answer, whatever our own look just said (SR10).
                throw error.alreadyExists ? .destinationAppeared(destination) : .io(error)
            }
            try io(try fs.syncToDevice(root))
        }
        let trip = try io(try fs.openFolder(destination.folder, in: root))
        folders[key] = trip
        return trip
    }

    func folder(for location: ArchiveLocation, create: Bool) throws(ApplyStop) -> OpenFolder? {
        let destination = Ledger.Destination(volumeUUID: location.volumeUUID, folder: location.folder)
        guard let trip = try tripFolder(destination, create: create) else { return nil }
        guard let subfolder = location.subfolder else { return trip }
        let key = FolderKey(destination: destination, subfolder: subfolder)
        if let known = folders[key] { return known }
        if try io(try fs.entry(subfolder, in: trip)) == nil {
            guard create else { return nil }
            // One level at a time: `RAW`, then `RAW/Edit Me`. Each new folder's parent is synced, so the
            // folder is durable before anything is put in it.
            var path = ""
            var parent = trip
            for component in subfolder.split(separator: "/") {
                path += (path.isEmpty ? "" : "/") + component
                if try io(try fs.entry(path, in: trip)) == nil {
                    try io(try fs.createFolder(path, in: trip))
                    try io(try fs.syncToDevice(parent))
                }
                parent = try io(try fs.openFolder(path, in: trip))
            }
        }
        let opened = try io(try fs.openFolder(subfolder, in: trip))
        folders[key] = opened
        return opened
    }

    // MARK: Helpers

    private func cardFile(of owner: Owner, role: FileRole) -> SourceFile? {
        switch owner.kind {
        case .video: return context.videos.first { $0.relativePath == owner.id }
        case .frame:
            guard let frame = context.frames.first(where: { $0.id.rawValue == owner.id }) else { return nil }
            return role == .raw ? frame.raf : frame.jpg
        }
    }

    func hash(_ path: String, in folder: OpenFolder) throws(ApplyStop) -> String {
        let file = try io(try fs.openForReading(path, in: folder))
        var hasher = SHA256()
        while true {
            let chunk = try io(try fs.read(file, upTo: 8 * 1024 * 1024))
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Appends to the journal, then to the in-memory ledger. If the journal can't be written, the run stops.
    func record(_ record: LedgerRecord) throws(ApplyStop) {
        do {
            try journal.append(record)
        } catch {
            throw .journal(error)
        }
        ledger.record(record)
    }
}

func io<T>(_ body: @autoclosure () throws(FileSystemError) -> T) throws(ApplyStop) -> T {
    do {
        return try body()
    } catch {
        throw .io(error)
    }
}
