import Testing

@testable import FujiCullCore

/// Five frames, cursor on the first, auto-advance on.
private func session(_ count: Int = 5, autoAdvance: Bool = true) -> CullSession {
    CullSession(frameIDs: (0..<count).map { FrameID("DCIM/100_FUJI/DSCF\($0 + 1)") }, autoAdvance: autoAdvance)
}

private func applying(_ commands: [CullCommand], to start: CullSession) -> CullSession {
    var s = start
    for command in commands { s.apply(command) }
    return s
}

// The keymap's session rules (REQUIREMENTS §4.2–4.3, R7–R11; DESIGN §5.2, D3, D4).
@Suite struct CullSessionTests {

    // MARK: ↑ Keep, ↓ Reject (with auto-advance, R11)

    @Test func upKeepsTheFrameAndMovesToTheNext() {
        let s = applying([.keep], to: session())

        #expect(s.mark(at: 0).decision == .keep)
        #expect(s.cursor == 1)
    }

    @Test func downRejectsTheFrameAndMovesToTheNext() {
        let s = applying([.reject], to: session())

        #expect(s.mark(at: 0).decision == .reject)
        #expect(s.cursor == 1)
    }

    @Test func withAutoAdvanceOffTheCursorStays() {
        let s = applying([.keep], to: session(autoAdvance: false))

        #expect(s.mark(at: 0).decision == .keep)
        #expect(s.cursor == 0)
    }

    @Test func decidingTheLastFrameStaysOnIt() {
        let s = applying([.jump(10), .keep], to: session())

        #expect(s.cursor == 4)
        #expect(s.mark(at: 4).decision == .keep)
    }

    // MARK: ← → and ⇧← ⇧→

    @Test func arrowsMoveWithoutDeciding() {
        let s = applying([.next, .next, .previous], to: session())

        #expect(s.cursor == 1)
        #expect(s.counts.undecided == 5)
    }

    @Test func movementStopsAtBothEnds() {
        #expect(applying([.previous], to: session()).cursor == 0)
        #expect(applying([.next, .next, .next, .next, .next, .next], to: session()).cursor == 4)
    }

    @Test func shiftArrowsJumpTenAndClamp() {
        let s = session(25)

        #expect(applying([.jump(10)], to: s).cursor == 10)
        #expect(applying([.jump(10), .jump(10), .jump(10)], to: s).cursor == 24)
        #expect(applying([.jump(10), .jump(-10), .jump(-10)], to: s).cursor == 0)
    }

    // MARK: / Favourite (R8)

    @Test func favouritingAnUndecidedFrameAlsoKeepsIt() {
        let s = applying([.toggleFavourite], to: session())

        #expect(s.mark(at: 0) == FrameMark(decision: .keep, isFavourite: true))
        #expect(s.cursor == 0, "/ doesn't advance")
    }

    @Test func favouritingARejectedFrameTurnsItIntoAKeep() {
        let s = applying([.reject, .previous, .toggleFavourite], to: session())

        #expect(s.mark(at: 0) == FrameMark(decision: .keep, isFavourite: true))
    }

    @Test func togglingFavouriteOffLeavesTheFrameKept() {
        let s = applying([.toggleFavourite, .toggleFavourite], to: session())

        #expect(s.mark(at: 0) == FrameMark(decision: .keep, isFavourite: false))
    }

    @Test func rejectingAFavouriteClearsTheHeart() {
        let s = applying([.toggleFavourite, .reject], to: session())

        #expect(s.mark(at: 0) == FrameMark(decision: .reject, isFavourite: false))
    }

    @Test func keepingAFavouriteLeavesItAFavourite() {
        let s = applying([.toggleFavourite, .keep], to: session())

        #expect(s.mark(at: 0) == FrameMark(decision: .keep, isFavourite: true))
    }

    // MARK: . Reset

    @Test func resetReturnsAFrameToUndecidedAndClearsTheHeart() {
        let s = applying([.toggleFavourite, .reset], to: session())

        #expect(s.mark(at: 0) == FrameMark())
        #expect(s.cursor == 0, ". doesn't advance")
    }

    // MARK: ⌫ Undo (R10, D3)

    @Test func undoRestoresTheDecisionAndFavouriteAndMovesBack() {
        let s = applying([.toggleFavourite, .reject, .undo], to: session())

        #expect(s.mark(at: 0) == FrameMark(decision: .keep, isFavourite: true))
        #expect(s.cursor == 0)
    }

    @Test func undoWalksBackThroughEveryDecision() {
        let s = applying([.keep, .reject, .keep, .undo, .undo, .undo], to: session())

        #expect(s.counts.undecided == 5)
        #expect(s.cursor == 0)
    }

    @Test func undoIgnoresNavigation() {
        let s = applying([.keep, .next, .next, .undo], to: session())

        #expect(s.mark(at: 0).decision == .undecided)
        #expect(s.cursor == 0)
    }

    @Test func undoWithNothingToUndoChangesNothing() {
        let start = applying([.next], to: session())

        #expect(applying([.undo], to: start) == start)
    }

    @Test func aCommandThatChangesNothingIsNotAddedToUndo() {
        let s = applying([.reset, .keep, .undo], to: session(autoAdvance: false))

        #expect(s.mark(at: 0).decision == .undecided)
        #expect(s.canUndo == false)
    }

    // MARK: ' Undecided-only filter (D4)

    @Test func theFilterSkipsDecidedFrames() {
        let s = applying([.keep, .keep, .previous, .previous, .toggleUndecidedFilter], to: session())

        #expect(s.undecidedOnly)
        #expect(s.cursor == 2, "turning the filter on moves off a decided frame")
        #expect(s.visibleIndices == [2, 3, 4])
    }

    @Test func decidingUnderTheFilterShowsTheNextUndecidedFrame() {
        let s = applying([.toggleUndecidedFilter, .toggleFavourite], to: session(autoAdvance: false))

        #expect(s.mark(at: 0).decision == .keep)
        #expect(s.cursor == 1, "the decided frame leaves the list, even with auto-advance off")
    }

    @Test func decidingTheLastUndecidedFrameFallsBackToAnEarlierOne() {
        let s = applying([.next, .next, .next, .next, .toggleUndecidedFilter, .keep], to: session())

        #expect(s.cursor == 3)
        #expect(s.currentFrameID == FrameID("DCIM/100_FUJI/DSCF4"))
    }

    @Test func whenEverythingIsDecidedTheFilteredListIsEmpty() {
        let s = applying([.toggleUndecidedFilter, .keep, .keep, .reject, .keep, .reject], to: session())

        #expect(s.visibleIndices.isEmpty)
        #expect(s.currentFrameID == nil)
        #expect(s.counts.undecided == 0)
    }

    @Test func arrowsUnderTheFilterMoveBetweenUndecidedFramesOnly() {
        let s = applying([.next, .keep, .previous, .toggleUndecidedFilter, .next], to: session(autoAdvance: false))

        #expect(s.cursor == 2, "frame 1 is kept, so → from frame 0 lands on frame 2")
    }

    @Test func undoUnderTheFilterBringsTheFrameBack() {
        let s = applying([.toggleUndecidedFilter, .keep, .undo], to: session())

        #expect(s.cursor == 0)
        #expect(s.visibleIndices == [0, 1, 2, 3, 4])
    }

    // MARK: Counts (R16)

    @Test func countsFollowEveryChange() {
        // keep 0, reject 1, ♥ 2, reject 2 (clears the heart), back to 2, reset 2.
        let s = applying([.keep, .reject, .toggleFavourite, .reject, .previous, .reset], to: session())

        #expect(s.counts == CullCounts(keep: 1, reject: 1, undecided: 3, favourite: 0))
    }

    // MARK: Restoring saved marks

    @Test func savedMarksAreRestoredAndAFavouriteWithoutKeepIsRepaired() {
        let ids = (1...3).map { FrameID("F\($0)") }
        let s = CullSession(
            frameIDs: ids,
            marks: [
                ids[0]: FrameMark(decision: .keep, isFavourite: true),
                ids[1]: FrameMark(decision: .reject, isFavourite: true),
            ])

        #expect(s.mark(at: 0) == FrameMark(decision: .keep, isFavourite: true))
        #expect(s.mark(at: 1) == FrameMark(decision: .reject, isFavourite: false))
        #expect(s.counts == CullCounts(keep: 1, reject: 1, undecided: 1, favourite: 1))
    }

    @Test func anEmptySessionIgnoresEveryCommand() {
        let empty = CullSession(frameIDs: [])
        let all: [CullCommand] = [.keep, .reject, .toggleFavourite, .reset, .next, .previous, .jump(10), .undo]

        #expect(applying(all + [.toggleUndecidedFilter], to: empty).currentFrameID == nil)
    }

    // MARK: Invariants under random use

    @Test func invariantsHoldAcrossRandomCommandSequences() {
        var random = SeededRandom(seed: 0x5EED_F00D)
        let commands: [CullCommand] = [
            .keep, .reject, .toggleFavourite, .reset, .next, .previous, .jump(10), .jump(-10), .undo,
            .toggleUndecidedFilter,
        ]
        for run in 0..<50 {
            var s = session(Int(random.next() % 30), autoAdvance: run.isMultiple(of: 2))
            for _ in 0..<100 {
                s.apply(commands[Int(random.next() % UInt64(commands.count))])
                checkInvariants(s)
            }
        }
    }

    private func checkInvariants(_ s: CullSession) {
        var keep = 0
        var reject = 0
        var favourite = 0
        for index in s.frameIDs.indices {
            let mark = s.mark(at: index)
            if mark.isFavourite { #expect(mark.decision == .keep, "a favourite is always kept (R8)") }
            if mark.decision == .keep { keep += 1 }
            if mark.decision == .reject { reject += 1 }
            if mark.isFavourite { favourite += 1 }
        }
        #expect(
            s.counts
                == CullCounts(
                    keep: keep, reject: reject, undecided: s.frameIDs.count - keep - reject, favourite: favourite))
        if s.frameIDs.isEmpty {
            #expect(s.currentFrameID == nil)
        } else {
            #expect(s.frameIDs.indices.contains(s.cursor))
            if s.undecidedOnly, !s.visibleIndices.isEmpty { #expect(s.visibleIndices.contains(s.cursor)) }
        }
    }
}

/// Deterministic generator so a failing random sequence can be replayed.
private struct SeededRandom {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state >> 33
    }
}
