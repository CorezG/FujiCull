import Foundation
import Testing

@testable import FujiCullCore

private let archive = "7CA26A15"
private let japan = Ledger.Destination(volumeUUID: archive, folder: "Japan 2026")
private let shot = Date(timeIntervalSince1970: 1_726_808_891)
private let rafSize: Int64 = 87_349_760
private let jpgSize: Int64 = 12_096_415

private func raf(_ name: String, folder: String = "DCIM/124_FUJI", size: Int64 = rafSize) -> SourceFile {
    SourceFile(relativePath: "\(folder)/\(name).RAF", size: size, modified: shot)
}

private func jpg(_ name: String, folder: String = "DCIM/124_FUJI", size: Int64 = jpgSize) -> SourceFile {
    SourceFile(relativePath: "\(folder)/\(name).JPG", size: size, modified: shot)
}

private func pair(_ name: String, folder: String = "DCIM/124_FUJI") -> Frame {
    Frame(id: FrameID("\(folder)/\(name)"), jpg: jpg(name, folder: folder), raf: raf(name, folder: folder))
}

private func taken(_ second: Int) -> CaptureTime {
    CaptureTime(dateTime: String(format: "2026:09:20 05:08:%02d", second), subsecond: "42")
}

private func at(_ name: String, in subfolder: String? = nil, _ destination: Ledger.Destination = japan)
    -> ArchiveLocation
{
    ArchiveLocation(volumeUUID: destination.volumeUUID, folder: destination.folder, subfolder: subfolder, name: name)
}

/// The records a completed copy leaves: `reserve` then `verified`.
private func archived(
    _ file: SourceFile, as role: FileRole, of frame: Frame, captured: CaptureTime?, at location: ArchiveLocation
) -> [LedgerRecord] {
    let owner = Owner.frame(frame.id)
    let source = SourceIdentity(
        path: file.relativePath, size: file.size, modified: file.modified, captureTime: captured, sha256: "hash")
    return [
        .reserve(owner: owner, role: role, location: location, partial: SafeCopy.partialName(for: location.name)),
        .verified(owner: owner, role: role, location: location, source: source, size: file.size, sha256: "hash"),
    ]
}

/// The records of a whole pair archived under `name`, with its Google Photos copy.
private func archivedPair(
    _ frame: Frame, captured: CaptureTime?, as name: String, in destination: Ledger.Destination = japan
)
    -> [LedgerRecord]
{
    var records: [LedgerRecord] = []
    if let file = frame.raf {
        records += archived(file, as: .raw, of: frame, captured: captured, at: at("\(name).RAF", destination))
    }
    if let file = frame.jpg {
        records += archived(file, as: .jpg, of: frame, captured: captured, at: at("\(name).JPG", destination))
        records += archived(
            file, as: .googlePhotos, of: frame, captured: captured,
            at: at("\(name).JPG", in: "Google Photos", destination))
    }
    return records
}

private func input(
    _ frames: [Frame], marks: [FrameMark], captured: [CaptureTime?]? = nil, ledger: [LedgerRecord] = [],
    listings: [Ledger.Destination: ApplyInput.Listing] = [:], videos: [SourceFile] = [], otherFiles: [SourceFile] = [],
    destination: Ledger.Destination = japan, readOnly: Bool = false, cameraCard: Bool = true,
    freeBytes: Int64 = 500_000_000_000, copyAgain: Set<Owner> = []
) -> ApplyInput {
    let times = captured ?? frames.indices.map { taken($0) }
    return ApplyInput(
        frames: frames, videos: videos, otherFiles: otherFiles, skippedItems: 0,
        marks: Dictionary(uniqueKeysWithValues: zip(frames.map(\.id), marks)),
        captureTimes: Dictionary(
            uniqueKeysWithValues: zip(frames.map(\.id), times).compactMap { id, time in time.map { (id, $0) } }),
        ledger: Ledger(ledger),
        source: ApplyInput.Source(volumeUUID: "DB8E88CF", isCameraCard: cameraCard, isReadOnly: readOnly),
        destination: destination, listings: listings, freeBytes: freeBytes, allocationSize: 131_072,
        copyAgain: copyAgain)
}

private let keep = FrameMark(decision: .keep)
private let favourite = FrameMark(decision: .keep, isFavourite: true)
private let reject = FrameMark(decision: .reject)
private let undecided = FrameMark()

private func names(_ copies: [ApplyPlan.Copy]) -> [String] {
    copies.map { ($0.to.subfolder.map { "\($0)/" } ?? "") + $0.to.name }
}

// The planner (DESIGN §5.7; R22, R24–R27, D6, D7; SR2, SR8–SR14, SR26). Pure: no files are touched.
@Suite struct ApplyPlannerTests {
    let a = pair("DSCF0001")
    let b = pair("DSCF0002")
    let c = pair("DSCF0003")

    // MARK: First run

    @Test func aFirstRunCopiesKeepersDeletesRejectsAndLeavesTheUndecidedAlone() throws {
        let movie = SourceFile(relativePath: "DCIM/124_FUJI/DSCF0009.MOV", size: 200_000_000, modified: shot)
        let memo = SourceFile(relativePath: "DCIM/124_FUJI/DSCF0001.WAV", size: 1_000, modified: shot)

        let plan = try ApplyPlanner.plan(
            input([a, b, c], marks: [favourite, reject, undecided], videos: [movie], otherFiles: [memo]))

        #expect(
            names(plan.copies) == ["DSCF0001.RAF", "DSCF0001.JPG", "Google Photos/DSCF0001.JPG", "Videos/DSCF0009.MOV"])
        #expect(plan.copies.map(\.role) == [.raw, .jpg, .googlePhotos, .video])
        #expect(plan.copies.map(\.favourite) == [true, true, false, false], "the Google Photos copy is never tagged")
        #expect(plan.copies[0].source == .card(try #require(a.raf)))
        #expect(plan.copies[2].source == .archive(at("DSCF0001.JPG")), "made from the archive JPG, not the card")
        #expect(plan.copies.map(\.owner) == [.frame(a.id), .frame(a.id), .frame(a.id), .video(movie.relativePath)])
        #expect(
            plan.cardDeletes == [
                ApplyPlan.CardDelete(frame: b.id, paths: [b.raf, b.jpg].compactMap { $0?.relativePath })
            ])
        #expect(plan.deleteMode == .permanent)
        #expect(
            plan.leftOnCard == ApplyPlan.LeftOnCard(undecided: [c.id], otherFiles: [memo.relativePath], skippedItems: 0)
        )
        #expect(plan.removals.isEmpty && plan.tagChanges.isEmpty && plan.superseded.isEmpty && plan.notDeleted.isEmpty)
        #expect(plan.destinationState == .new)
    }

    @Test func anUndecidedFrameIsNeverMentionedInAnyOperation() throws {
        // Even when an earlier run archived and tagged it.
        let ledger = archivedPair(c, captured: taken(0), as: "DSCF0003") + [.tagged(location: at("DSCF0003.JPG"))]
        let listing = ApplyInput.Listing(trip: ["DSCF0003.RAF", "DSCF0003.JPG"], googlePhotos: ["DSCF0003.JPG"])

        let plan = try ApplyPlanner.plan(input([c], marks: [undecided], ledger: ledger, listings: [japan: listing]))

        #expect(plan.copies.isEmpty && plan.tagChanges.isEmpty && plan.removals.isEmpty && plan.cardDeletes.isEmpty)
        #expect(plan.leftOnCard.undecided == [c.id])
    }

    @Test func orphansAreCopiedWithTheFilesTheyHave() throws {
        let rafOnly = Frame(id: FrameID("DCIM/124_FUJI/DSCF0004"), jpg: nil, raf: raf("DSCF0004"))
        let jpgOnly = Frame(id: FrameID("DCIM/124_FUJI/DSCF0005"), jpg: jpg("DSCF0005"), raf: nil)

        let plan = try ApplyPlanner.plan(input([rafOnly, jpgOnly], marks: [keep, keep]))

        #expect(names(plan.copies) == ["DSCF0004.RAF", "DSCF0005.JPG", "Google Photos/DSCF0005.JPG"])
    }

    // MARK: Later runs (R25)

    @Test func aSecondRunCopiesNothingThatIsAlreadyVerified() throws {
        let ledger = archivedPair(a, captured: taken(0), as: "DSCF0001")
        let listing = ApplyInput.Listing(trip: ["DSCF0001.RAF", "DSCF0001.JPG"], googlePhotos: ["DSCF0001.JPG"])

        let plan = try ApplyPlanner.plan(
            input([a, c], marks: [keep, undecided], ledger: ledger, listings: [japan: listing]))

        #expect(plan.copies.isEmpty)
        #expect(plan.destinationState == .ours)
    }

    @Test func decidingAnUndecidedFrameLaterCopiesOnlyThatFrame() throws {
        let ledger = archivedPair(a, captured: taken(0), as: "DSCF0001")
        let listing = ApplyInput.Listing(trip: ["DSCF0001.RAF", "DSCF0001.JPG"], googlePhotos: ["DSCF0001.JPG"])

        let plan = try ApplyPlanner.plan(
            input([a, c], marks: [keep, keep], ledger: ledger, listings: [japan: listing]))

        #expect(names(plan.copies) == ["DSCF0003.RAF", "DSCF0003.JPG", "Google Photos/DSCF0003.JPG"])
    }

    @Test func aRunInterruptedBeforeTheGooglePhotosCopiesMakesThemNextTime() throws {
        // Review 3, finding 5: the archive files were verified in an earlier run; only the staging copy is missing.
        let ledger =
            archived(try #require(a.raf), as: .raw, of: a, captured: taken(0), at: at("DSCF0001.RAF"))
            + archived(try #require(a.jpg), as: .jpg, of: a, captured: taken(0), at: at("DSCF0001.JPG"))
        let listing = ApplyInput.Listing(trip: ["DSCF0001.RAF", "DSCF0001.JPG"])

        let plan = try ApplyPlanner.plan(input([a], marks: [keep], ledger: ledger, listings: [japan: listing]))

        #expect(names(plan.copies) == ["Google Photos/DSCF0001.JPG"])
        #expect(plan.copies.first?.source == .archive(at("DSCF0001.JPG")))
    }

    @Test func aGooglePhotosCopyThatWasEmptiedOutIsNotMadeAgain() throws {
        // The staging folder is disposable: once verified, its copy is never recreated or required.
        let ledger = archivedPair(a, captured: taken(0), as: "DSCF0001")
        let listing = ApplyInput.Listing(trip: ["DSCF0001.RAF", "DSCF0001.JPG"], googlePhotos: [])

        let plan = try ApplyPlanner.plan(input([a], marks: [keep], ledger: ledger, listings: [japan: listing]))

        #expect(plan.copies.isEmpty)
    }

    // MARK: Rejecting or un-keeping an archived frame (D6, R26)

    @Test func rejectingAnArchivedFrameRemovesItsArchiveFilesAndDeletesItFromTheCard() throws {
        let ledger = archivedPair(a, captured: taken(0), as: "DSCF0001")
        let listing = ApplyInput.Listing(trip: ["DSCF0001.RAF", "DSCF0001.JPG"], googlePhotos: ["DSCF0001.JPG"])

        let plan = try ApplyPlanner.plan(input([a], marks: [reject], ledger: ledger, listings: [japan: listing]))

        #expect(
            plan.removals == [
                ApplyPlan.Removal(
                    frame: a.id,
                    files: [at("DSCF0001.RAF"), at("DSCF0001.JPG"), at("DSCF0001.JPG", in: "Google Photos")])
            ])
        #expect(plan.cardDeletes.map(\.frame) == [a.id])
        #expect(plan.copies.isEmpty)
    }

    @Test func aGooglePhotosCopyThatHasGoneDoesNotHoldUpTheRemoval() throws {
        let ledger = archivedPair(a, captured: taken(0), as: "DSCF0001")
        let listing = ApplyInput.Listing(trip: ["DSCF0001.RAF", "DSCF0001.JPG"], googlePhotos: [])

        let plan = try ApplyPlanner.plan(input([a], marks: [reject], ledger: ledger, listings: [japan: listing]))

        #expect(plan.removals == [ApplyPlan.Removal(frame: a.id, files: [at("DSCF0001.RAF"), at("DSCF0001.JPG")])])
    }

    @Test func archiveFilesAlreadyTrashedAreNotPlannedAgain() throws {
        var ledger = archivedPair(a, captured: taken(0), as: "DSCF0001")
        for location in [at("DSCF0001.RAF"), at("DSCF0001.JPG"), at("DSCF0001.JPG", in: "Google Photos")] {
            ledger += [.trashing(location: location), .trashed(location: location, trashPath: nil)]
        }

        let plan = try ApplyPlanner.plan(
            input([a], marks: [reject], ledger: ledger, listings: [japan: ApplyInput.Listing()]))

        #expect(plan.removals.isEmpty)
        #expect(plan.cardDeletes.map(\.frame) == [a.id], "the card files are still to delete")
    }

    @Test func aTrashMoveThatWasInterruptedIsPlannedAgain() throws {
        let ledger = archivedPair(a, captured: taken(0), as: "DSCF0001") + [.trashing(location: at("DSCF0001.RAF"))]
        let listing = ApplyInput.Listing(trip: ["DSCF0001.RAF", "DSCF0001.JPG"], googlePhotos: ["DSCF0001.JPG"])

        let plan = try ApplyPlanner.plan(input([a], marks: [reject], ledger: ledger, listings: [japan: listing]))

        #expect(plan.removals.first?.files.contains(at("DSCF0001.RAF")) == true)
    }

    @Test func onlyFilesThisCardsJournalRecordsAreEverRemoved() throws {
        // The same names are on the archive, but nothing in the journal says FujiCull wrote them.
        let listing = ApplyInput.Listing(trip: ["DSCF0001.RAF", "DSCF0001.JPG"], googlePhotos: ["DSCF0001.JPG"])

        let plan = try ApplyPlanner.plan(input([a], marks: [reject], listings: [japan: listing]))

        #expect(plan.removals.isEmpty)
    }

    @Test func aKeeperSetBackToUndecidedAfterArchivingChangesNothing() throws {
        let ledger = archivedPair(a, captured: taken(0), as: "DSCF0001")
        let listing = ApplyInput.Listing(trip: ["DSCF0001.RAF", "DSCF0001.JPG"], googlePhotos: ["DSCF0001.JPG"])

        let plan = try ApplyPlanner.plan(input([a], marks: [undecided], ledger: ledger, listings: [japan: listing]))

        #expect(plan.copies.isEmpty && plan.removals.isEmpty && plan.cardDeletes.isEmpty && plan.tagChanges.isEmpty)
    }

    @Test func aFrameRejectedTrashedThenKeptAgainIsCopiedAfresh() throws {
        var ledger = archivedPair(a, captured: taken(0), as: "DSCF0001")
        for location in [at("DSCF0001.RAF"), at("DSCF0001.JPG"), at("DSCF0001.JPG", in: "Google Photos")] {
            ledger += [.trashing(location: location), .trashed(location: location, trashPath: nil)]
        }

        let plan = try ApplyPlanner.plan(
            input([a], marks: [keep], ledger: ledger, listings: [japan: ApplyInput.Listing()]))

        #expect(names(plan.copies) == ["DSCF0001.RAF", "DSCF0001.JPG", "Google Photos/DSCF0001.JPG"])
    }

    // MARK: Favourites (R8, SR12)

    @Test func favouritingAnArchivedFrameTagsItsArchivePairOnly() throws {
        let ledger = archivedPair(a, captured: taken(0), as: "DSCF0001")
        let listing = ApplyInput.Listing(trip: ["DSCF0001.RAF", "DSCF0001.JPG"], googlePhotos: ["DSCF0001.JPG"])

        let plan = try ApplyPlanner.plan(input([a], marks: [favourite], ledger: ledger, listings: [japan: listing]))

        #expect(
            plan.tagChanges == [
                ApplyPlan.TagChange(location: at("DSCF0001.RAF"), favourite: true),
                ApplyPlan.TagChange(location: at("DSCF0001.JPG"), favourite: true),
            ])
    }

    @Test func unfavouritingRemovesOnlyTagsFujiCullSet() throws {
        let ledger = archivedPair(a, captured: taken(0), as: "DSCF0001") + [.tagged(location: at("DSCF0001.RAF"))]
        // Both files carry the tag now; the JPG's was added by the owner in Finder.
        let listing = ApplyInput.Listing(
            trip: ["DSCF0001.RAF", "DSCF0001.JPG"], googlePhotos: ["DSCF0001.JPG"],
            favourites: ["DSCF0001.RAF", "DSCF0001.JPG"])

        let plan = try ApplyPlanner.plan(input([a], marks: [keep], ledger: ledger, listings: [japan: listing]))

        #expect(plan.tagChanges == [ApplyPlan.TagChange(location: at("DSCF0001.RAF"), favourite: false)])
    }

    @Test func aTagThatIsAlreadyRightIsNotPlanned() throws {
        let ledger =
            archivedPair(a, captured: taken(0), as: "DSCF0001")
            + [.tagged(location: at("DSCF0001.RAF")), .tagged(location: at("DSCF0001.JPG"))]
        let listing = ApplyInput.Listing(
            trip: ["DSCF0001.RAF", "DSCF0001.JPG"], favourites: ["DSCF0001.RAF", "DSCF0001.JPG"])

        let plan = try ApplyPlanner.plan(input([a], marks: [favourite], ledger: ledger, listings: [japan: listing]))

        #expect(plan.tagChanges.isEmpty)
    }

    @Test func aTagLostToAnUnplugIsAppliedAgain() throws {
        // The journal says tagged, but the file has no tag: plan from what is actually there.
        let ledger =
            archivedPair(a, captured: taken(0), as: "DSCF0001")
            + [.tagged(location: at("DSCF0001.RAF")), .tagged(location: at("DSCF0001.JPG"))]
        let listing = ApplyInput.Listing(trip: ["DSCF0001.RAF", "DSCF0001.JPG"], favourites: ["DSCF0001.RAF"])

        let plan = try ApplyPlanner.plan(input([a], marks: [favourite], ledger: ledger, listings: [japan: listing]))

        #expect(plan.tagChanges == [ApplyPlan.TagChange(location: at("DSCF0001.JPG"), favourite: true)])
    }

    // MARK: Names and collisions (SR10, SR11)

    @Test func aNameAlreadyOnTheArchiveGivesTheWholeFrameASuffix() throws {
        let listing = ApplyInput.Listing(trip: ["DSCF0001.JPG"])

        let plan = try ApplyPlanner.plan(input([a], marks: [keep], listings: [japan: listing]))

        #expect(names(plan.copies) == ["DSCF0001-2.RAF", "DSCF0001-2.JPG", "Google Photos/DSCF0001-2.JPG"])
        #expect(plan.destinationState == .existsNotOurs)
    }

    @Test func aCollisionOnlyInGooglePhotosStillMovesTheWholeFrame() throws {
        let listing = ApplyInput.Listing(googlePhotos: ["DSCF0001.JPG"])

        let plan = try ApplyPlanner.plan(input([a], marks: [keep], listings: [japan: listing]))

        #expect(names(plan.copies) == ["DSCF0001-2.RAF", "DSCF0001-2.JPG", "Google Photos/DSCF0001-2.JPG"])
    }

    @Test func namesAreComparedIgnoringCaseAndTheNextFreeSuffixIsUsed() throws {
        let listing = ApplyInput.Listing(trip: ["dscf0001.raf", "DSCF0001-2.JPG"])

        let plan = try ApplyPlanner.plan(input([a], marks: [keep], listings: [japan: listing]))

        #expect(names(plan.copies) == ["DSCF0001-3.RAF", "DSCF0001-3.JPG", "Google Photos/DSCF0001-3.JPG"])
    }

    @Test func twoFramesWithTheSameFileNameInOnePlanGetDifferentNames() throws {
        // The camera's counter wrapped, or two folders hold the same number.
        let other = pair("DSCF0001", folder: "DCIM/125_FUJI")

        let plan = try ApplyPlanner.plan(input([a, other], marks: [keep, keep]))

        #expect(
            names(plan.copies) == [
                "DSCF0001.RAF", "DSCF0001.JPG", "Google Photos/DSCF0001.JPG",
                "DSCF0001-2.RAF", "DSCF0001-2.JPG", "Google Photos/DSCF0001-2.JPG",
            ])
    }

    @Test func aNameHeldBySupersededOrReservedFilesInTheJournalIsNotReused() throws {
        // Not in the listing handed over, but the journal knows another frame's file is, or will be, there.
        let ledger = archivedPair(b, captured: taken(1), as: "DSCF0001")

        let plan = try ApplyPlanner.plan(
            input([a], marks: [keep], ledger: ledger, listings: [japan: ApplyInput.Listing()]))

        #expect(names(plan.copies).first == "DSCF0001-2.RAF")
    }

    @Test func aForeignFileAtANeededNameRehomesTheWholeFrame() throws {
        // The RAF is verified as DSCF0001; the JPG still needs copying, and someone else's DSCF0001.JPG is there.
        let ledger = archived(try #require(a.raf), as: .raw, of: a, captured: taken(0), at: at("DSCF0001.RAF"))
        let listing = ApplyInput.Listing(trip: ["DSCF0001.RAF", "DSCF0001.JPG"])

        let plan = try ApplyPlanner.plan(input([a], marks: [keep], ledger: ledger, listings: [japan: listing]))

        #expect(plan.superseded == [at("DSCF0001.RAF")], "left where it is, and never removed")
        #expect(names(plan.copies) == ["DSCF0001-2.RAF", "DSCF0001-2.JPG", "Google Photos/DSCF0001-2.JPG"])
    }

    @Test func aForeignFileWhereTheStagingCopyBelongsAlsoRehomesTheFrame() throws {
        // Both archive files are verified, the staging copy was never made, and its name is taken.
        let ledger =
            archived(try #require(a.raf), as: .raw, of: a, captured: taken(0), at: at("DSCF0001.RAF"))
            + archived(try #require(a.jpg), as: .jpg, of: a, captured: taken(0), at: at("DSCF0001.JPG"))
        let listing = ApplyInput.Listing(trip: ["DSCF0001.RAF", "DSCF0001.JPG"], googlePhotos: ["DSCF0001.JPG"])

        let plan = try ApplyPlanner.plan(input([a], marks: [keep], ledger: ledger, listings: [japan: listing]))

        #expect(plan.superseded == [at("DSCF0001.RAF"), at("DSCF0001.JPG")])
        #expect(names(plan.copies) == ["DSCF0001-2.RAF", "DSCF0001-2.JPG", "Google Photos/DSCF0001-2.JPG"])
    }

    @Test func copyAgainRehomesAFrameWhoseArchiveFileChanged() throws {
        let ledger = archivedPair(a, captured: taken(0), as: "DSCF0001")
        let listing = ApplyInput.Listing(trip: ["DSCF0001.RAF", "DSCF0001.JPG"], googlePhotos: ["DSCF0001.JPG"])

        let plan = try ApplyPlanner.plan(
            input([a], marks: [keep], ledger: ledger, listings: [japan: listing], copyAgain: [.frame(a.id)]))

        #expect(plan.superseded == [at("DSCF0001.RAF"), at("DSCF0001.JPG"), at("DSCF0001.JPG", in: "Google Photos")])
        #expect(names(plan.copies) == ["DSCF0001-2.RAF", "DSCF0001-2.JPG", "Google Photos/DSCF0001-2.JPG"])
    }

    @Test func entriesThatDifferOnlyByCaseStopThePlan() {
        let listing = ApplyInput.Listing(trip: ["DSCF0001.JPG", "dscf0001.jpg"])

        #expect(throws: ApplyError.ambiguousNames(["DSCF0001.JPG", "dscf0001.jpg"])) {
            try ApplyPlanner.plan(input([a], marks: [keep], listings: [japan: listing]))
        }
    }

    // MARK: Frame identity (SR2; review 3, finding 1)

    @Test func aDifferentPhotoAtTheSamePathAndSizeIsCopiedNotSkipped() throws {
        // After a format the card holds a new DSCF0001 with identical sizes; only the capture time differs.
        let ledger = archivedPair(a, captured: taken(0), as: "DSCF0001")
        let listing = ApplyInput.Listing(trip: ["DSCF0001.RAF", "DSCF0001.JPG"], googlePhotos: ["DSCF0001.JPG"])

        let plan = try ApplyPlanner.plan(
            input([a], marks: [keep], captured: [taken(30)], ledger: ledger, listings: [japan: listing]))

        #expect(names(plan.copies) == ["DSCF0001-2.RAF", "DSCF0001-2.JPG", "Google Photos/DSCF0001-2.JPG"])
        #expect(
            plan.superseded.isEmpty, "the old trip's files belong to another photo; they are simply not this frame's")
    }

    @Test func rejectingADifferentPhotoNeverRemovesTheOldPhotosArchiveFiles() throws {
        let ledger = archivedPair(a, captured: taken(0), as: "DSCF0001")
        let listing = ApplyInput.Listing(trip: ["DSCF0001.RAF", "DSCF0001.JPG"], googlePhotos: ["DSCF0001.JPG"])

        let plan = try ApplyPlanner.plan(
            input([a], marks: [reject], captured: [taken(30)], ledger: ledger, listings: [japan: listing]))

        #expect(plan.removals.isEmpty)
        #expect(plan.cardDeletes.map(\.frame) == [a.id])
    }

    @Test func aRejectWithNoCaptureDateIsNeverDeleted() throws {
        let plan = try ApplyPlanner.plan(input([a, b], marks: [reject, reject], captured: [nil, taken(1)]))

        #expect(plan.cardDeletes.map(\.frame) == [b.id])
        #expect(plan.notDeleted == [ApplyPlan.NotDeleted(frame: a.id, reason: .noCaptureDate)])
    }

    @Test func aKeeperWithNoCaptureDateIsNotCopiedAgainEveryRun() throws {
        // With no capture time on either side, the file's own date stands in, so it isn't duplicated each run.
        let ledger = archivedPair(a, captured: nil, as: "DSCF0001")
        let listing = ApplyInput.Listing(trip: ["DSCF0001.RAF", "DSCF0001.JPG"], googlePhotos: ["DSCF0001.JPG"])

        let plan = try ApplyPlanner.plan(
            input([a], marks: [keep], captured: [nil], ledger: ledger, listings: [japan: listing]))

        #expect(plan.copies.isEmpty)
    }

    @Test func aRecordWithACaptureTimeDoesNotBindToAPhotoWithout() throws {
        let ledger = archivedPair(a, captured: taken(0), as: "DSCF0001")
        let listing = ApplyInput.Listing(trip: ["DSCF0001.RAF", "DSCF0001.JPG"], googlePhotos: ["DSCF0001.JPG"])

        let plan = try ApplyPlanner.plan(
            input([a], marks: [keep], captured: [nil], ledger: ledger, listings: [japan: listing]))

        #expect(plan.copies.count == 3)
    }

    @Test func aFileThatReappearsWhereOneWasDeletedIsANewFrame() throws {
        // Its path has a `deleted` record: nothing recorded before that binds to it (closed frame).
        let ledger =
            archivedPair(a, captured: taken(0), as: "DSCF0001")
            + [.deleting(path: "DCIM/124_FUJI/DSCF0001.RAF"), .deleted(path: "DCIM/124_FUJI/DSCF0001.RAF")]
        let listing = ApplyInput.Listing(trip: ["DSCF0001.RAF", "DSCF0001.JPG"], googlePhotos: ["DSCF0001.JPG"])

        let plan = try ApplyPlanner.plan(input([a], marks: [keep], ledger: ledger, listings: [japan: listing]))

        #expect(names(plan.copies) == ["DSCF0001-2.RAF", "DSCF0001-2.JPG", "Google Photos/DSCF0001-2.JPG"])
    }

    // MARK: The card (R6, SR8)

    @Test func aLockedCardStillGetsCopiesAndArchiveRemovalsButNoDeletes() throws {
        let ledger = archivedPair(b, captured: taken(1), as: "DSCF0002")
        let listing = ApplyInput.Listing(trip: ["DSCF0002.RAF", "DSCF0002.JPG"], googlePhotos: ["DSCF0002.JPG"])

        let plan = try ApplyPlanner.plan(
            input([a, b], marks: [keep, reject], ledger: ledger, listings: [japan: listing], readOnly: true))

        #expect(plan.copies.count == 3)
        #expect(plan.removals.map(\.frame) == [b.id])
        #expect(plan.cardDeletes.isEmpty)
        #expect(plan.notDeleted == [ApplyPlan.NotDeleted(frame: b.id, reason: .cardLocked)])
    }

    @Test func aSourceThatIsNotACameraCardHasItsRejectsTrashedNotDeleted() throws {
        let plan = try ApplyPlanner.plan(input([a], marks: [reject], cameraCard: false))

        #expect(plan.deleteMode == .trash)
        #expect(plan.cardDeletes.map(\.frame) == [a.id])
    }

    @Test func archivingAVolumeOntoItselfIsRefused() {
        var same = input([a], marks: [keep])
        same.source.volumeUUID = archive

        #expect(throws: ApplyError.sameVolume) { try ApplyPlanner.plan(same) }
    }

    // MARK: Videos (R27)

    @Test func aVideoAlreadyArchivedIsNotCopiedAgainAndAChangedOneIs() throws {
        let movie = SourceFile(relativePath: "DCIM/124_FUJI/DSCF0009.MOV", size: 200_000_000, modified: shot)
        let owner = Owner.video(movie.relativePath)
        let location = at("DSCF0009.MOV", in: "Videos")
        let ledger: [LedgerRecord] = [
            .reserve(owner: owner, role: .video, location: location, partial: ".DSCF0009.MOV.fujicull-partial"),
            .verified(
                owner: owner, role: .video, location: location,
                source: SourceIdentity(
                    path: movie.relativePath, size: movie.size, modified: shot, captureTime: nil, sha256: "h"),
                size: movie.size, sha256: "h"),
        ]
        let listing = ApplyInput.Listing(videos: ["DSCF0009.MOV"])

        let same = try ApplyPlanner.plan(
            input([], marks: [], ledger: ledger, listings: [japan: listing], videos: [movie]))
        let changed = SourceFile(
            relativePath: movie.relativePath, size: movie.size, modified: shot.addingTimeInterval(60))
        let again = try ApplyPlanner.plan(
            input([], marks: [], ledger: ledger, listings: [japan: listing], videos: [changed]))

        #expect(same.copies.isEmpty)
        #expect(names(again.copies) == ["Videos/DSCF0009-2.MOV"])
    }

    // MARK: Destinations (D7; review 3, finding 9)

    @Test func keepersFiledUnderAnEarlierFolderAreFoundThere() throws {
        let part2 = Ledger.Destination(volumeUUID: archive, folder: "Japan 2026 part 2")
        let ledger = archivedPair(a, captured: taken(0), as: "DSCF0001", in: japan)
        let old = ApplyInput.Listing(trip: ["DSCF0001.RAF", "DSCF0001.JPG"], googlePhotos: ["DSCF0001.JPG"])

        let plan = try ApplyPlanner.plan(
            input([a, b], marks: [favourite, keep], ledger: ledger, listings: [japan: old], destination: part2))

        #expect(plan.copies.allSatisfy { $0.owner == .frame(b.id) && $0.to.folder == "Japan 2026 part 2" })
        #expect(
            plan.tagChanges.map(\.location.folder) == ["Japan 2026", "Japan 2026"], "tagged where they actually are")
        #expect(plan.unreachableDestinations.isEmpty)
        #expect(plan.destinationState == .new)
    }

    @Test func aFolderThisJournalChoseBeforeIsOursEvenIfNothingWasCopiedYet() throws {
        // The last run created the folder and stopped before its first file.
        let ledger: [LedgerRecord] = [.destination(volumeUUID: archive, folder: "Japan 2026")]

        let plan = try ApplyPlanner.plan(
            input([a], marks: [keep], ledger: ledger, listings: [japan: ApplyInput.Listing()]))

        #expect(plan.destinationState == .ours)
    }

    @Test func aRecordedFolderThatCannotBeListedIsReportedAndItsFilesLeftAlone() throws {
        let part2 = Ledger.Destination(volumeUUID: archive, folder: "Japan 2026 part 2")
        let ledger =
            archivedPair(a, captured: taken(0), as: "DSCF0001", in: japan)
            + archivedPair(b, captured: taken(1), as: "DSCF0002", in: japan)

        let plan = try ApplyPlanner.plan(
            input([a, b], marks: [favourite, reject], ledger: ledger, destination: part2))

        #expect(plan.unreachableDestinations == [japan])
        #expect(plan.tagChanges.isEmpty && plan.removals.isEmpty, "nothing is done to files that can't be seen")
        #expect(plan.copies.isEmpty, "and they aren't copied again behind the owner's back")
    }

    // MARK: Space (SR14)

    @Test func spaceCountsWholeAllocationUnitsACompanionFileEachAndAMargin() throws {
        let plan = try ApplyPlanner.plan(input([a], marks: [keep]))

        let unit: Int64 = 131_072
        let rafUnits = (rafSize + unit - 1) / unit
        let jpgUnits = (jpgSize + unit - 1) / unit
        // RAF, JPG and the Google Photos JPG, each with one unit for its `._` companion, plus 1 GB.
        #expect(plan.requiredBytes == (rafUnits + 1 + 2 * (jpgUnits + 1)) * unit + 1_000_000_000)
    }

    @Test func tooLittleSpaceStopsThePlanWithTheNumbers() throws {
        let needed = try ApplyPlanner.plan(input([a], marks: [keep])).requiredBytes

        #expect(throws: ApplyError.insufficientSpace(needed: needed, available: needed - 1)) {
            try ApplyPlanner.plan(input([a], marks: [keep], freeBytes: needed - 1))
        }
        #expect(throws: Never.self) { try ApplyPlanner.plan(input([a], marks: [keep], freeBytes: needed)) }
    }

    @Test func aRunWithNothingToCopyNeedsNoSpace() throws {
        let plan = try ApplyPlanner.plan(input([a], marks: [reject], freeBytes: 0))

        #expect(plan.requiredBytes == 0)
    }

    // MARK: Trip folder names

    @Test(
        arguments: [
            ("Japan 2026", nil), ("Côte d'Azur (été)", nil), ("2026-10 Kyōto & Ōsaka", nil),
            ("", TripName.Problem.empty), ("Japan/2026", .forbiddenCharacter), ("What?", .forbiddenCharacter),
            ("a\u{7}b", .forbiddenCharacter), ("Tab\there", .forbiddenCharacter),
            (" Japan", .startsOrEndsWithSpaceOrDot),
            ("Japan.", .startsOrEndsWithSpaceOrDot), (".Trashes", .startsOrEndsWithSpaceOrDot),
            ("..", .startsOrEndsWithSpaceOrDot),
            ("CON", .reserved), ("nul", .reserved), ("COM7", .reserved), ("LPT1.txt", .reserved),
            ("System Volume Information", .reserved), (String(repeating: "a", count: 201), .tooLong),
            (String(repeating: "a", count: 200), nil),
        ] as [(String, TripName.Problem?)])
    func tripNamesAreCheckedForExFATAndWindows(name: String, problem: TripName.Problem?) {
        #expect(TripName.problem(with: name) == problem)
    }

    @Test func anInvalidTripNameStopsThePlan() {
        let bad = Ledger.Destination(volumeUUID: archive, folder: "Japan: 2026")

        #expect(throws: ApplyError.invalidTripName(.forbiddenCharacter)) {
            try ApplyPlanner.plan(input([a], marks: [keep], destination: bad))
        }
    }
}
