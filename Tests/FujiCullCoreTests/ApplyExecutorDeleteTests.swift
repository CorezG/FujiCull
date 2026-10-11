import Foundation
import Testing

@testable import FujiCullCore

private let reject4 = ["DCIM/124_FUJI/DSCF0004.RAF", "DCIM/124_FUJI/DSCF0004.JPG"]

// The executor, part 2: the gate, archive removal and card deletion (DESIGN §5.7 steps 5–8; R22, R26; SR8,
// SR16–SR19, SR25, SR27). The question every test here asks: could a photo be lost?
@Suite struct ApplyExecutorDeleteTests {

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

    private func frameID(_ name: String) -> FrameID { FrameID("DCIM/124_FUJI/\(name)") }

    // MARK: A healthy run (R22, R24)

    @Test func rejectsAreDeletedOnlyAfterEveryKeeperIsOnTheArchive() throws {
        let world = try standardWorld()
        let before = try world.cardNames()
        var asked: ApplyExecutor.Confirmation?

        let done = try world.apply(confirm: {
            asked = $0
            return true
        })

        #expect(done.gate.allowsRemoval)
        #expect(asked == ApplyExecutor.Confirmation(toTrash: [], toDelete: reject4, deleteMode: .permanent))
        #expect(done.removal.deleted == reject4)
        #expect(
            try world.cardNames() == before.filter { !reject4.contains($0) },
            "keepers and the undecided frame stay (R24)")
        #expect(FileManager.default.fileExists(atPath: world.card.url("DCIM/124_FUJI/DSCF0005.MOV").path))
        #expect(done.executor.ledger.cardFileStatus(reject4[0]) == .deleted)
        #expect(done.executor.ledger.unsettledDeletes.isEmpty)
    }

    @Test func decliningTheConfirmationDeletesNothing() throws {
        let world = try standardWorld()
        let before = try world.cardNames()

        let done = try world.apply(confirm: { _ in false })

        #expect(done.removal == ApplyExecutor.RemovalOutcome(declined: true))
        #expect(try world.cardNames() == before)
        #expect(done.executor.ledger.cardFileStatus(reject4[0]) == nil, "not even an intent is recorded")
        #expect(done.copy.copied.count == 7, "the keepers were still copied")
    }

    @Test func aRunWithNothingToRemoveAsksNothing() throws {
        let world = try ApplyWorld()
        try world.addPair("DSCF0001", keepMark)
        var asked = false

        let done = try world.apply(confirm: { _ in
            asked = true
            return true
        })

        #expect(!asked)
        #expect(done.removal == ApplyExecutor.RemovalOutcome())
    }

    @Test func theSummaryReportsWhatWasDoneAndWhatIsLeft() throws {
        let world = try standardWorld()

        let summary = try world.apply().summary

        #expect(summary.copiedFiles == 7)
        #expect(summary.copiedBytes == 2 * (3_000 + 1_200 + 1_200) + 5_000)
        #expect(summary.keepersOnArchive == 3)
        #expect(summary.deletedFromCard == reject4)
        #expect(summary.leftOnCard.undecided == [frameID("DSCF0003")])
        #expect(summary.problems.isEmpty && summary.gateBlockers.isEmpty && summary.trashed.isEmpty)
        #expect(summary.stopped == nil && !summary.declined)
    }

    @Test func theSummaryOfARunThatStoppedWhileCopyingSaysSoAndReportsNothingRemoved() throws {
        let world = try standardWorld()
        let executor = try world.executor(FaultyFileSystem(.fail(.write, call: 2, code: ENOSPC)))
        let plan = try executor.makePlan()
        let copy = executor.copy(plan, isCancelled: { false })
        let check = try executor.finalCheck()

        // The app shows this without ever reaching the gate.
        let summary = ApplySummary(plan: plan, copy: copy, check: check, gate: nil, removal: nil)

        #expect(summary.stopped == copy.stopped && summary.stopped != nil)
        #expect(summary.copiedFiles == 1 && summary.copiedBytes == 3_000)
        #expect(summary.keepersOnArchive == 0)
        #expect(summary.problems.count == 4, "one RAF copied; its JPG, the other pair and the video are not archived")
        #expect(summary.trashed.isEmpty && summary.deletedFromCard.isEmpty && summary.skippedRemovals.isEmpty)
        #expect(summary.gateBlockers.isEmpty && !summary.declined)
    }

    @Test func theSummaryOfADeclinedRunSaysNothingWasRemoved() throws {
        let world = try standardWorld()

        let summary = try world.apply(confirm: { _ in false }).summary

        #expect(summary.declined)
        #expect(summary.deletedFromCard.isEmpty && summary.copiedFiles == 7 && summary.stopped == nil)
    }

    @Test func theSummaryListsDuplicatesLeftByRehomingAndSkippedRemovals() throws {
        let (world, id) = try rejectedAfterArchiving()
        try ApplyWorld.bytes(1_200, seed: 555).write(to: world.archive.url("Japan 2026/JPG/DSCF0001.JPG"))
        let done = try world.apply()
        var plan = done.plan
        plan.superseded = [world.location("DSCF0009.RAF")]

        let summary = ApplySummary(
            plan: plan, copy: done.copy, check: done.check, gate: done.gate, removal: done.removal)

        #expect(summary.duplicatesLeft == [world.location("DSCF0009.RAF")])
        #expect(
            summary.skippedRemovals == [.init(frame: id, reason: .archiveFileChanged(world.location("DSCF0001.JPG")))])
        #expect(summary.notDeleted.isEmpty && summary.skippedCopies.isEmpty && summary.tagFailures.isEmpty)
    }

    @Test func deletedFoldersAreMadeDurableOnTheCard() throws {
        let world = try standardWorld()
        try world.addPair("DSCF0009", rejectMark, folder: "DCIM/125_FUJI")
        let fs = FaultyFileSystem()
        let executor = try world.executor(fs)
        let plan = try executor.makePlan()
        let copy = executor.copy(plan, isCancelled: { false })
        let gate = try executor.gate(
            plan: plan, outcome: copy, check: try executor.finalCheck(), isCancelled: { false })
        let before = fs.calls(.syncFolder)

        _ = executor.removeAndDelete(plan, gate: gate, confirm: { _ in true }, isCancelled: { false })

        #expect(fs.calls(.syncFolder) - before == 2, "one sync for each card folder that had deletions (SR27)")
    }

    // MARK: The gate (SR17): nothing is deleted unless every keeper is provably on the archive

    /// One file-system call fails during the copy run, at any point; everything after it works. Whatever
    /// happens, a card file may only be deleted if every keeper is on the archive, byte for byte.
    @Test func noFailureDuringCopyingEverLeadsToADeleteWithoutEveryKeeperArchived() throws {
        let clean = try standardWorld()
        let counter = FaultyFileSystem()
        try clean.run(counter)
        let keepers = try clean.archiveFiles().filter { !$0.key.contains("Google Photos") }
        let everyPoint = ProcessInfo.processInfo.environment["FUJICULL_SLOW_TESTS"] == "1"

        var scenarios = 0
        var blocked = 0
        for operation in FileOperation.allCases {
            let calls = counter.calls(operation)
            guard calls > 0 else { continue }
            let points = everyPoint ? Array(1...calls) : Array(Set([1, (calls + 1) / 2, calls])).sorted()
            for point in points {
                scenarios += 1
                let world = try standardWorld()
                let cardBefore = try world.cardNames()
                let label: Comment = "\(operation) call \(point) failed"
                do {
                    let done = try world.apply(FaultyFileSystem(.fail(operation, call: point, code: EIO)))
                    if done.removal.deleted.isEmpty { blocked += 1 }
                } catch {
                    // Planning or the final check couldn't run at all: nothing can have been deleted.
                    blocked += 1
                }
                let archived = try world.archiveFiles()
                let allKeepersArchived = keepers.allSatisfy { archived[$0.key] == $0.value }
                if try world.cardNames() != cardBefore {
                    #expect(allKeepersArchived, label)
                }
                #expect(
                    try world.cardNames().filter { !reject4.contains($0) }
                        == cardBefore.filter { !reject4.contains($0) }, label)
                #expect(try world.archiveNames().allSatisfy { !$0.contains(".TestTrash") }, label)
            }
        }
        #expect(scenarios >= 30)
        #expect(blocked > 0, "at least some failures must have closed the gate, or the test proves nothing")
    }

    @Test(arguments: [
        FaultyFileSystem.Fault.fail(.write, call: 3, code: ENOSPC), .fail(.syncFile, call: 2, code: ENOTTY),
        .corruptReads(nameContains: "DSCF0002.RAF.fujicull-partial"), .fail(.rename, call: 4, code: EIO),
        .fail(.syncFolder, call: 3, code: EIO), .fail(.createFolder, call: 2, code: EIO),
    ])
    func aFailedCopyRunClosesTheGateAndNothingIsDeleted(fault: FaultyFileSystem.Fault) throws {
        let world = try standardWorld()
        let before = try world.cardNames()

        let done = try world.apply(FaultyFileSystem(fault))

        #expect(done.copy.stopped != nil)
        #expect(!done.gate.allowsRemoval)
        #expect(done.removal == ApplyExecutor.RemovalOutcome(stopped: .gateClosed))
        #expect(try world.cardNames() == before, "zero files deleted from the card")
        #expect(done.summary.gateBlockers.isEmpty == false)
    }

    @Test func aSkippedKeeperClosesTheGate() throws {
        // Its card file changed after the scan, so it wasn't copied; a reject must not be deleted meanwhile.
        let world = try standardWorld()
        let executor = try world.executor()
        let plan = try executor.makePlan()
        try ApplyWorld.bytes(3_000, seed: 999).write(to: world.card.url("DCIM/124_FUJI/DSCF0002.RAF"))
        let before = try world.cardNames()

        let copy = executor.copy(plan, isCancelled: { false })
        let check = try executor.finalCheck()
        let gate = try executor.gate(plan: plan, outcome: copy, check: check, isCancelled: { false })
        let removal = executor.removeAndDelete(plan, gate: gate, confirm: { _ in true }, isCancelled: { false })

        #expect(copy.stopped == nil && copy.skipped.count == 1)
        #expect(
            gate.blockers.contains(
                .keeperNotOnArchive(.init(owner: .frame(frameID("DSCF0002")), kind: .notArchived(.raw)))))
        #expect(removal.stopped == .gateClosed)
        #expect(try world.cardNames() == before)
    }

    @Test func aKeeperThatWentMissingFromTheArchiveClosesTheGate() throws {
        let world = try standardWorld()
        world.marks[frameID("DSCF0004")] = FrameMark()  // first run: nothing to delete
        try world.apply()
        try FileManager.default.removeItem(at: world.archive.url("Japan 2026/JPG/DSCF0001.JPG"))
        world.marks[frameID("DSCF0004")] = rejectMark
        let before = try world.cardNames()

        let done = try world.apply()

        #expect(
            done.gate.blockers == [
                .keeperNotOnArchive(
                    .init(owner: .frame(frameID("DSCF0001")), kind: .missing(world.location("DSCF0001.JPG"))))
            ])
        #expect(try world.cardNames() == before)
    }

    @Test func aKeeperArchivedEarlierThatNoLongerHashesTheSameClosesTheGate() throws {
        // Same size, so the final check passes; the gate reads the file and finds different bytes.
        let world = try standardWorld()
        world.marks[frameID("DSCF0004")] = FrameMark()
        try world.apply()
        try ApplyWorld.bytes(3_000, seed: 4_242).write(to: world.archive.url("Japan 2026/RAW/DSCF0002.RAF"))
        world.marks[frameID("DSCF0004")] = rejectMark
        let before = try world.cardNames()

        let done = try world.apply()

        #expect(done.check.problems.isEmpty)
        #expect(done.gate.blockers == [.earlierCopyChanged(world.location("DSCF0002.RAF"))])
        #expect(done.removal.stopped == .gateClosed)
        #expect(try world.cardNames() == before)
    }

    @Test func filesCopiedInThisRunAreNotReadAThirdTimeByTheGate() throws {
        let world = try standardWorld()
        let fs = FaultyFileSystem()
        let executor = try world.executor(fs)
        let plan = try executor.makePlan()
        let copy = executor.copy(plan, isCancelled: { false })
        let check = try executor.finalCheck()
        let opens = fs.calls(.openForReading)

        let gate = try executor.gate(plan: plan, outcome: copy, check: check, isCancelled: { false })

        #expect(gate.allowsRemoval)
        #expect(fs.calls(.openForReading) == opens, "they were hashed from the device minutes ago")
    }

    @Test func anEmptiedGooglePhotosFolderDoesNotCloseTheGate() throws {
        let world = try standardWorld()
        world.marks[frameID("DSCF0004")] = FrameMark()
        try world.apply()
        try FileManager.default.removeItem(at: world.archive.url("Japan 2026/Google Photos"))
        world.marks[frameID("DSCF0004")] = rejectMark

        let done = try world.apply()

        #expect(done.gate.allowsRemoval)
        #expect(done.removal.deleted == reject4)
    }

    @Test func aKeeperOnADriveThatIsNotConnectedClosesTheGate() throws {
        let world = try standardWorld()
        world.marks[frameID("DSCF0004")] = FrameMark()
        try world.apply()
        world.archiveRoots = ["SECOND-DRIVE": world.archive.root.path]
        world.destination = Ledger.Destination(volumeUUID: "SECOND-DRIVE", folder: "Elsewhere")
        world.marks[frameID("DSCF0004")] = rejectMark
        let before = try world.cardNames()
        let executor = try world.executor()
        let plan = try ApplyPlanner.plan(
            ApplyInput(
                frames: try world.context().frames, marks: world.marks, captureTimes: try world.context().captureTimes,
                ledger: executor.ledger, source: try world.context().source, destination: world.destination,
                freeBytes: 1_000_000_000_000, allocationSize: 4096))

        let check = try executor.finalCheck()
        let gate = try executor.gate(
            plan: plan, outcome: ApplyExecutor.CopyOutcome(), check: check, isCancelled: { false })
        let removal = executor.removeAndDelete(plan, gate: gate, confirm: { _ in true }, isCancelled: { false })

        #expect(
            gate.blockers.contains(
                .destinationUnreachable(Ledger.Destination(volumeUUID: world.archiveUUID, folder: "Japan 2026"))))
        #expect(removal.stopped == .gateClosed)
        #expect(try world.cardNames() == before)
    }

    // MARK: Deleting from the card (SR19)

    @Test func aCardFileChangedSinceTheScanIsSkippedAndReported() throws {
        let world = try standardWorld()
        try world.addPair("DSCF0006", rejectMark)
        let executor = try world.executor()
        let plan = try executor.makePlan()
        let copy = executor.copy(plan, isCancelled: { false })
        let gate = try executor.gate(
            plan: plan, outcome: copy, check: try executor.finalCheck(), isCancelled: { false })
        // Rewritten after the scan: this is no longer the file that was looked at and rejected.
        try ApplyWorld.bytes(1_200, seed: 31).write(to: world.card.url("DCIM/124_FUJI/DSCF0004.JPG"))

        let removal = executor.removeAndDelete(plan, gate: gate, confirm: { _ in true }, isCancelled: { false })

        #expect(
            removal.skipped == [
                .init(frame: frameID("DSCF0004"), reason: .cardFileChanged("DCIM/124_FUJI/DSCF0004.JPG"))
            ])
        #expect(
            try world.cardNames().filter { $0.contains("DSCF0004") } == reject4,
            "neither file of the pair is deleted")
        #expect(
            removal.deleted == ["DCIM/124_FUJI/DSCF0006.RAF", "DCIM/124_FUJI/DSCF0006.JPG"],
            "the other reject still goes")
    }

    @Test func aLockedCardFileStopsItsWholeFrameFromBeingDeleted() throws {
        let world = try standardWorld()
        let locked = world.card.url("DCIM/124_FUJI/DSCF0004.JPG")
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: locked.path)
        defer {
            do {
                try FileManager.default.setAttributes([.immutable: false], ofItemAtPath: locked.path)
            } catch {
                Issue.record("could not unlock the test file: \(error)")
            }
        }

        let done = try world.apply()

        #expect(
            done.removal.skipped == [
                .init(frame: frameID("DSCF0004"), reason: .cardFileLocked("DCIM/124_FUJI/DSCF0004.JPG"))
            ])
        #expect(done.removal.deleted.isEmpty, "the RAF isn't deleted on its own")
    }

    @Test func ifTheSecondFileOfAPairCannotBeDeletedItIsReportedAndFinishedNextRun() throws {
        let world = try standardWorld()

        let done = try world.apply(FaultyFileSystem(.fail(.remove, call: 2, code: EIO)))

        #expect(done.removal.deleted == [reject4[0]])
        #expect(done.removal.skipped == [.init(frame: frameID("DSCF0004"), reason: .pairSplit(remaining: reject4[1]))])
        #expect(done.executor.ledger.unsettledDeletes == [reject4[1]])

        let again = try world.apply()

        #expect(again.removal.deleted == [reject4[1]], "the frame is still Reject, now with one file")
        #expect(try world.cardNames().filter { $0.contains("DSCF0004") }.isEmpty)
    }

    @Test func aDeleteThatHappenedButWasNotRecordedIsSettledOnTheNextRun() throws {
        // The app died between the unlink and its record (SR25).
        let world = try standardWorld()
        try LedgerJournal.open(at: world.journalURL).journal.append(.deleting(path: reject4[0]))
        try FileManager.default.removeItem(at: world.card.url(reject4[0]))

        let executor = try world.executor()
        let recovery = try executor.recover()

        #expect(recovery.settledDeletes == [reject4[0]])
        #expect(executor.ledger.cardFileStatus(reject4[0]) == .deleted)
        #expect(executor.ledger.unsettledDeletes.isEmpty)
    }

    @Test func cancellingDuringDeletionStopsBeforeTheNextFrame() throws {
        let world = try standardWorld()
        try world.addPair("DSCF0006", rejectMark)
        let executor = try world.executor()
        let plan = try executor.makePlan()
        let copy = executor.copy(plan, isCancelled: { false })
        let gate = try executor.gate(
            plan: plan, outcome: copy, check: try executor.finalCheck(), isCancelled: { false })
        var checks = 0

        let removal = executor.removeAndDelete(
            plan, gate: gate, confirm: { _ in true },
            isCancelled: {
                checks += 1
                return checks > 1
            })

        #expect(removal.stopped == .cancelled)
        #expect(removal.deleted == reject4, "the frame in progress is finished; the next isn't started")
        #expect(try world.cardNames().contains("DCIM/124_FUJI/DSCF0006.RAF"))
    }

    @Test func aPlanThatNamesAKeeperForDeletionIsRefused() throws {
        // A plan is only data. Whatever it says, the executor checks the decision itself before it deletes.
        let world = try standardWorld()
        let executor = try world.executor()
        var plan = try executor.makePlan()
        let copy = executor.copy(plan, isCancelled: { false })
        let gate = try executor.gate(
            plan: plan, outcome: copy, check: try executor.finalCheck(), isCancelled: { false })
        plan.cardDeletes = [
            ApplyPlan.CardDelete(frame: frameID("DSCF0001"), paths: ["DCIM/124_FUJI/DSCF0001.RAF"]),
            ApplyPlan.CardDelete(frame: frameID("DSCF0003"), paths: ["DCIM/124_FUJI/DSCF0003.JPG"]),
            ApplyPlan.CardDelete(frame: frameID("DSCF0004"), paths: ["DCIM/124_FUJI/DSCF0002.JPG"]),
        ]
        let before = try world.cardNames()

        let removal = executor.removeAndDelete(plan, gate: gate, confirm: { _ in true }, isCancelled: { false })

        #expect(removal.deleted.isEmpty)
        #expect(
            removal.skipped.map(\.reason) == [
                .notRejected, .notRejected, .notThisFramesFile("DCIM/124_FUJI/DSCF0002.JPG"),
            ])
        #expect(try world.cardNames() == before)
    }

    @Test func aLockedCardKeepsItsRejectsButConfirmedArchiveRemovalsStillHappen() throws {
        let world = try ApplyWorld()
        let id = try world.addPair("DSCF0001", keepMark)
        try world.apply()
        world.marks[id] = rejectMark
        world.cardIsReadOnly = true
        let before = try world.cardNames()

        let done = try world.apply()

        #expect(done.plan.notDeleted == [ApplyPlan.NotDeleted(frame: id, reason: .cardLocked)])
        #expect(done.removal.trashed.count == 3)
        #expect(done.removal.deleted.isEmpty)
        #expect(try world.cardNames() == before)
    }

    @Test func rejectsOnASourceThatIsNotACameraCardGoToTheTrashNotOblivion() throws {
        let world = try standardWorld()
        world.cardIsCameraCard = false
        let fs = FaultyFileSystem()

        let done = try world.apply(fs)

        #expect(done.plan.deleteMode == .trash)
        #expect(done.removal.deleted == reject4)
        #expect(fs.calls(.remove) == 0, "nothing was unlinked")
        #expect(try FileManager.default.contentsOfDirectory(atPath: world.card.url(".TestTrash").path).count == 2)
    }

    // MARK: Removing archive copies of frames rejected later (D6, R26, SR18)

    /// One keeper archived by a first run, then rejected.
    private func rejectedAfterArchiving() throws -> (world: ApplyWorld, id: FrameID) {
        let world = try ApplyWorld()
        let id = try world.addPair("DSCF0001", keepMark)
        try world.addPair("DSCF0002", keepMark)
        try world.apply()
        world.marks[id] = rejectMark
        return (world, id)
    }

    @Test func rejectingAnArchivedFrameMovesItsArchiveCopiesToTheTrashAndDeletesItFromTheCard() throws {
        let (world, _) = try rejectedAfterArchiving()
        var asked: ApplyExecutor.Confirmation?

        let done = try world.apply(confirm: {
            asked = $0
            return true
        })

        let gone = [
            world.location("DSCF0001.RAF"), world.location("DSCF0001.JPG"),
            world.location("DSCF0001.JPG", in: "Google Photos"),
        ]
        #expect(asked?.toTrash == gone)
        #expect(done.removal.trashed.map(\.location) == gone)
        #expect(
            done.removal.trashed.allSatisfy { $0.trashPath.map { FileManager.default.fileExists(atPath: $0) } == true },
            "moved, not destroyed")
        #expect(
            try world.archiveNames().filter { !$0.contains(".TestTrash") } == [
                "Japan 2026/Google Photos/DSCF0002.JPG", "Japan 2026/JPG/DSCF0002.JPG", "Japan 2026/RAW/DSCF0002.RAF",
            ])
        #expect(try world.cardNames() == ["DCIM/124_FUJI/DSCF0002.RAF", "DCIM/124_FUJI/DSCF0002.JPG"])
        #expect(done.executor.ledger.file(at: gone[0])?.status == .trashed)
        #expect(done.executor.ledger.file(at: gone[0])?.trashPath == done.removal.trashed[0].trashPath)
    }

    @Test func aSecondRunAfterARemovalPlansNothingMore() throws {
        let (world, _) = try rejectedAfterArchiving()
        try world.apply()

        let again = try world.apply()

        #expect(again.plan.removals.isEmpty && again.plan.cardDeletes.isEmpty && again.plan.copies.isEmpty)
    }

    @Test func anArchiveFileChangedSinceItWasVerifiedIsSkippedAndReported() throws {
        // Edited by the owner after archiving: it isn't the file FujiCull wrote any more, so it stays.
        let (world, id) = try rejectedAfterArchiving()
        try ApplyWorld.bytes(1_200, seed: 555).write(to: world.archive.url("Japan 2026/JPG/DSCF0001.JPG"))

        let done = try world.apply()

        #expect(done.removal.skipped == [.init(frame: id, reason: .archiveFileChanged(world.location("DSCF0001.JPG")))])
        #expect(done.removal.trashed.isEmpty, "the RAF isn't removed on its own")
        #expect(FileManager.default.fileExists(atPath: world.archive.url("Japan 2026/RAW/DSCF0001.RAF").path))
    }

    @Test func anArchiveFileThatHasGoneSkipsTheFrame() throws {
        let (world, id) = try rejectedAfterArchiving()
        try FileManager.default.removeItem(at: world.archive.url("Japan 2026/RAW/DSCF0001.RAF"))

        let done = try world.apply()

        #expect(done.removal.skipped == [.init(frame: id, reason: .archiveFileMissing(world.location("DSCF0001.RAF")))])
        #expect(done.removal.trashed.isEmpty)
    }

    @Test func aStagingCopyThatWasEditedIsLeftAloneAndTheRestIsRemoved() throws {
        let (world, _) = try rejectedAfterArchiving()
        try ApplyWorld.bytes(1_200, seed: 556).write(to: world.archive.url("Japan 2026/Google Photos/DSCF0001.JPG"))

        let done = try world.apply()

        #expect(
            done.removal.trashed.map(\.location) == [world.location("DSCF0001.RAF"), world.location("DSCF0001.JPG")])
        #expect(FileManager.default.fileExists(atPath: world.archive.url("Japan 2026/Google Photos/DSCF0001.JPG").path))
    }

    @Test func aTrashMoveThatFailsIsNeverReplacedByADelete() throws {
        let (world, id) = try rejectedAfterArchiving()
        let fs = FaultyFileSystem(.fail(.trash, call: 1, code: EIO))

        let done = try world.apply(fs)

        #expect(done.removal.skipped == [.init(frame: id, reason: .trashFailed(world.location("DSCF0001.RAF")))])
        #expect(done.removal.trashed.isEmpty)
        #expect(FileManager.default.fileExists(atPath: world.archive.url("Japan 2026/RAW/DSCF0001.RAF").path))
        // The only unlinks in the whole run are the frame's two card files.
        #expect(fs.calls(.remove) == 2)
        #expect(done.executor.ledger.unsettledTrashes.map(\.location) == [world.location("DSCF0001.RAF")])
    }

    @Test func aTrashMoveThatHappenedButWasNotRecordedIsSettledAndTheFrameFinished() throws {
        // The app died between the move and its record (SR25): the frame must not be skipped for ever.
        let (world, _) = try rejectedAfterArchiving()
        try LedgerJournal.open(at: world.journalURL).journal.append(.trashing(location: world.location("DSCF0001.RAF")))
        try FileManager.default.removeItem(at: world.archive.url("Japan 2026/RAW/DSCF0001.RAF"))

        let executor = try world.executor()
        let recovery = try executor.recover()
        #expect(recovery.settledTrashes == [world.location("DSCF0001.RAF")])

        let done = try world.apply()

        #expect(
            done.removal.trashed.map(\.location) == [
                world.location("DSCF0001.JPG"), world.location("DSCF0001.JPG", in: "Google Photos"),
            ])
        #expect(done.removal.skipped.isEmpty)
    }

    @Test func aPlanThatNamesSomeoneElsesArchiveFileForRemovalIsRefused() throws {
        // Only a file this journal records as verified for this very frame can ever be moved to the Trash.
        let (world, id) = try rejectedAfterArchiving()
        let foreign = world.archive.url("Japan 2026/Holiday.JPG")
        try Data("not FujiCull's".utf8).write(to: foreign)
        let executor = try world.executor()
        var plan = try executor.makePlan()
        let gate = try executor.gate(
            plan: plan, outcome: ApplyExecutor.CopyOutcome(), check: try executor.finalCheck(), isCancelled: { false })
        plan.removals = [
            ApplyPlan.Removal(frame: id, files: [world.location("Holiday.JPG")]),
            ApplyPlan.Removal(frame: id, files: [world.location("DSCF0002.RAF")]),
        ]
        plan.cardDeletes = []

        let removal = executor.removeAndDelete(plan, gate: gate, confirm: { _ in true }, isCancelled: { false })

        #expect(removal.trashed.isEmpty)
        #expect(
            removal.skipped.map(\.reason) == [.notThisFramesFile("Holiday.JPG"), .notThisFramesFile("DSCF0002.RAF")])
        #expect(FileManager.default.fileExists(atPath: foreign.path))
        #expect(FileManager.default.fileExists(atPath: world.archive.url("Japan 2026/RAW/DSCF0002.RAF").path))
    }
}
