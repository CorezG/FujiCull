import Foundation
import Testing

@testable import FujiCullCore

// The executor, part 1: recover, copy and verify, tag, final check (DESIGN §5.7 steps 1–4; SR3, SR7, SR10,
// SR12, SR15, SR16, SR25, SR26, SR28). Real small files in temporary folders; faults injected by call.
@Suite struct ApplyExecutorCopyTests {

    /// A favourite, a plain keeper, an undecided frame, a reject and a video.
    private func standardWorld() throws -> ApplyWorld {
        let world = try ApplyWorld()
        try world.addPair("DSCF0001", favouriteMark)
        try world.addPair("DSCF0002", keepMark)
        try world.addPair("DSCF0003", FrameMark())
        try world.addPair("DSCF0004", rejectMark)
        try world.addVideo("DSCF0005")
        return world
    }

    private let standardArchive = [
        "Japan 2026/Google Photos/DSCF0001.JPG", "Japan 2026/Google Photos/DSCF0002.JPG", "Japan 2026/JPG/DSCF0001.JPG",
        "Japan 2026/JPG/DSCF0002.JPG", "Japan 2026/RAW/DSCF0001.RAF", "Japan 2026/RAW/DSCF0002.RAF",
        "Japan 2026/Videos/DSCF0005.MOV",
    ]

    // MARK: A healthy run

    @Test func aFirstRunCopiesEveryKeeperAndVideoIdenticallyAndTouchesNothingElse() throws {
        let world = try standardWorld()
        let cardBefore = try world.cardNames()

        let (outcome, executor) = try world.run()

        #expect(outcome.stopped == nil && outcome.skipped.isEmpty && outcome.tagFailures.isEmpty)
        #expect(outcome.copied.count == 7)
        #expect(try world.archiveNames() == standardArchive)
        let archived = try world.archiveFiles()
        #expect(archived["Japan 2026/RAW/DSCF0001.RAF"] == (try world.sha(ofCardFile: "DCIM/124_FUJI/DSCF0001.RAF")))
        #expect(archived["Japan 2026/JPG/DSCF0002.JPG"] == (try world.sha(ofCardFile: "DCIM/124_FUJI/DSCF0002.JPG")))
        #expect(
            archived["Japan 2026/Google Photos/DSCF0001.JPG"]
                == (try world.sha(ofCardFile: "DCIM/124_FUJI/DSCF0001.JPG")))
        #expect(archived["Japan 2026/Videos/DSCF0005.MOV"] == (try world.sha(ofCardFile: "DCIM/124_FUJI/DSCF0005.MOV")))
        #expect(try world.cardNames() == cardBefore, "nothing on the card is deleted by copying")
        #expect(executor.ledger.allFiles.allSatisfy { $0.status == .verified })
        #expect(executor.ledger.chosenDestination == world.destination)
    }

    @Test func favouritesAreTaggedOnTheArchivePairOnly() throws {
        let world = try standardWorld()

        let (_, executor) = try world.run()

        #expect(try world.tags("Japan 2026/RAW/DSCF0001.RAF") == ["Favourite"])
        #expect(try world.tags("Japan 2026/JPG/DSCF0001.JPG") == ["Favourite"])
        #expect(try world.tags("Japan 2026/Google Photos/DSCF0001.JPG").isEmpty)
        #expect(try world.tags("Japan 2026/RAW/DSCF0002.RAF").isEmpty)
        #expect(executor.ledger.file(at: world.location("DSCF0001.RAF"))?.taggedByUs == true)
        #expect(executor.ledger.file(at: world.location("DSCF0002.RAF"))?.taggedByUs == false)
    }

    @Test func copiesKeepTheCardFilesDate() throws {
        let world = try standardWorld()
        let onCard = try world.card.url("DCIM/124_FUJI/DSCF0001.JPG").resourceValues(forKeys: [
            .contentModificationDateKey
        ])

        try world.run()

        let onArchive = try world.archive.url("Japan 2026/JPG/DSCF0001.JPG").resourceValues(forKeys: [
            .contentModificationDateKey
        ])
        #expect(onArchive.contentModificationDate == onCard.contentModificationDate)
    }

    @Test func theFinalCheckCountsWhatIsActuallyOnTheArchive() throws {
        let world = try standardWorld()
        let (_, executor) = try world.run()

        let check = try executor.finalCheck()

        #expect(check == ApplyExecutor.FinalCheck(keepersOnArchive: 3, problems: []), "two frames and the video")
    }

    @Test func aSecondRunFindsNothingToDo() throws {
        let world = try standardWorld()
        try world.run()
        let before = try world.archiveFiles()
        let fs = FaultyFileSystem()

        let executor = try world.executor(fs)
        let recovery = try executor.recover()
        let plan = try executor.makePlan()
        let outcome = executor.copy(plan, isCancelled: { false })

        #expect(recovery == ApplyExecutor.Recovery())
        #expect(plan.copies.isEmpty && plan.tagChanges.isEmpty)
        #expect(plan.destinationState == .ours)
        #expect(outcome == ApplyExecutor.CopyOutcome())
        #expect(fs.calls(.write) == 0 && fs.calls(.create) == 0)
        #expect(try world.archiveFiles() == before)
    }

    @Test func progressRunsFromNothingToTheTotal() throws {
        let world = try standardWorld()
        let executor = try world.executor()
        let plan = try executor.makePlan()
        var reports: [(Int64, Int64)] = []

        _ = executor.copy(plan, isCancelled: { false }, onProgress: { reports.append(($0, $1)) })

        let total = plan.copies.reduce(Int64(0)) { $0 + $1.size }
        #expect(reports.allSatisfy { $0.1 == total && $0.0 <= total })
        #expect(reports.map(\.0) == reports.map(\.0).sorted(), "never goes backwards")
        #expect(reports.last?.0 == total)
    }

    @Test func everyFileIsReservedInTheJournalBeforeItExistsAndVerifiedAfter() throws {
        let world = try standardWorld()

        try world.run()

        let records = try LedgerJournal.open(at: world.journalURL).records
        var reserved: Set<ArchiveLocation> = []
        var verified = 0
        for record in records {
            if case .reserve(_, _, let location, _) = record { reserved.insert(location) }
            if case .verified(_, _, let location, let source, let size, let sha256) = record {
                #expect(reserved.contains(location), "verified without a reservation: \(location.name)")
                #expect(source.sha256 == sha256 && source.size == size)
                verified += 1
            }
        }
        #expect(verified == 7)
        #expect(records.first == .destination(volumeUUID: world.archiveUUID, folder: "Japan 2026"))
    }

    // MARK: Stopping

    @Test func cancellingStopsTheRunAndTheNextRunFinishesIt() throws {
        let world = try standardWorld()
        let executor = try world.executor()
        let plan = try executor.makePlan()
        var checks = 0

        let first = executor.copy(
            plan,
            isCancelled: {
                checks += 1
                return checks > 9
            })
        #expect(first.stopped == .cancelled)
        #expect(first.copied.count < 7)
        #expect(try world.archiveNames().allSatisfy { !$0.contains("fujicull-partial") }, "a cancelled copy cleans up")

        let second = try world.run().outcome

        #expect(second.stopped == nil)
        #expect(try world.archiveNames() == standardArchive)
    }

    @Test func anIOErrorStopsTheRunAndNothingLaterIsAttempted() throws {
        let world = try standardWorld()
        let fs = FaultyFileSystem(.fail(.write, call: 2, code: ENOSPC))

        let (outcome, executor) = try world.run(fs)

        #expect(
            outcome.stopped
                == .io(FileSystemError(operation: .write, name: ".DSCF0001.JPG.fujicull-partial", code: ENOSPC)))
        #expect(outcome.copied == [world.location("DSCF0001.RAF")])
        #expect(try world.archiveNames() == ["Japan 2026/RAW/DSCF0001.RAF"])
        #expect(executor.ledger.file(at: world.location("DSCF0001.JPG"))?.status == .released)
        #expect(fs.calls(.write) == 2)
    }

    @Test func aCopyThatReadsBackDifferentlyStopsTheRunAndIsNeverRecordedAsVerified() throws {
        let world = try standardWorld()

        let (outcome, executor) = try world.run(FaultyFileSystem(.corruptReads(nameContains: "fujicull-partial")))

        #expect(outcome.stopped == .verificationFailed(world.location("DSCF0001.RAF")))
        #expect(outcome.copied.isEmpty)
        #expect(try world.archiveNames().isEmpty)
        #expect(executor.ledger.allFiles.map(\.status) == [.released])
    }

    @Test func aCardFileThatChangedSinceTheScanIsSkippedAndTheRestCarryOn() throws {
        let world = try standardWorld()
        let executor = try world.executor()
        let plan = try executor.makePlan()
        // Rewritten after the scan: same size, new date.
        let changed = world.card.url("DCIM/124_FUJI/DSCF0001.RAF")
        try ApplyWorld.bytes(3_000, seed: 999).write(to: changed)

        let outcome = executor.copy(plan, isCancelled: { false })

        #expect(outcome.stopped == nil)
        #expect(
            outcome.skipped == [
                ApplyExecutor.CopyOutcome.Skipped(
                    owner: .frame(FrameID("DCIM/124_FUJI/DSCF0001")), reason: .sourceChanged)
            ])
        #expect(
            try world.archiveNames() == standardArchive.filter { !$0.contains("DSCF0001") },
            "no part of that frame is copied")
        #expect(try executor.finalCheck().keepersOnArchive == 2)
    }

    // MARK: Names (SR10, SR26)

    @Test func aNameTakenAfterPlanningSkipsTheFrameAndTheNextPlanRehomesIt() throws {
        let world = try standardWorld()
        let executor = try world.executor()
        let plan = try executor.makePlan()
        let foreign = Data("someone else's photo".utf8)
        try FileManager.default.createDirectory(
            at: world.archive.url("Japan 2026/JPG"), withIntermediateDirectories: true)
        try foreign.write(to: world.archive.url("Japan 2026/JPG/DSCF0001.JPG"))
        var late = plan
        late.destinationState = .ours  // pre-flight has agreed to use the folder

        let outcome = executor.copy(late, isCancelled: { false })

        #expect(
            outcome.skipped == [
                ApplyExecutor.CopyOutcome.Skipped(
                    owner: .frame(FrameID("DCIM/124_FUJI/DSCF0001")), reason: .nameConflict)
            ])
        #expect(try Data(contentsOf: world.archive.url("Japan 2026/JPG/DSCF0001.JPG")) == foreign, "never overwritten")

        let (again, after) = try world.run()

        #expect(again.stopped == nil && again.skipped.isEmpty)
        #expect(after.ledger.file(at: world.location("DSCF0001.RAF"))?.status == .superseded)
        #expect(
            try world.archiveNames().filter { $0.contains("DSCF0001") } == [
                "Japan 2026/Google Photos/DSCF0001-2.JPG", "Japan 2026/JPG/DSCF0001-2.JPG",
                "Japan 2026/JPG/DSCF0001.JPG",
                "Japan 2026/RAW/DSCF0001-2.RAF", "Japan 2026/RAW/DSCF0001.RAF",
            ])
        #expect(try Data(contentsOf: world.archive.url("Japan 2026/JPG/DSCF0001.JPG")) == foreign)
        #expect(try after.finalCheck().problems.isEmpty)
    }

    @Test func aFolderThatAppearsAfterItWasPlannedAsNewStopsTheRun() throws {
        let world = try standardWorld()
        let executor = try world.executor()
        let plan = try executor.makePlan()
        #expect(plan.destinationState == .new)
        try FileManager.default.createDirectory(at: world.archive.url("japan 2026"), withIntermediateDirectories: true)

        let outcome = executor.copy(plan, isCancelled: { false })

        #expect(outcome.stopped == .destinationAppeared(world.destination))
        #expect(try world.archiveNames().isEmpty, "nothing is added to a folder nobody agreed to")
    }

    // MARK: Recovery (executor step 1, SR25)

    @Test func aRunCutOffBetweenClaimingANameAndTheRenameIsCleanedUpAndFinished() throws {
        let world = try standardWorld()
        try world.run(FaultyFileSystem(.die(.rename, call: 1)))
        #expect(
            try world.archiveNames() == [
                "Japan 2026/RAW/.DSCF0001.RAF.fujicull-partial", "Japan 2026/RAW/DSCF0001.RAF",
            ])
        #expect(try Data(contentsOf: world.archive.url("Japan 2026/RAW/DSCF0001.RAF")).isEmpty, "the placeholder")

        let executor = try world.executor()
        let recovery = try executor.recover()

        #expect(recovery.released == [world.location("DSCF0001.RAF")])
        #expect(recovery.adopted.isEmpty && recovery.strayPartials.isEmpty)
        #expect(try world.archiveNames().isEmpty, "the placeholder and the partial are gone")

        _ = executor.copy(try executor.makePlan(), isCancelled: { false })
        #expect(try world.archiveNames() == standardArchive, "and the frame keeps its plain name: no -2")
    }

    @Test func aCopyThatFinishedButWasNotRecordedIsAdoptedNotCopiedAgain() throws {
        let world = try standardWorld()
        // Folder syncs: 1 after creating the trip folder, 2 after creating RAW, 3 after the first file's rename.
        try world.run(FaultyFileSystem(.die(.syncFolder, call: 3)))
        #expect(try world.archiveNames() == ["Japan 2026/RAW/DSCF0001.RAF"])
        let fs = FaultyFileSystem()

        let executor = try world.executor(fs)
        let recovery = try executor.recover()
        let plan = try executor.makePlan()

        #expect(recovery.adopted == [world.location("DSCF0001.RAF")])
        #expect(executor.ledger.file(at: world.location("DSCF0001.RAF"))?.status == .verified)
        #expect(plan.copies.count == 6, "the adopted file isn't copied again")
        _ = executor.copy(plan, isCancelled: { false })
        #expect(try world.archiveNames() == standardArchive)
    }

    @Test func aDifferentFileAtAReservedNameIsNeitherAdoptedNorRemoved() throws {
        // Same name, same size, different bytes: not provably ours, so it is left exactly as it is.
        let world = try standardWorld()
        let journal = try LedgerJournal.open(at: world.journalURL).journal
        let location = world.location("DSCF0001.RAF")
        try journal.append(.destination(volumeUUID: world.archiveUUID, folder: "Japan 2026"))
        try journal.append(
            .reserve(
                owner: .frame(FrameID("DCIM/124_FUJI/DSCF0001")), role: .raw, location: location,
                partial: ".DSCF0001.RAF.fujicull-partial"))
        let theirs = ApplyWorld.bytes(3_000, seed: 12_345)
        try FileManager.default.createDirectory(
            at: world.archive.url("Japan 2026/RAW"), withIntermediateDirectories: true)
        try theirs.write(to: world.archive.url("Japan 2026/RAW/DSCF0001.RAF"))

        let (outcome, executor) = try world.run()

        #expect(outcome.stopped == nil)
        #expect(try Data(contentsOf: world.archive.url("Japan 2026/RAW/DSCF0001.RAF")) == theirs)
        #expect(executor.ledger.file(at: location)?.status == .released)
        #expect(
            try world.archiveNames().contains("Japan 2026/RAW/DSCF0001-2.RAF"),
            "the frame goes under the next free name")
        #expect(try world.archiveNames().contains("Japan 2026/JPG/DSCF0001-2.JPG"))
    }

    @Test func aReservationInAFolderThatNoLongerExistsIsReleased() throws {
        let world = try standardWorld()
        let journal = try LedgerJournal.open(at: world.journalURL).journal
        try journal.append(
            .reserve(
                owner: .frame(FrameID("DCIM/124_FUJI/DSCF0001")), role: .raw,
                location: world.location("DSCF0001.RAF", trip: "Gone"),
                partial: ".DSCF0001.RAF.fujicull-partial"))

        let recovery = try world.executor().recover()

        #expect(recovery.released == [world.location("DSCF0001.RAF", trip: "Gone")])
    }

    @Test func aReservationOnADriveThatIsNotConnectedStaysOpen() throws {
        let world = try standardWorld()
        let elsewhere = ArchiveLocation(
            volumeUUID: "OTHER-DRIVE", folder: "Japan 2026", subfolder: nil, name: "DSCF0001.RAF")
        try LedgerJournal.open(at: world.journalURL).journal.append(
            .reserve(owner: .frame(FrameID("DCIM/124_FUJI/DSCF0001")), role: .raw, location: elsewhere, partial: ".p"))

        let executor = try world.executor()
        let recovery = try executor.recover()

        #expect(recovery.unreachable == [Ledger.Destination(volumeUUID: "OTHER-DRIVE", folder: "Japan 2026")])
        #expect(
            executor.ledger.openReservations.map(\.location) == [elsewhere], "it can't be settled without the drive")
    }

    @Test func leftoverPartialsNobodyReservedAreListedAndRemovedOnlyWhenAsked() throws {
        let world = try standardWorld()
        try world.run()
        let stray = world.archive.url("Japan 2026/Google Photos/.OLD.JPG.fujicull-partial")
        try Data("half a file".utf8).write(to: stray)
        let executor = try world.executor()

        let recovery = try executor.recover()

        let location = world.location(".OLD.JPG.fujicull-partial", in: "Google Photos")
        #expect(recovery.strayPartials == [location])
        #expect(FileManager.default.fileExists(atPath: stray.path), "listing is not removing")

        // A name without FujiCull's suffix is ignored even if asked for.
        try executor.removeStrayPartials([location, world.location("DSCF0001.RAF")])

        #expect(!FileManager.default.fileExists(atPath: stray.path))
        #expect(try world.archiveNames() == standardArchive)
    }

    // MARK: Converging after a crash anywhere (T19 acceptance)

    /// The drive vanishes at the nth call of one operation; then a healthy run. The archive must end up
    /// exactly as an uninterrupted run leaves it: same names, same bytes, same tags, no duplicates.
    @Test func aRunCutOffAtAnyPointConvergesOnTheSameArchive() throws {
        let clean = try standardWorld()
        let counter = FaultyFileSystem()
        try clean.run(counter)
        let expected = try clean.archiveFiles()
        let everyPoint = ProcessInfo.processInfo.environment["FUJICULL_SLOW_TESTS"] == "1"

        var scenarios = 0
        for operation in FileOperation.allCases {
            let calls = counter.calls(operation)
            guard calls > 0 else { continue }
            // Every call when run at a checkpoint; otherwise the first, the middle and the last.
            let points = everyPoint ? Array(1...calls) : Array(Set([1, (calls + 1) / 2, calls])).sorted()
            for point in points {
                scenarios += 1
                let world = try standardWorld()
                do {
                    try world.run(FaultyFileSystem(.die(operation, call: point)))
                } catch {
                    // The first run may not even get started; that is one of the cases.
                }

                let (outcome, executor) = try world.run()

                let label: Comment = "after the drive vanished at \(operation) call \(point)"
                #expect(outcome.stopped == nil, label)
                #expect(try world.archiveFiles() == expected, label)
                #expect(try world.tags("Japan 2026/RAW/DSCF0001.RAF") == ["Favourite"], label)
                #expect(try world.tags("Japan 2026/JPG/DSCF0001.JPG") == ["Favourite"], label)
                #expect(executor.ledger.openReservations.isEmpty, label)
                #expect(try executor.finalCheck() == ApplyExecutor.FinalCheck(keepersOnArchive: 3, problems: []), label)
            }
        }
        #expect(scenarios >= 30)
    }

    // MARK: Google Photos copies

    @Test func aRunCutOffBeforeTheStagingCopiesMakesThemNextTime() throws {
        let world = try ApplyWorld()
        try world.addPair("DSCF0001", keepMark)
        // Folder creations: 1 the trip folder, 2 RAW, 3 JPG, 4 Google Photos.
        try world.run(FaultyFileSystem(.die(.createFolder, call: 4)))
        #expect(try world.archiveNames() == ["Japan 2026/JPG/DSCF0001.JPG", "Japan 2026/RAW/DSCF0001.RAF"])

        let (outcome, _) = try world.run()

        #expect(outcome.copied == [world.location("DSCF0001.JPG", in: "Google Photos")])
        #expect(
            try world.archiveFiles()["Japan 2026/Google Photos/DSCF0001.JPG"]
                == (try world.sha(ofCardFile: "DCIM/124_FUJI/DSCF0001.JPG")))
    }

    @Test func anArchiveJPGEditedSinceItWasVerifiedIsNotCopiedToGooglePhotos() throws {
        let world = try ApplyWorld()
        try world.addPair("DSCF0001", keepMark)
        try world.run(FaultyFileSystem(.die(.createFolder, call: 4)))
        try ApplyWorld.bytes(1_200, seed: 777).write(to: world.archive.url("Japan 2026/JPG/DSCF0001.JPG"))

        let (outcome, _) = try world.run()

        #expect(
            outcome.skipped == [
                ApplyExecutor.CopyOutcome.Skipped(
                    owner: .frame(FrameID("DCIM/124_FUJI/DSCF0001")), reason: .archiveJPGUnavailable)
            ])
        #expect(try world.archiveNames() == ["Japan 2026/JPG/DSCF0001.JPG", "Japan 2026/RAW/DSCF0001.RAF"])
    }

    // MARK: Tags on later runs (SR12)

    @Test func favouritingAndUnfavouritingLaterChangesOnlyOurTagAndKeepsTheOwners() throws {
        let world = try ApplyWorld()
        let id = try world.addPair("DSCF0001", keepMark)
        try world.run()
        try world.setTags(["Print"], on: "Japan 2026/JPG/DSCF0001.JPG")

        world.marks[id] = favouriteMark
        let (favoured, tagged) = try world.run()

        #expect(favoured.copied.isEmpty)
        #expect(try world.tags("Japan 2026/RAW/DSCF0001.RAF") == ["Favourite"])
        #expect(Set(try world.tags("Japan 2026/JPG/DSCF0001.JPG")) == ["Favourite", "Print"])
        #expect(tagged.ledger.file(at: world.location("DSCF0001.JPG"))?.taggedByUs == true)

        world.marks[id] = keepMark
        let (_, untagged) = try world.run()

        #expect(try world.tags("Japan 2026/RAW/DSCF0001.RAF").isEmpty)
        #expect(try world.tags("Japan 2026/JPG/DSCF0001.JPG") == ["Print"], "the owner's own tag is left alone")
        #expect(untagged.ledger.file(at: world.location("DSCF0001.JPG"))?.taggedByUs == false)
    }

    @Test func aTagThatCannotBeSetIsReportedAndPlannedAgainNextRun() throws {
        let world = try ApplyWorld()
        try world.addPair("DSCF0001", favouriteMark)

        let (outcome, executor) = try world.run(FaultyFileSystem(.fail(.writeTags, call: 1, code: EIO)))

        #expect(outcome.stopped == nil, "a tag is not worth stopping a copy run for")
        #expect(outcome.tagFailures == [world.location("DSCF0001.RAF")])
        #expect(outcome.copied.count == 3)
        #expect(executor.ledger.file(at: world.location("DSCF0001.RAF"))?.taggedByUs == false)

        try world.run()

        #expect(try world.tags("Japan 2026/RAW/DSCF0001.RAF") == ["Favourite"])
    }

    @Test func aNewFileStartsWithExactlyTheTagsFujiCullIntends() throws {
        // On exFAT a new file can inherit a tag from an orphaned `._` companion. Simulated here by a tag
        // that is already on the file the moment it gets its final name.
        let world = try ApplyWorld()
        try world.addPair("DSCF0001", keepMark)
        let target = world.archive.url("Japan 2026/RAW/DSCF0001.RAF")
        let fs = FaultyFileSystem(
            .after(.rename, call: 1) {
                do {
                    try (target as NSURL).setResourceValue(["Favourite", "Stale"], forKey: .tagNamesKey)
                } catch {
                    Issue.record("could not plant the stale tag: \(error)")
                }
            })

        try world.run(fs)

        #expect(try world.tags("Japan 2026/RAW/DSCF0001.RAF").isEmpty)
    }

    // MARK: The final check (SR28)

    @Test func theFinalCheckReportsMissingChangedAndUnarchivedKeepers() throws {
        let world = try standardWorld()
        try world.run()
        try FileManager.default.removeItem(at: world.archive.url("Japan 2026/RAW/DSCF0001.RAF"))
        try Data("truncated".utf8).write(to: world.archive.url("Japan 2026/JPG/DSCF0002.JPG"))
        try FileManager.default.removeItem(at: world.archive.url("Japan 2026/Google Photos/DSCF0001.JPG"))
        let late = try world.addPair("DSCF0006", keepMark)

        let check = try world.executor().finalCheck()

        #expect(check.keepersOnArchive == 1, "only the video is whole")
        #expect(
            check.problems == [
                .init(owner: .frame(FrameID("DCIM/124_FUJI/DSCF0001")), kind: .missing(world.location("DSCF0001.RAF"))),
                .init(owner: .frame(FrameID("DCIM/124_FUJI/DSCF0002")), kind: .changed(world.location("DSCF0002.JPG"))),
                .init(owner: .frame(late), kind: .notArchived(.raw)),
                .init(owner: .frame(late), kind: .notArchived(.jpg)),
            ], "the emptied Google Photos copy is not a problem")
    }

    @Test func keepersFiledUnderAnEarlierFolderAreCheckedThere() throws {
        let world = try ApplyWorld()
        try world.addPair("DSCF0001", keepMark)
        try world.run()
        world.destination = Ledger.Destination(volumeUUID: world.archiveUUID, folder: "Japan 2026 part 2")
        try world.addPair("DSCF0002", keepMark)

        let (outcome, executor) = try world.run()

        #expect(outcome.copied.allSatisfy { $0.folder == "Japan 2026 part 2" && $0.name.contains("DSCF0002") })
        #expect(try executor.finalCheck() == ApplyExecutor.FinalCheck(keepersOnArchive: 2, problems: []))
    }

    @Test func aKeeperOnADriveThatIsNotConnectedIsReportedNotAssumed() throws {
        let world = try ApplyWorld()
        try world.addPair("DSCF0001", keepMark)
        try world.run()
        // The drive that holds the keeper isn't plugged in this time; new copies would go to another one.
        world.archiveRoots = ["SECOND-DRIVE": world.archive.root.path]
        world.destination = Ledger.Destination(volumeUUID: "SECOND-DRIVE", folder: "Elsewhere")

        let check = try world.executor().finalCheck()

        #expect(check.keepersOnArchive == 0)
        let elsewhere = Ledger.Destination(volumeUUID: world.archiveUUID, folder: "Japan 2026")
        #expect(
            check.problems.map(\.kind) == [.unreachable(elsewhere), .unreachable(elsewhere)], "its RAF and its JPG")
    }

    // MARK: The right card, the right drive (SR7, SR16)

    @Test func aCardThatIsNotTheOneTheSessionBelongsToIsRefused() throws {
        let world = try standardWorld()
        world.cardUUID = "DB8E88CF-NOT-THIS-CARD"

        #expect(throws: ApplyStop.wrongCard) { try world.executor() }
    }

    @Test func anotherVolumeMountedWhereTheArchiveShouldBeIsRefused() throws {
        let world = try standardWorld()
        world.archiveRoots = ["EXPECTED-ARCHIVE": world.archive.root.path]
        world.destination = Ledger.Destination(volumeUUID: "EXPECTED-ARCHIVE", folder: "Japan 2026")
        let executor = try world.executor()

        #expect(throws: ApplyStop.wrongArchive(expected: "EXPECTED-ARCHIVE", found: world.archiveUUID)) {
            try executor.makePlan()
        }
        #expect(try world.archiveNames().isEmpty)
    }

    @Test func anArchiveThatIsNotConnectedStopsBeforeAnything() throws {
        let world = try standardWorld()
        world.archiveRoots = [:]
        let executor = try world.executor()

        #expect(throws: ApplyStop.archiveNotConnected(volumeUUID: world.archiveUUID)) { try executor.makePlan() }
    }

    @Test func aPlanThatCannotBeMadeIsReportedWithItsReason() throws {
        let world = try standardWorld()
        let executor = try world.executor(FaultyFileSystem(freeBytes: 1_000))

        do {
            _ = try executor.makePlan()
            Issue.record("expected the plan to be refused for lack of space")
        } catch ApplyStop.plan(.insufficientSpace(_, let available)) {
            #expect(available == 1_000)
        }
    }
}
