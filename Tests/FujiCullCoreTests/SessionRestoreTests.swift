import Foundation
import Testing

@testable import FujiCullCore

private func frame(_ name: String, jpg: Int64? = 12, raf: Int64? = 87) -> Frame {
    let folder = "DCIM/124_FUJI"
    return Frame(
        id: FrameID("\(folder)/\(name)"),
        jpg: jpg.map { SourceFile(relativePath: "\(folder)/\(name).JPG", size: $0, modified: .distantPast) },
        raf: raf.map { SourceFile(relativePath: "\(folder)/\(name).RAF", size: $0, modified: .distantPast) })
}

// Saving a session and matching it back to a card by frame identity (DESIGN §5.3; SR2, SR4).
@Suite struct SessionRestoreTests {

    @Test func aSessionRoundTripsThroughJSON() throws {
        let frames = [frame("DSCF0001"), frame("DSCF0002"), frame("DSCF0003", raf: nil)]
        var session = CullSession(frameIDs: frames.map(\.id))
        session.apply(.toggleFavourite)
        session.apply(.next)
        session.apply(.reject)
        session.apply(.toggleUndecidedFilter)

        let file = SessionFile(key: "vol-ABC", rootHint: "/Volumes/Fuji SD", session: session, frames: frames)
        let decoded = try JSONDecoder().decode(SessionFile.self, from: JSONEncoder().encode(file))

        #expect(decoded == file)
        #expect(decoded.schemaVersion == SessionFile.currentSchemaVersion)
        #expect(decoded.frames.count == 2, "only frames that aren't Undecided are stored")
        #expect(decoded.undecidedOnly)
    }

    @Test func anEmptySessionSavesNoCursorAndNoFrames() {
        let file = SessionFile(key: "k", rootHint: "", session: CullSession(frameIDs: []), frames: [])

        #expect(file.cursorFrameID == nil)
        #expect(file.frames.isEmpty)
    }

    @Test func aDecisionForAFrameThatWasNotScannedIsNotSaved() {
        // The session knows DSCF0002, but the scan handed over only DSCF0001; there's no identity to save it with.
        let scanned = [frame("DSCF0001")]
        var session = CullSession(frameIDs: [scanned[0].id, FrameID("DCIM/124_FUJI/DSCF0002")])
        session.apply(.keep)
        session.apply(.keep)

        let file = SessionFile(key: "k", rootHint: "", session: session, frames: scanned)

        #expect(file.frames.map(\.id) == [scanned[0].id])
    }

    @Test func duplicateFrameIDsNeverCrashAndTheFirstFrameWins() {
        // The scanner never produces duplicates (split orphans keep exact filenames), but bad input mustn't trap.
        let first = frame("DSCF0001", jpg: 10)
        let duplicate = frame("DSCF0001", jpg: 20)
        var session = CullSession(frameIDs: [first.id])
        session.apply(.keep)

        let file = SessionFile(key: "k", rootHint: "", session: session, frames: [first, duplicate])
        let outcome = SessionRestore.match(file, to: [first, duplicate])

        #expect(file.frames.first?.jpgSize == 10)
        #expect(outcome.isFull)
    }

    @Test func aFullMatchRestoresDecisionsCursorAndFilter() {
        let frames = [frame("DSCF0001"), frame("DSCF0002"), frame("DSCF0003")]
        var session = CullSession(frameIDs: frames.map(\.id))
        session.apply(.keep)
        session.apply(.toggleFavourite)
        let file = SessionFile(key: "k", rootHint: "", session: session, frames: frames)

        guard case .full(let restored) = SessionRestore.match(file, to: frames) else {
            Issue.record("expected a full match")
            return
        }
        #expect(restored.mark(at: 0).decision == .keep)
        #expect(restored.mark(at: 1) == FrameMark(decision: .keep, isFavourite: true))
        #expect(restored.cursor == 1)
    }

    // MARK: Capture time (SR2, review 3 finding 1)

    @Test func eachSavedDecisionCarriesItsCaptureTime() {
        let frames = [frame("DSCF0001"), frame("DSCF0002")]
        var session = CullSession(frameIDs: frames.map(\.id))
        session.apply(.keep)
        session.apply(.reject)
        let taken = CaptureTime(dateTime: "2026:09:20 05:08:11", subsecond: "42")

        let file = SessionFile(
            key: "k", rootHint: "", session: session, frames: frames, captureTimes: [frames[0].id: taken])

        #expect(file.frames[0].captureTime == taken)
        #expect(file.frames[1].captureTime == nil, "not read yet")
    }

    @Test func aDecisionBindsOnlyToAFrameTakenAtTheSameMoment() {
        // Same path and same sizes after a format: only the capture time tells the photos apart.
        let taken = CaptureTime(dateTime: "2026:09:20 05:08:11", subsecond: "42")
        let stored = StoredFrame(
            id: FrameID("DCIM/100_FUJI/DSCF0007"), jpgSize: nil, rafSize: 87_349_760, captureTime: taken,
            mark: FrameMark(decision: .reject))

        #expect(SessionRestore.binds(stored, to: taken, savedBySchema: 2))
        #expect(
            !SessionRestore.binds(
                stored, to: CaptureTime(dateTime: "2026:10:10 17:55:01", subsecond: "42"), savedBySchema: 2))
        #expect(
            !SessionRestore.binds(
                stored, to: CaptureTime(dateTime: "2026:09:20 05:08:11", subsecond: "43"), savedBySchema: 2))
        #expect(!SessionRestore.binds(stored, to: nil, savedBySchema: 2), "a photo with no capture time never binds")
    }

    @Test func aDecisionSavedWithoutACaptureTimeDoesNotBind() {
        let stored = StoredFrame(
            id: FrameID("DCIM/100_FUJI/DSCF0007"), jpgSize: 12, rafSize: 87, captureTime: nil,
            mark: FrameMark(decision: .keep))

        #expect(
            !SessionRestore.binds(
                stored, to: CaptureTime(dateTime: "2026:09:20 05:08:11", subsecond: nil), savedBySchema: 2))
    }

    @Test func aSessionFromBeforeCaptureTimesWereSavedKeepsItsDecisions() throws {
        // Version 1 files have no capture times at all. Their decisions are kept once, and the next save
        // records the times.
        let json = """
            {"schemaVersion":1,"key":"vol-ABC","rootHint":"/Volumes/Fuji SD","undecidedOnly":false,
             "frames":[{"id":"DCIM/124_FUJI/DSCF0001","jpgSize":12,"rafSize":87,
                        "mark":{"decision":"keep","isFavourite":false}}]}
            """
        let file = try JSONDecoder().decode(SessionFile.self, from: Data(json.utf8))
        let stored = try #require(file.frames.first)

        #expect(stored.captureTime == nil)
        #expect(stored.mark == FrameMark(decision: .keep), "a mark saved before the edit flag existed has none")
        #expect(
            SessionRestore.binds(
                stored, to: CaptureTime(dateTime: "2026:09:20 05:08:11", subsecond: nil),
                savedBySchema: file.schemaVersion))
        #expect(!SessionRestore.binds(stored, to: nil, savedBySchema: file.schemaVersion))
    }

    @Test func theEditFlagIsSavedAndRestored() throws {
        let frames = [frame("DSCF0001"), frame("DSCF0002")]
        var session = CullSession(frameIDs: frames.map(\.id))
        session.apply(.toggleNeedsEdit)
        let file = SessionFile(key: "k", rootHint: "", session: session, frames: frames)

        let decoded = try JSONDecoder().decode(SessionFile.self, from: JSONEncoder().encode(file))

        #expect(decoded.frames.first?.mark == FrameMark(decision: .keep, needsEdit: true))
        guard case .full(let restored) = SessionRestore.match(decoded, to: frames) else {
            Issue.record("expected a full match")
            return
        }
        #expect(restored.mark(at: 0).needsEdit)
    }

    @Test func newFilesAreSavedAsVersionTwo() {
        #expect(SessionFile.currentSchemaVersion == 2)
    }

    @Test func noSavedSessionMeansAFreshStart() {
        #expect(SessionRestore.match(nil, to: [frame("DSCF0001")]) == .none)
    }

    @Test func aSessionWithNoDecisionsStillRestoresItsPosition() {
        let frames = [frame("DSCF0001"), frame("DSCF0002")]
        var session = CullSession(frameIDs: frames.map(\.id))
        session.apply(.next)
        let file = SessionFile(key: "k", rootHint: "", session: session, frames: frames)

        guard case .full(let restored) = SessionRestore.match(file, to: frames) else {
            Issue.record("expected a full match")
            return
        }
        #expect(restored.cursor == 1)
    }

    @Test func framesDeletedByApplyDoNotCountAsMissing() {
        // After Apply deleted the rejects, only keepers and undecided frames are left on the card.
        let before = [frame("DSCF0001"), frame("DSCF0002"), frame("DSCF0003"), frame("DSCF0004")]
        var session = CullSession(frameIDs: before.map(\.id))
        session.apply(.keep)
        session.apply(.reject)
        session.apply(.reject)
        let file = SessionFile(key: "k", rootHint: "", session: session, frames: before)
        let after = [before[0], before[3]]

        let outcome = SessionRestore.match(file, to: after, deletedByApply: [before[1].id, before[2].id])

        guard case .full(let restored) = outcome else {
            Issue.record("expected a silent restore, got \(outcome)")
            return
        }
        #expect(restored.mark(at: 0).decision == .keep)
        #expect(restored.counts.reject == 0)
    }

    @Test func newFramesOnTheCardArriveUndecided() {
        let old = [frame("DSCF0001"), frame("DSCF0002")]
        var session = CullSession(frameIDs: old.map(\.id))
        session.apply(.keep)
        let file = SessionFile(key: "k", rootHint: "", session: session, frames: old)
        let now = old + [frame("DSCF0003")]

        guard case .full(let restored) = SessionRestore.match(file, to: now) else {
            Issue.record("expected a full match")
            return
        }
        #expect(restored.counts == CullCounts(keep: 1, reject: 0, undecided: 2, favourite: 0))
    }

    @Test func aReformattedCardWithReusedNamesIsAPartialMatch() {
        // Same names, different photos: the sizes don't match, so the old decisions must not carry over.
        let old = [frame("DSCF0001", jpg: 12_096_415), frame("DSCF0002", jpg: 13_076_139)]
        var session = CullSession(frameIDs: old.map(\.id))
        session.apply(.reject)
        session.apply(.keep)
        let file = SessionFile(key: "k", rootHint: "", session: session, frames: old)
        let reshot = [frame("DSCF0001", jpg: 11_820_383), frame("DSCF0002", jpg: 11_828_645)]

        let outcome = SessionRestore.match(file, to: reshot)

        guard case .partial(let matched, let expected, let resumed) = outcome else {
            Issue.record("expected a partial match, got \(outcome)")
            return
        }
        #expect(matched == 0 && expected == 2)
        #expect(resumed.counts.undecided == 2, "resuming keeps only matching decisions")
    }

    @Test func aPartialMatchKeepsOnlyTheMatchingDecisions() {
        let old = [frame("DSCF0001"), frame("DSCF0002"), frame("DSCF0003")]
        var session = CullSession(frameIDs: old.map(\.id))
        session.apply(.keep)
        session.apply(.reject)
        session.apply(.keep)
        let file = SessionFile(key: "k", rootHint: "", session: session, frames: old)
        // DSCF0002 was deleted in camera; DSCF0003 was replaced by a different photo of the same name.
        let now = [old[0], frame("DSCF0003", jpg: 99)]

        guard case .partial(let matched, let expected, let resumed) = SessionRestore.match(file, to: now) else {
            Issue.record("expected a partial match")
            return
        }
        #expect(matched == 1 && expected == 3)
        #expect(resumed.mark(at: 0).decision == .keep)
        #expect(resumed.mark(at: 1).decision == .undecided)
    }

    @Test func anOrphanMatchesOnlyTheFilesItHas() {
        let jpgOnly = [frame("DSCF0009", raf: nil)]
        var session = CullSession(frameIDs: jpgOnly.map(\.id))
        session.apply(.keep)
        let file = SessionFile(key: "k", rootHint: "", session: session, frames: jpgOnly)
        let rafAppeared = [frame("DSCF0009")]

        #expect(SessionRestore.match(file, to: jpgOnly).isFull)
        #expect(!SessionRestore.match(file, to: rafAppeared).isFull, "a different set of files is a different frame")
    }
}

extension RestoreOutcome {
    var isFull: Bool {
        if case .full = self { return true }
        return false
    }
}
