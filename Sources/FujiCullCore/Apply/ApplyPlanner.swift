import Foundation

/// Decides what one Apply run will do (DESIGN §5.7, Planner). Pure: same input, same plan, no I/O.
///
/// Everything is decided per file (SR9), and only from what can be proven: a journal record counts for a
/// card file only if it **binds** to it (SR2), and a name counts as free only if neither the archive's
/// listing nor the journal nor this plan says otherwise (SR11).
public enum ApplyPlanner {
    static let googlePhotos = "Google Photos"
    static let videos = "Videos"
    /// Kept free on the archive on top of what the copies need (SR14).
    private static let margin: Int64 = 1_000_000_000

    public static func plan(_ input: ApplyInput) throws(ApplyError) -> ApplyPlan {
        if let problem = TripName.problem(with: input.destination.folder) { throw .invalidTripName(problem) }
        if let source = input.source.volumeUUID, source == input.destination.volumeUUID { throw .sameVolume }
        for listing in input.listings.values {
            for names in [listing.trip, listing.googlePhotos, listing.videos] {
                if let clash = ambiguous(names) { throw .ambiguousNames(clash) }
            }
        }

        var planner = Planner(input)
        for frame in input.frames { planner.plan(frame) }
        for video in input.videos { planner.plan(video: video) }
        planner.finish()

        let plan = planner.plan
        if plan.requiredBytes > input.freeBytes {
            throw .insufficientSpace(needed: plan.requiredBytes, available: input.freeBytes)
        }
        return plan
    }

    /// Two entries of one folder that differ only by case, if there are any.
    private static func ambiguous(_ names: [String]) -> [String]? {
        let groups = Dictionary(grouping: names, by: { $0.lowercased() })
        return groups.values.first { $0.count > 1 }?.sorted()
    }

    /// The working state of one planning pass.
    private struct Planner {
        let input: ApplyInput
        var plan = ApplyPlan()
        private let filesByOwner: [Owner: [Ledger.ArchiveFile]]
        /// Lower-cased names that can't be given out, per folder: on the archive, held in the journal by a
        /// file that is or will be there, or allocated earlier in this plan.
        private var taken: [Folder: Set<String>] = [:]

        private struct Folder: Hashable {
            let destination: Ledger.Destination
            let subfolder: String?
        }

        init(_ input: ApplyInput) {
            self.input = input
            filesByOwner = Dictionary(grouping: input.ledger.allFiles, by: \.owner)
            for (destination, listing) in input.listings {
                for (subfolder, names) in [
                    (nil, listing.trip), (googlePhotos, listing.googlePhotos), (videos, listing.videos),
                ] {
                    taken[Folder(destination: destination, subfolder: subfolder), default: []]
                        .formUnion(names.map { $0.lowercased() })
                }
            }
            // A trashed or released file is gone; every other recorded file is, or is about to be, on the archive.
            for file in input.ledger.allFiles where file.status != .trashed && file.status != .released {
                taken[Folder(destination: file.destination, subfolder: file.location.subfolder), default: []]
                    .insert(file.location.name.lowercased())
            }
            let chosen = input.destination
            if input.listings[chosen] == nil {
                plan.destinationState = .new
            } else {
                // A folder this journal chose before is ours even if that run stopped before its first file.
                let known =
                    input.ledger.chosenDestination == chosen
                    || input.ledger.allFiles.contains { $0.destination == chosen }
                plan.destinationState = known ? .ours : .existsNotOurs
            }
            plan.deleteMode = input.source.isCameraCard ? .permanent : .trash
            plan.leftOnCard.otherFiles = input.otherFiles.map(\.relativePath)
            plan.leftOnCard.skippedItems = input.skippedItems
        }

        // MARK: One frame

        mutating func plan(_ frame: Frame) {
            let mark = input.marks[frame.id] ?? FrameMark()
            switch mark.decision {
            case .undecided: plan.leftOnCard.undecided.append(frame.id)
            case .keep: planKeep(frame, favourite: mark.isFavourite)
            case .reject: planReject(frame)
            }
        }

        private mutating func planKeep(_ frame: Frame, favourite: Bool) {
            let owner = Owner.frame(frame.id)
            let captured = input.captureTimes[frame.id]
            var raw = frame.raf.flatMap { bound(owner, .raw, to: $0, captured: captured) }
            var jpg = frame.jpg.flatMap { bound(owner, .jpg, to: $0, captured: captured) }
            let recorded = [raw, jpg].compactMap { $0 }

            // Files in a folder that can't be seen are left alone: not copied again behind the owner's back,
            // not tagged. The plan reports the folder, and card deletion isn't offered (SR17).
            if let hidden = recorded.first(where: { input.listings[$0.destination] == nil }) {
                noteUnreachable(hidden.destination)
                return
            }

            // The frame keeps one name across its files (SR11). If a file still to make can't have the name
            // the others were verified under, or the owner asked for a fresh copy, the whole frame is
            // copied again under a new name and the old files are left where they are (SR26).
            var suffix: Int?
            if let first = recorded.first { suffix = suffixNumber(of: first.location.name) }
            var home = recorded.first?.destination ?? input.destination
            var needsStaging = frame.jpg != nil && !(jpg.map { hasStagingCopy(owner, newerThan: $0) } ?? false)
            if let current = suffix {
                let blocked =
                    [raw == nil ? frame.raf : nil, jpg == nil ? frame.jpg : nil].compactMap { $0 }
                    .contains { isTaken(name(of: $0, suffix: current), in: Folder(destination: home, subfolder: nil)) }
                    || (needsStaging
                        && (frame.jpg.map {
                            isTaken(
                                name(of: $0, suffix: current), in: Folder(destination: home, subfolder: googlePhotos))
                        } ?? false))
                if blocked || input.copyAgain.contains(owner) {
                    let staging = files(of: owner).filter { $0.role == .googlePhotos && $0.status == .verified }
                    plan.superseded += (recorded + staging).map(\.location)
                    (raw, jpg, suffix, home, needsStaging) = (nil, nil, nil, input.destination, frame.jpg != nil)
                }
            }

            let toCopy: [(FileRole, SourceFile)] = [
                (.raw, raw == nil ? frame.raf : nil), (.jpg, jpg == nil ? frame.jpg : nil),
            ]
            .compactMap { role, file in file.map { (role, $0) } }
            let chosen = suffix ?? freeSuffix(for: toCopy.map(\.1), staging: needsStaging ? frame.jpg : nil, in: home)
            for (role, file) in toCopy {
                let to = claim(name(of: file, suffix: chosen), in: home, subfolder: nil)
                plan.copies.append(
                    ApplyPlan.Copy(
                        owner: owner, role: role, source: .card(file), size: file.size, to: to, favourite: favourite))
            }
            if needsStaging, let file = frame.jpg {
                let archiveName = name(of: file, suffix: chosen)
                plan.copies.append(
                    ApplyPlan.Copy(
                        owner: owner, role: .googlePhotos,
                        source: .archive(location(archiveName, in: home, subfolder: nil)),
                        size: file.size, to: claim(archiveName, in: home, subfolder: googlePhotos), favourite: false))
            }

            // Tags on files already there are planned from what the files carry now (SR12).
            for file in [raw, jpg].compactMap({ $0 }) {
                let tagged =
                    input.listings[file.destination]?.favourites.contains {
                        $0.lowercased() == file.location.name.lowercased()
                    } ?? false
                if favourite, !tagged {
                    plan.tagChanges.append(ApplyPlan.TagChange(location: file.location, favourite: true))
                }
                if !favourite, tagged, file.taggedByUs {
                    plan.tagChanges.append(ApplyPlan.TagChange(location: file.location, favourite: false))
                }
            }
        }

        private mutating func planReject(_ frame: Frame) {
            let owner = Owner.frame(frame.id)
            let captured = input.captureTimes[frame.id]

            // Archive copies made while the frame was a keeper (D6, R26): only files this journal proves
            // FujiCull wrote for this very photo.
            var removable = [
                frame.raf.flatMap { bound(owner, .raw, to: $0, captured: captured) },
                frame.jpg.flatMap { bound(owner, .jpg, to: $0, captured: captured) },
            ]
            .compactMap { $0 }
            if let hidden = removable.first(where: { input.listings[$0.destination] == nil }) {
                noteUnreachable(hidden.destination)
                removable = []
            }
            if !removable.isEmpty {
                // The staging copy goes too if it is still there; if it has gone, that holds nothing up.
                let staging = files(of: owner).filter { file in
                    file.role == .googlePhotos && file.status == .verified
                        && (input.listings[file.destination]?.googlePhotos.contains {
                            $0.lowercased() == file.location.name.lowercased()
                        } ?? false)
                }
                plan.removals.append(ApplyPlan.Removal(frame: frame.id, files: (removable + staging).map(\.location)))
            }

            if input.source.isReadOnly {
                plan.notDeleted.append(ApplyPlan.NotDeleted(frame: frame.id, reason: .cardLocked))
            } else if captured == nil {
                plan.notDeleted.append(ApplyPlan.NotDeleted(frame: frame.id, reason: .noCaptureDate))
            } else {
                plan.cardDeletes.append(
                    ApplyPlan.CardDelete(
                        frame: frame.id, paths: [frame.raf, frame.jpg].compactMap { $0?.relativePath }))
            }
        }

        // MARK: Videos (R27)

        mutating func plan(video: SourceFile) {
            let owner = Owner.video(video.relativePath)
            if let recorded = bound(owner, .video, to: video, captured: nil) {
                if input.listings[recorded.destination] == nil { noteUnreachable(recorded.destination) }
                return
            }
            let folder = Folder(destination: input.destination, subfolder: videos)
            var suffix = 1
            while isTaken(name(of: video, suffix: suffix), in: folder) { suffix += 1 }
            let to = claim(name(of: video, suffix: suffix), in: input.destination, subfolder: videos)
            plan.copies.append(
                ApplyPlan.Copy(
                    owner: owner, role: .video, source: .card(video), size: video.size, to: to, favourite: false))
        }

        // MARK: Totals

        mutating func finish() {
            guard !plan.copies.isEmpty else { return }
            let unit = max(input.allocationSize, 1)
            // Each file is rounded up to whole allocation units, and gets one more for its `._` companion.
            plan.requiredBytes = plan.copies.reduce(margin) { $0 + (($1.size + unit - 1) / unit + 1) * unit }
        }

        // MARK: Binding (SR2)

        private func files(of owner: Owner) -> [Ledger.ArchiveFile] { filesByOwner[owner] ?? [] }

        private func bound(_ owner: Owner, _ role: FileRole, to file: SourceFile, captured: CaptureTime?) -> Ledger
            .ArchiveFile?
        {
            input.ledger.boundFile(among: files(of: owner), role: role, to: file, captured: captured)
        }

        /// Whether the frame's staging copy was made from its current archive JPG.
        private func hasStagingCopy(_ owner: Owner, newerThan jpg: Ledger.ArchiveFile?) -> Bool {
            guard let jpg else { return false }
            return files(of: owner).contains {
                $0.role == .googlePhotos && $0.status == .verified && $0.sequence > jpg.sequence
            }
        }

        // MARK: Names (SR10, SR11)

        private func isTaken(_ name: String, in folder: Folder) -> Bool {
            taken[folder]?.contains(name.lowercased()) ?? false
        }

        /// The smallest suffix (1 means none) under which every file still to copy has a free name.
        private func freeSuffix(for files: [SourceFile], staging: SourceFile?, in destination: Ledger.Destination)
            -> Int
        {
            var suffix = 1
            while true {
                let trip = Folder(destination: destination, subfolder: nil)
                let stage = Folder(destination: destination, subfolder: googlePhotos)
                let clash =
                    files.contains { isTaken(name(of: $0, suffix: suffix), in: trip) }
                    || (staging.map { isTaken(name(of: $0, suffix: suffix), in: stage) } ?? false)
                if !clash { return suffix }
                suffix += 1
            }
        }

        private mutating func claim(_ name: String, in destination: Ledger.Destination, subfolder: String?)
            -> ArchiveLocation
        {
            taken[Folder(destination: destination, subfolder: subfolder), default: []].insert(name.lowercased())
            return location(name, in: destination, subfolder: subfolder)
        }

        private func location(_ name: String, in destination: Ledger.Destination, subfolder: String?) -> ArchiveLocation
        {
            ArchiveLocation(
                volumeUUID: destination.volumeUUID, folder: destination.folder, subfolder: subfolder, name: name)
        }

        private mutating func noteUnreachable(_ destination: Ledger.Destination) {
            if !plan.unreachableDestinations.contains(destination) { plan.unreachableDestinations.append(destination) }
        }

        /// The card file's own name, with `-n` before the extension when `suffix` is 2 or more.
        private func name(of file: SourceFile, suffix: Int) -> String {
            let original = file.relativePath.split(separator: "/").last.map(String.init) ?? file.relativePath
            guard suffix > 1 else { return original }
            guard let dot = original.lastIndex(of: "."), dot != original.startIndex else {
                return "\(original)-\(suffix)"
            }
            return "\(original[..<dot])-\(suffix)\(original[dot...])"
        }

        /// The suffix an archive name carries: 1 for `DSCF0001.JPG`, 2 for `DSCF0001-2.JPG`.
        private func suffixNumber(of archiveName: String) -> Int {
            let stem = archiveName.lastIndex(of: ".").map { String(archiveName[..<$0]) } ?? archiveName
            guard let dash = stem.lastIndex(of: "-"), let number = Int(stem[stem.index(after: dash)...]), number > 1
            else { return 1 }
            return number
        }
    }
}
