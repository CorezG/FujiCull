import CryptoKit
import Foundation
import Testing

@testable import FujiCullCore

private func payload(_ count: Int) -> Data {
    var state: UInt64 = 0x9E37_79B9_7F4A_7C15
    return Data(
        (0..<count).map { _ in
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return UInt8(truncatingIfNeeded: state >> 56)
        })
}

private func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

// The copy primitive (DESIGN §5.7 executor step 2; SR7, SR10, SR16). Temporary folders only.
@Suite struct SafeCopyTests {
    let card: TempTree
    let archive: TempTree
    let bytes = payload(10_000)
    let taken = Date(timeIntervalSince1970: 1_726_808_891)
    let sourcePath = "DCIM/124_FUJI/DSCF0001.JPG"

    init() throws {
        card = try TempTree()
        archive = try TempTree()
        let url = card.url(sourcePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: url)
    }

    /// A request to copy the source to `DSCF0001.JPG` in the archive, in 1,000-byte chunks (so 10 writes).
    private func request(
        _ fs: some FileSystem, expectedSize: Int64? = nil, expectedSHA256: String? = nil
    ) throws -> SafeCopy.Request {
        SafeCopy.Request(
            sourceFolder: try fs.openFolder(at: card.root.path), sourcePath: sourcePath,
            expectedSize: expectedSize ?? Int64(bytes.count), expectedSHA256: expectedSHA256,
            destination: try fs.openFolder(at: archive.root.path), finalName: "DSCF0001.JPG", modified: taken,
            chunkSize: 1_000)
    }

    private func archiveListing() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: archive.root.path).sorted()
    }

    private func failure(_ fs: some FileSystem, _ request: SafeCopy.Request, isCancelled: () -> Bool = { false })
        -> SafeCopy.Failure?
    {
        do {
            _ = try SafeCopy.copy(request, using: fs, isCancelled: isCancelled)
            return nil
        } catch {
            return error
        }
    }

    // MARK: Success

    @Test func aSuccessfulCopyIsIdenticalVerifiedAndDated() throws {
        let fs = FaultyFileSystem()

        let result = try SafeCopy.copy(try request(fs), using: fs, isCancelled: { false })

        #expect(result == SafeCopy.Result(sha256: sha256(bytes), size: 10_000))
        #expect(try Data(contentsOf: archive.url("DSCF0001.JPG")) == bytes)
        #expect(try archiveListing() == ["DSCF0001.JPG"], "no partial file is left")
        let modified = try #require(
            try archive.url("DSCF0001.JPG").resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate)
        #expect(abs(modified.timeIntervalSince(taken)) < 0.001)
    }

    @Test func theCopyIsMadeDurableBeforeItIsReported() throws {
        let fs = FaultyFileSystem()

        _ = try SafeCopy.copy(try request(fs), using: fs, isCancelled: { false })

        #expect(fs.calls(.write) == 10, "one write per chunk")
        #expect(fs.calls(.syncFile) == 1)
        #expect(fs.calls(.syncFolder) == 1)
        #expect(fs.calls(.rename) == 1)
    }

    @Test func theSourceIsNeverModified() throws {
        let fs = FaultyFileSystem()
        let before = try FileManager.default.attributesOfItem(atPath: card.url(sourcePath).path)

        _ = try SafeCopy.copy(try request(fs), using: fs, isCancelled: { false })

        let after = try FileManager.default.attributesOfItem(atPath: card.url(sourcePath).path)
        #expect(try Data(contentsOf: card.url(sourcePath)) == bytes)
        #expect(before[.modificationDate] as? Date == after[.modificationDate] as? Date)
    }

    @Test func anEmptyFileCopies() throws {
        try Data().write(to: card.url(sourcePath))
        let fs = FaultyFileSystem()

        let result = try SafeCopy.copy(try request(fs, expectedSize: 0), using: fs, isCancelled: { false })

        #expect(result == SafeCopy.Result(sha256: sha256(Data()), size: 0))
        #expect(try archiveListing() == ["DSCF0001.JPG"])
    }

    @Test func aGooglePhotosCopyIsMadeWhenTheSourceStillHashesToTheRecordedValue() throws {
        let fs = FaultyFileSystem()

        let result = try SafeCopy.copy(
            try request(fs, expectedSHA256: sha256(bytes)), using: fs, isCancelled: { false })

        #expect(result.sha256 == sha256(bytes))
    }

    // MARK: Faults: no final file, no partial, a typed error

    @Test(arguments: [1, 4, 10])
    func aWriteErrorAtAnyChunkLeavesNothingBehind(chunk: Int) throws {
        let fs = FaultyFileSystem(.fail(.write, call: chunk, code: ENOSPC))

        let failure = try #require(failure(fs, try request(fs)))

        #expect(
            failure.reason
                == .io(FileSystemError(operation: .write, name: ".DSCF0001.JPG.fujicull-partial", code: ENOSPC)))
        #expect(failure.leftBehind.isEmpty)
        #expect(try archiveListing().isEmpty)
    }

    @Test func aCorruptedReadBackFailsVerificationAndLeavesNothingBehind() throws {
        let fs = FaultyFileSystem(.corruptReads(nameContains: "fujicull-partial"))

        let failure = try #require(failure(fs, try request(fs)))

        #expect(failure == SafeCopy.Failure(reason: .verificationFailed, leftBehind: []))
        #expect(try archiveListing().isEmpty)
    }

    @Test func cancellingBetweenChunksLeavesNothingBehind() throws {
        let fs = FaultyFileSystem()
        var checks = 0

        let failure = try #require(
            failure(fs, try request(fs)) {
                checks += 1
                return checks > 3
            })

        #expect(failure == SafeCopy.Failure(reason: .cancelled, leftBehind: []))
        #expect(fs.calls(.write) == 3, "stopped after three chunks")
        #expect(try archiveListing().isEmpty)
    }

    @Test func cancellingDuringTheReadBackLeavesNothingBehind() throws {
        let fs = FaultyFileSystem()
        var checks = 0

        let failure = try #require(
            failure(fs, try request(fs)) {
                checks += 1
                return checks > 14  // 11 checks while copying 10 chunks, then into the read-back
            })

        #expect(failure == SafeCopy.Failure(reason: .cancelled, leftBehind: []))
        #expect(try archiveListing().isEmpty)
    }

    @Test func anExistingDestinationIsNeverOverwritten() throws {
        let theirs = Data("someone else's photo".utf8)
        try theirs.write(to: archive.url("DSCF0001.JPG"))
        let fs = FaultyFileSystem()

        let failure = try #require(failure(fs, try request(fs)))

        #expect(failure == SafeCopy.Failure(reason: .nameTaken("DSCF0001.JPG"), leftBehind: []))
        #expect(try Data(contentsOf: archive.url("DSCF0001.JPG")) == theirs)
        #expect(try archiveListing() == ["DSCF0001.JPG"])
        #expect(fs.calls(.write) == 0, "noticed before 100 MB is written, not after")
    }

    @Test func aNameTheVolumeTreatsAsTheSameIsTaken() throws {
        // The volume decides what counts as the same name (SR10). The test volume ignores case, like exFAT.
        let theirs = Data("theirs".utf8)
        try theirs.write(to: archive.url("dscf0001.jpg"))
        let fs = FaultyFileSystem()

        let failure = try #require(failure(fs, try request(fs)))

        #expect(failure.reason == .nameTaken("DSCF0001.JPG"))
        #expect(try Data(contentsOf: archive.url("dscf0001.jpg")) == theirs)
        #expect(try archiveListing() == ["dscf0001.jpg"])
    }

    @Test func aFileThatAppearsAtTheLastMomentIsNotOverwritten() throws {
        // Free when the copy started, taken by the time the name is claimed.
        let theirs = Data("arrived during the copy".utf8)
        let target = archive.url("DSCF0001.JPG")
        let fs = FaultyFileSystem(
            .before(.setModified, call: 1) {
                FileManager.default.createFile(atPath: target.path, contents: theirs)
            })

        let failure = try #require(failure(fs, try request(fs)))

        #expect(failure == SafeCopy.Failure(reason: .nameTaken("DSCF0001.JPG"), leftBehind: []))
        #expect(try Data(contentsOf: target) == theirs)
        #expect(try archiveListing() == ["DSCF0001.JPG"])
    }

    @Test func aLeftoverPartialUnderTheSameNameStopsTheCopy() throws {
        try Data("stale".utf8).write(to: archive.url(".DSCF0001.JPG.fujicull-partial"))
        let fs = FaultyFileSystem()

        let failure = try #require(failure(fs, try request(fs)))

        #expect(failure == SafeCopy.Failure(reason: .nameTaken(".DSCF0001.JPG.fujicull-partial"), leftBehind: []))
        #expect(try archiveListing() == [".DSCF0001.JPG.fujicull-partial"], "it wasn't ours to remove")
    }

    @Test func aFailedSyncFailsTheCopyAndIsNotDowngraded() throws {
        // Some drives refuse F_FULLFSYNC. That is a failed copy, never "good enough".
        let fs = FaultyFileSystem(.fail(.syncFile, call: 1, code: ENOTTY))

        let failure = try #require(failure(fs, try request(fs)))

        #expect(
            failure.reason
                == .io(FileSystemError(operation: .syncFile, name: ".DSCF0001.JPG.fujicull-partial", code: ENOTTY)))
        #expect(try archiveListing().isEmpty)
    }

    @Test func aSourceThatIsNotTheExpectedSizeIsNotCopied() throws {
        let fs = FaultyFileSystem()

        let failure = try #require(failure(fs, try request(fs, expectedSize: 9_999)))

        #expect(
            failure == SafeCopy.Failure(reason: .sourceChanged(expectedSize: 9_999, actualSize: 10_000), leftBehind: [])
        )
        #expect(try archiveListing().isEmpty)
    }

    @Test func aSourceThatNoLongerHashesToTheRecordedValueIsNotCopied() throws {
        // An archive JPG edited since it was verified must not become the Google Photos copy.
        let fs = FaultyFileSystem()

        let failure = try #require(failure(fs, try request(fs, expectedSHA256: sha256(Data("different".utf8)))))

        #expect(failure == SafeCopy.Failure(reason: .sourceMismatch, leftBehind: []))
        #expect(try archiveListing().isEmpty)
    }

    @Test func aMissingSourceFailsBeforeAnythingIsCreated() throws {
        try FileManager.default.removeItem(at: card.url(sourcePath))
        let fs = FaultyFileSystem()

        let failure = try #require(failure(fs, try request(fs)))

        #expect(failure.reason == .io(FileSystemError(operation: .openForReading, name: sourcePath, code: ENOENT)))
        #expect(fs.calls(.create) == 0)
        #expect(try archiveListing().isEmpty)
    }

    @Test(arguments: [FileOperation.setModified, .rename, .syncFolder])
    func aFailureInTheLastStepsLeavesNothingBehind(operation: FileOperation) throws {
        let fs = FaultyFileSystem(.fail(operation, call: 1, code: EIO))

        let failure = try #require(failure(fs, try request(fs)))

        #expect(failure.leftBehind.isEmpty)
        #expect(try archiveListing().isEmpty, "neither the placeholder, the partial nor a half-finished file")
    }

    @Test func aFinalFileOfTheWrongSizeFailsVerification() throws {
        let target = archive.url("DSCF0001.JPG")
        let fs = FaultyFileSystem(
            .after(.rename, call: 1) {
                FileManager.default.createFile(atPath: target.path, contents: Data("short".utf8))
            })

        let failure = try #require(failure(fs, try request(fs)))

        #expect(failure == SafeCopy.Failure(reason: .verificationFailed, leftBehind: []))
        #expect(try archiveListing().isEmpty)
    }

    // MARK: The drive disappears: what a crash leaves, for recovery to deal with

    @Test func ifTheDriveGoesMidCopyThePartialIsReportedAsLeftBehind() throws {
        let fs = FaultyFileSystem(.die(.write, call: 3))

        let failure = try #require(failure(fs, try request(fs)))

        #expect(failure.leftBehind == [".DSCF0001.JPG.fujicull-partial"])
        #expect(try archiveListing() == [".DSCF0001.JPG.fujicull-partial"])
    }

    @Test func ifTheDriveGoesBetweenTheClaimAndTheRenameAnEmptyPlaceholderIsLeft() throws {
        // The state executor step 1 must recover from: a zero-length file under the final name, and the partial.
        let fs = FaultyFileSystem(.die(.rename, call: 1))

        let failure = try #require(failure(fs, try request(fs)))

        #expect(failure.leftBehind.sorted() == [".DSCF0001.JPG.fujicull-partial", "DSCF0001.JPG"])
        #expect(try archiveListing() == [".DSCF0001.JPG.fujicull-partial", "DSCF0001.JPG"])
        #expect(try Data(contentsOf: archive.url("DSCF0001.JPG")).isEmpty)
        #expect(try Data(contentsOf: archive.url(".DSCF0001.JPG.fujicull-partial")) == bytes)
    }
}
