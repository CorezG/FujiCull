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
