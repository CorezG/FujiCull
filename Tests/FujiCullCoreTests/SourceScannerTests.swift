import Foundation
import Testing

@testable import FujiCullCore

// Scanner behaviour from DESIGN §5.1 (R1–R5, R27, SR1, SR2).
@Suite struct SourceScannerTests {

    // MARK: Pairing

    @Test func pairsJPGAndRAFWithTheSameName() throws {
        let tree = try TempTree()
        try tree.file("DCIM/100_FUJI/DSCF0001.JPG", bytes: 12)
        try tree.file("DCIM/100_FUJI/DSCF0001.RAF", bytes: 87)

        let result = try SourceScanner.scan(tree.root, identityBase: tree.root)

        #expect(result.frames.count == 1)
        let frame = try #require(result.frames.first)
        #expect(frame.id == FrameID("DCIM/100_FUJI/DSCF0001"))
        #expect(frame.jpg?.relativePath == "DCIM/100_FUJI/DSCF0001.JPG")
        #expect(frame.raf?.relativePath == "DCIM/100_FUJI/DSCF0001.RAF")
        #expect(frame.isUnpaired == false)
    }

    @Test func jpgWithoutRAFIsAnUnpairedFrame() throws {
        let tree = try TempTree()
        try tree.file("DCIM/100_FUJI/DSCF0002.JPG")

        let frame = try #require(try SourceScanner.scan(tree.root, identityBase: tree.root).frames.first)

        #expect(frame.jpg != nil)
        #expect(frame.raf == nil)
        #expect(frame.isUnpaired)
    }

    @Test func rafWithoutJPGIsAnUnpairedFrame() throws {
        let tree = try TempTree()
        try tree.file("DCIM/100_FUJI/DSCF0003.RAF")

        let frame = try #require(try SourceScanner.scan(tree.root, identityBase: tree.root).frames.first)

        #expect(frame.jpg == nil)
        #expect(frame.raf != nil)
        #expect(frame.isUnpaired)
    }

    @Test func pairsAcrossDifferentCaseAndJPEGExtension() throws {
        let tree = try TempTree()
        try tree.file("DCIM/100_FUJI/dscf0004.jpeg")
        try tree.file("DCIM/100_FUJI/DSCF0004.RAF")

        let result = try SourceScanner.scan(tree.root, identityBase: tree.root)

        #expect(result.frames.count == 1)
        #expect(result.frames.first?.isUnpaired == false)
        #expect(result.frames.first?.id == FrameID("DCIM/100_FUJI/DSCF0004"))
    }

    @Test func filesInDifferentFoldersAreNeverPaired() throws {
        let tree = try TempTree()
        try tree.file("DCIM/100_FUJI/DSCF0001.JPG")
        try tree.file("DCIM/101_FUJI/DSCF0001.RAF")

        let frames = try SourceScanner.scan(tree.root, identityBase: tree.root).frames

        #expect(frames.count == 2)
        #expect(frames.allSatisfy { $0.isUnpaired })
    }

    // MARK: Groups that aren't exactly one JPG + one RAF (pure grouping, no disk)

    @Test func duplicateNamesThatDifferOnlyInCaseBecomeSeparateOrphans() {
        let files = [
            SourceFile(relativePath: "DCIM/100_FUJI/a.jpg", size: 1, modified: .distantPast),
            SourceFile(relativePath: "DCIM/100_FUJI/A.JPG", size: 2, modified: .distantPast),
            SourceFile(relativePath: "DCIM/100_FUJI/A.RAF", size: 3, modified: .distantPast),
        ]

        let frames = SourceScanner.group(files)

        #expect(frames.count == 3)
        #expect(frames.allSatisfy { $0.isUnpaired })
        #expect(Set(frames.map(\.id)).count == 3, "split orphans must never share an identity")
        #expect(frames.contains { $0.id == FrameID("DCIM/100_FUJI/a.jpg") })
        #expect(frames.contains { $0.id == FrameID("DCIM/100_FUJI/A.JPG") })
    }

    @Test func jpgAndJPEGWithTheSameStemAreSplitIntoOrphans() throws {
        let tree = try TempTree()
        try tree.file("DCIM/100_FUJI/DSCF0005.JPG")
        try tree.file("DCIM/100_FUJI/DSCF0005.JPEG")
        try tree.file("DCIM/100_FUJI/DSCF0005.RAF")

        let frames = try SourceScanner.scan(tree.root, identityBase: tree.root).frames

        #expect(frames.count == 3)
        #expect(frames.allSatisfy { $0.isUnpaired })
        #expect(frames.map(\.id).contains(FrameID("DCIM/100_FUJI/DSCF0005.JPEG")))
    }

    // MARK: Buckets: frames, videos, other files, skipped

    @Test func videosAreCollectedSeparatelyInAnyCase() throws {
        let tree = try TempTree()
        try tree.file("DCIM/100_FUJI/DSCF0010.MOV", bytes: 500)
        try tree.file("DCIM/100_FUJI/DSCF0011.mp4")
        try tree.file("DCIM/100_FUJI/DSCF0012.JPG")

        let result = try SourceScanner.scan(tree.root, identityBase: tree.root)

        #expect(result.frames.count == 1)
        #expect(result.videos.map(\.relativePath) == ["DCIM/100_FUJI/DSCF0010.MOV", "DCIM/100_FUJI/DSCF0011.mp4"])
        #expect(result.videos.first?.size == 500)
    }

    @Test func otherFilesAreListedNotDropped() throws {
        let tree = try TempTree()
        try tree.file("DCIM/100_FUJI/DSCF0020.HIF")
        try tree.file("DCIM/100_FUJI/DSCF0021.WAV")
        try tree.file("notes.txt")

        let result = try SourceScanner.scan(tree.root, identityBase: tree.root)

        #expect(result.frames.isEmpty)
        #expect(
            Set(result.otherFiles.map(\.relativePath))
                == ["DCIM/100_FUJI/DSCF0020.HIF", "DCIM/100_FUJI/DSCF0021.WAV", "notes.txt"])
    }

    @Test func hiddenAndSystemEntriesAreSkipped() throws {
        let tree = try TempTree()
        try tree.file("DCIM/100_FUJI/DSCF0030.JPG")
        try tree.file("DCIM/100_FUJI/._DSCF0030.JPG")
        try tree.file(".Trashes/501/DSCF9000.JPG")
        try tree.file(".Spotlight-V100/Store-V2/index")
        try tree.file(".fseventsd/0000000000000001")
        try tree.file("System Volume Information/IndexerVolumeGuid")
        try tree.file("$RECYCLE.BIN/desktop.ini")
        try tree.file("FFDB/FFDB_X_T50_4DA12884.db")
        try tree.file("ACTIVITY/25101200.LOG")
        try tree.file("UPD/firmware.bin")

        let result = try SourceScanner.scan(tree.root, identityBase: tree.root)

        #expect(result.frames.map(\.id) == [FrameID("DCIM/100_FUJI/DSCF0030")])
        #expect(result.videos.isEmpty)
        #expect(result.otherFiles.isEmpty)
    }

    @Test func cameraSystemFolderNamesAreOnlySkippedAtTheIdentityRoot() throws {
        let tree = try TempTree()
        try tree.file("Trips/FFDB/DSCF0040.JPG")

        let frames = try SourceScanner.scan(tree.root, identityBase: tree.root).frames

        #expect(frames.map(\.id) == [FrameID("Trips/FFDB/DSCF0040")])
    }

    // MARK: Order (D1, ADR-004)

    @Test func ordersByFolderThenFilenameAcrossACounterWrap() throws {
        let tree = try TempTree()
        try tree.file("DCIM/101_FUJI/DSCF0001.JPG")
        try tree.file("DCIM/100_FUJI/DSCF9999.JPG")
        try tree.file("DCIM/100_FUJI/DSCF9998.JPG")
        try tree.file("DCIM/101_FUJI/DSCF0002.JPG")

        let ids = try SourceScanner.scan(tree.root, identityBase: tree.root).frames.map(\.id.rawValue)

        #expect(
            ids == [
                "DCIM/100_FUJI/DSCF9998", "DCIM/100_FUJI/DSCF9999",
                "DCIM/101_FUJI/DSCF0001", "DCIM/101_FUJI/DSCF0002",
            ])
    }

    @Test func orderIsNumericAwareForNamesWithoutLeadingZeros() throws {
        let tree = try TempTree()
        try tree.file("Shoot/IMG_10.JPG")
        try tree.file("Shoot/IMG_9.JPG")
        try tree.file("Shoot/IMG_100.JPG")

        let ids = try SourceScanner.scan(tree.root, identityBase: tree.root).frames.map(\.id.rawValue)

        #expect(ids == ["Shoot/IMG_9", "Shoot/IMG_10", "Shoot/IMG_100"])
    }

    // MARK: Identity and snapshot (SR2)

    @Test func frameIDsAreRelativeToTheIdentityBaseNotTheScannedFolder() throws {
        let tree = try TempTree()
        try tree.file("DCIM/100_FUJI/DSCF0050.JPG")

        let scannedFromDCIM = try SourceScanner.scan(tree.url("DCIM"), identityBase: tree.root)
        let scannedFromRoot = try SourceScanner.scan(tree.root, identityBase: tree.root)

        #expect(scannedFromDCIM.frames.map(\.id) == [FrameID("DCIM/100_FUJI/DSCF0050")])
        #expect(scannedFromDCIM.frames.map(\.id) == scannedFromRoot.frames.map(\.id))
    }

    @Test func aPlainFolderOfJPGsIsScannedRecursively() throws {
        let tree = try TempTree()
        try tree.file("Day 1/DSCF0060.JPG")
        try tree.file("Day 2/Evening/DSCF0061.JPG")

        let ids = try SourceScanner.scan(tree.root, identityBase: tree.root).frames.map(\.id.rawValue)

        #expect(ids == ["Day 1/DSCF0060", "Day 2/Evening/DSCF0061"])
    }

    @Test func recordsSizeAndModificationDateForEachFile() throws {
        let tree = try TempTree()
        let when = Date(timeIntervalSince1970: 1_758_300_000)
        try tree.file("DCIM/100_FUJI/DSCF0070.JPG", bytes: 1234, modified: when)

        let jpg = try #require(try SourceScanner.scan(tree.root, identityBase: tree.root).frames.first?.jpg)

        #expect(jpg.size == 1234)
        #expect(jpg.modified == when)
    }

    @Test func scanningAMissingFolderThrows() {
        let missing = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)")
        #expect(throws: SourceScanner.ScanError.self) {
            try SourceScanner.scan(missing, identityBase: missing)
        }
    }

    @Test func refusesAnIdentityBaseThatDoesNotContainTheFolder() throws {
        let card = try TempTree()
        let elsewhere = try TempTree()
        try card.file("DCIM/100_FUJI/DSCF0080.JPG")

        #expect {
            try SourceScanner.scan(card.url("DCIM"), identityBase: elsewhere.root)
        } throws: { error in
            if case SourceScanner.ScanError.notInsideIdentityBase = error { return true }
            return false
        }
    }

    // MARK: Performance (NFR: open a 2,000-frame card in < 2 s; the scan's share is < 200 ms)

    @Test func scansTwoThousandPairsInUnder200Milliseconds() throws {
        let tree = try TempTree()
        for n in 1...2000 {
            let stem = String(format: "DSCF%04d", n)
            try tree.file("DCIM/100_FUJI/\(stem).JPG")
            try tree.file("DCIM/100_FUJI/\(stem).RAF")
        }

        // Best of three, so a momentarily busy machine doesn't fail the build; the budget itself is unchanged.
        let clock = ContinuousClock()
        var result: ScanResult?
        var best = Duration.seconds(60)
        for _ in 1...3 {
            let elapsed = try clock.measure { result = try SourceScanner.scan(tree.root, identityBase: tree.root) }
            best = min(best, elapsed)
        }

        #expect(result?.frames.count == 2000)
        #expect(best < .milliseconds(200), "best scan took \(best)")
    }
}
