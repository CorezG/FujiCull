import Foundation
import Testing

@testable import FujiCullCore

extension ApplyWorld {
    /// The setup the app would hand over: the frames as culled, the decisions, where things are.
    func setup() throws -> ApplyRun.Setup {
        let context = try context()
        return ApplyRun.Setup(
            cardRoot: card.root, frames: context.frames, marks: marks, captureTimes: context.captureTimes,
            source: context.source, destination: destination, archiveRoots: archiveRoots, journalURL: journalURL,
            locksDirectory: state.root)
    }
}

// A whole Apply as the screens drive it: pre-flight, copy, confirm, remove (DESIGN §5.7; SR3, SR16, SR26).
@Suite struct ApplyRunTests {
    private let reject4 = ["DCIM/124_FUJI/DSCF0004.RAF", "DCIM/124_FUJI/DSCF0004.JPG"]

    private func standardWorld() throws -> ApplyWorld {
        let world = try ApplyWorld()
        try world.addPair("DSCF0001", favouriteMark)
        try world.addPair("DSCF0002", keepMark)
        try world.addPair("DSCF0003", FrameMark())
        try world.addPair("DSCF0004", rejectMark)
        try world.addVideo("DSCF0005")
        return world
    }

    @Test func aWholeRunGoesPreflightCopyConfirmRemove() async throws {
        let world = try standardWorld()
        let run = try ApplyRun(fs: FaultyFileSystem(), setup: try world.setup())

        let preflight = try await run.preflight()
        #expect(
            preflight.keepers == 2 && preflight.favourites == 1 && preflight.rejects == 1 && preflight.undecided == 1)
        #expect(preflight.videos == 1)
        #expect(preflight.copyBytes == 2 * (3_000 + 1_200 + 1_200) + 5_000)
        #expect(preflight.plan.destinationState == .new)
        #expect(try world.archiveNames().isEmpty, "pre-flight copies nothing")

        let report = try await run.copy()
        #expect(report.outcome.copied.count == 7 && report.blockers.isEmpty)
        #expect(report.check.keepersOnArchive == 3)
        #expect(
            report.confirmation == ApplyExecutor.Confirmation(toTrash: [], toDelete: reject4, deleteMode: .permanent))
        #expect(try world.cardNames().count == 8, "copying deletes nothing")

        let summary = await run.finish(confirmed: true)
        #expect(summary.deletedFromCard == reject4)
        #expect(summary.copiedFiles == 7 && summary.keepersOnArchive == 3)
        #expect(await run.ledger.framesDeletedFromCard.contains(FrameID("DCIM/124_FUJI/DSCF0004")))
    }

    @Test func decliningAtTheConfirmationLeavesTheCardAsItWas() async throws {
        let world = try standardWorld()
        let run = try ApplyRun(fs: FaultyFileSystem(), setup: try world.setup())
        _ = try await run.preflight()
        _ = try await run.copy()

        let summary = await run.finish(confirmed: false)

        #expect(summary.declined && summary.deletedFromCard.isEmpty)
        #expect(try world.cardNames().count == 8)
    }

    @Test func aRunWithNothingToRemoveHasNothingToConfirm() async throws {
        let world = try ApplyWorld()
        try world.addPair("DSCF0001", keepMark)
        let run = try ApplyRun(fs: FaultyFileSystem(), setup: try world.setup())
        _ = try await run.preflight()

        let report = try await run.copy()

        #expect(report.confirmation == nil && report.blockers.isEmpty)
        #expect(await run.finish(confirmed: true).deletedFromCard.isEmpty)
    }

    @Test func aClosedGateOffersNothingToConfirmAndFinishRemovesNothing() async throws {
        let world = try standardWorld()
        let run = try ApplyRun(fs: FaultyFileSystem(.fail(.write, call: 3, code: ENOSPC)), setup: try world.setup())
        _ = try await run.preflight()

        let report = try await run.copy()
        let summary = await run.finish(confirmed: true)

        #expect(report.outcome.stopped != nil)
        #expect(report.confirmation == nil && !report.blockers.isEmpty)
        #expect(summary.deletedFromCard.isEmpty && summary.stopped != nil)
        #expect(try world.cardNames().count == 8)
    }

    @Test func aCardThatChangedSinceItWasCulledIsRefused() throws {
        let world = try standardWorld()
        let setup = try world.setup()
        try world.addPair("DSCF0006", FrameMark())  // shot, or copied on, after the card was opened

        #expect(throws: ApplyRun.StartError.cardChanged) { try ApplyRun(fs: FaultyFileSystem(), setup: setup) }
    }

    @Test func aSecondApplyToTheSameTripFolderIsRefusedWhileTheFirstIsAlive() throws {
        let world = try standardWorld()
        let first = try ApplyRun(fs: FaultyFileSystem(), setup: try world.setup())

        #expect(throws: ApplyRun.StartError.busy) { try ApplyRun(fs: FaultyFileSystem(), setup: try world.setup()) }
        withExtendedLifetime(first) {}
    }

    @Test func theWrongCardIsRefusedAtTheStart() throws {
        let world = try standardWorld()
        world.cardUUID = "DB8E88CF-NOT-THIS-CARD"

        #expect(throws: ApplyRun.StartError.stopped(.wrongCard)) {
            try ApplyRun(fs: FaultyFileSystem(), setup: try world.setup())
        }
    }

    @Test func anExistingFolderIsOnlyAddedToWithTheOwnersAgreement() async throws {
        let world = try standardWorld()
        try Data("an older trip".utf8).write(to: try world.archive.file("Japan 2026/IMG_0001.JPG"))
        let run = try ApplyRun(fs: FaultyFileSystem(), setup: try world.setup())
        #expect(try await run.preflight().plan.destinationState == .existsNotOurs)

        await #expect(throws: ApplyStop.destinationAppeared(world.destination)) { try await run.copy() }
        #expect(try world.archiveNames() == ["Japan 2026/IMG_0001.JPG"], "nothing was added without being asked")

        let report = try await run.copy(addToExistingFolder: true)
        #expect(report.outcome.copied.count == 7)
    }

    @Test func aNameTakenDuringTheRunIsResolvedInTheSameRun() async throws {
        // Someone's DSCF0001.JPG lands in the trip folder just as copying starts. The frame is copied again
        // whole as -2, the stranger's file is untouched, and the run still ends with every keeper archived.
        let world = try standardWorld()
        let foreign = Data("someone else's".utf8)
        let target = world.archive.url("Japan 2026/JPG/DSCF0001.JPG")
        let fs = FaultyFileSystem(
            .before(.create, call: 3) { FileManager.default.createFile(atPath: target.path, contents: foreign) })
        let run = try ApplyRun(fs: fs, setup: try world.setup())
        _ = try await run.preflight()

        let report = try await run.copy()
        let summary = await run.finish(confirmed: true)

        #expect(report.outcome.stopped == nil && report.outcome.skipped.isEmpty)
        #expect(report.check == ApplyExecutor.FinalCheck(keepersOnArchive: 3, problems: []))
        #expect(try Data(contentsOf: target) == foreign)
        #expect(try world.archiveNames().contains("Japan 2026/JPG/DSCF0001-2.JPG"))
        #expect(
            summary.duplicatesLeft == [world.location("DSCF0001.RAF")], "the first RAF stays, listed as a duplicate")
        #expect(summary.deletedFromCard == reject4)
    }

    @Test func cancellingTheTaskStopsTheCopyAndClosesTheGate() async throws {
        let world = try standardWorld()
        let run = try ApplyRun(fs: FaultyFileSystem(), setup: try world.setup())
        _ = try await run.preflight()

        let report = try await run.copy(onProgress: { _, _ in withUnsafeCurrentTask { $0?.cancel() } })
        let summary = await run.finish(confirmed: true)

        #expect(report.outcome.stopped == .cancelled)
        #expect(report.confirmation == nil)
        #expect(summary.deletedFromCard.isEmpty)
        #expect(try world.cardNames().count == 8)
    }

    @Test func leftoverPartialsAreRemovedOnlyWhenTheOwnerAgrees() async throws {
        let world = try standardWorld()
        let stray = try world.archive.file("Japan 2026/.OLD.JPG.fujicull-partial")
        try world.archive.file("Japan 2026/keep-me.JPG")
        let run = try ApplyRun(fs: FaultyFileSystem(), setup: try world.setup())

        let preflight = try await run.preflight()
        #expect(preflight.recovery.strayPartials.map(\.name) == [".OLD.JPG.fujicull-partial"])
        #expect(FileManager.default.fileExists(atPath: stray.path))

        try await run.removeStrayPartials()

        #expect(!FileManager.default.fileExists(atPath: stray.path))
        #expect(FileManager.default.fileExists(atPath: world.archive.url("Japan 2026/keep-me.JPG").path))
    }

    @Test func finishingWithoutHavingCopiedRemovesNothing() async throws {
        let world = try standardWorld()
        let run = try ApplyRun(fs: FaultyFileSystem(), setup: try world.setup())
        _ = try await run.preflight()

        let summary = await run.finish(confirmed: true)

        #expect(summary.deletedFromCard.isEmpty && summary.copiedFiles == 0)
        #expect(try world.cardNames().count == 8)
        await #expect(throws: Never.self) { _ = try await run.preflight() }
    }

    @Test func copyingBeforePreflightIsRefused() async throws {
        let world = try standardWorld()
        let run = try ApplyRun(fs: FaultyFileSystem(), setup: try world.setup())

        await #expect(throws: ApplyStop.gateClosed) { try await run.copy() }
        #expect(await run.finish(confirmed: true).deletedFromCard.isEmpty)
    }
}
