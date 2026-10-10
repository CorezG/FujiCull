import CryptoKit
import Foundation
import Testing

@testable import FujiCullCore

// The real file-system calls Apply is built from, against temporary folders only (DESIGN §5.7, SR7, SR10).
@Suite struct LocalFileSystemTests {
    let fs = LocalFileSystem()

    private func expectError(
        _ operation: FileOperation, code: Int32, sourceLocation: SourceLocation = #_sourceLocation,
        _ body: () throws -> Void
    ) {
        do {
            try body()
            Issue.record("expected \(operation) to fail", sourceLocation: sourceLocation)
        } catch let error as FileSystemError {
            #expect(error.operation == operation, sourceLocation: sourceLocation)
            #expect(error.code == code, sourceLocation: sourceLocation)
        } catch {
            Issue.record("unexpected error \(error)", sourceLocation: sourceLocation)
        }
    }

    // MARK: Folders and identity

    @Test func openingAMissingFolderFails() {
        expectError(.openFolder, code: ENOENT) { _ = try fs.openFolder(at: "/nonexistent-\(UUID().uuidString)") }
    }

    @Test func openingAFileAsAFolderFails() throws {
        let tree = try TempTree()
        let file = try tree.file("a.bin")

        expectError(.openFolder, code: ENOTDIR) { _ = try fs.openFolder(at: file.path) }
    }

    @Test func theVolumeUUIDReadFromAnOpenFolderMatchesWhatFoundationReports() throws {
        let tree = try TempTree()
        let folder = try fs.openFolder(at: tree.root.path)

        let expected = try tree.root.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString

        #expect(try fs.volumeUUID(of: folder) == expected)
        #expect(expected != nil)
    }

    // MARK: Entries

    @Test func anEntryReportsItsSizeAndDate() throws {
        let tree = try TempTree()
        let modified = Date(timeIntervalSince1970: 1_700_000_000)
        try tree.file("DSCF0001.JPG", bytes: 1234, modified: modified)
        let folder = try fs.openFolder(at: tree.root.path)

        let entry = try #require(try fs.entry("DSCF0001.JPG", in: folder))

        #expect(entry == EntryInfo(size: 1234, modified: modified, isRegularFile: true))
    }

    @Test func aMissingEntryIsNil() throws {
        let tree = try TempTree()
        let folder = try fs.openFolder(at: tree.root.path)

        #expect(try fs.entry("nope.JPG", in: folder) == nil)
    }

    @Test func aFolderIsNotARegularFile() throws {
        let tree = try TempTree()
        try tree.file("Google Photos/a.JPG")
        let folder = try fs.openFolder(at: tree.root.path)

        #expect(try fs.entry("Google Photos", in: folder)?.isRegularFile == false)
    }

    @Test func lookingUpAnEntryThroughAFileFails() throws {
        let tree = try TempTree()
        try tree.file("a.bin")
        let folder = try fs.openFolder(at: tree.root.path)

        expectError(.entry, code: ENOTDIR) { _ = try fs.entry("a.bin/inside", in: folder) }
    }

    // MARK: Creating, writing, reading

    @Test func exclusiveCreateRefusesANameTheVolumeAlreadyHas() throws {
        let tree = try TempTree()
        try tree.file("DSCF0001.JPG")
        let folder = try fs.openFolder(at: tree.root.path)

        do {
            _ = try fs.createExclusively("DSCF0001.JPG", in: folder, uncached: false)
            Issue.record("expected the create to be refused")
        } catch {
            #expect(error.alreadyExists)
            #expect(error.operation == .create)
        }
    }

    @Test func whatIsWrittenUncachedReadsBackTheSame() throws {
        let tree = try TempTree()
        let folder = try fs.openFolder(at: tree.root.path)
        let payload = Data((0..<100_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })

        let out = try fs.createExclusively("a.fujicull-partial", in: folder, uncached: true)
        try fs.write(payload.prefix(40_000), to: out)
        try fs.write(payload.dropFirst(40_000), to: out)
        try fs.syncToDevice(out)
        try fs.syncToDevice(folder)

        let back = try fs.openForReading("a.fujicull-partial", in: folder)
        var read = Data()
        while true {
            let chunk = try fs.read(back, upTo: 30_000)
            if chunk.isEmpty { break }
            read.append(chunk)
        }
        #expect(read == payload)
    }

    @Test func readingOpensFilesInSubfolders() throws {
        let tree = try TempTree()
        try tree.file("DCIM/124_FUJI/DSCF0001.JPG", bytes: 10)
        let folder = try fs.openFolder(at: tree.root.path)

        let file = try fs.openForReading("DCIM/124_FUJI/DSCF0001.JPG", in: folder)

        #expect(try fs.read(file, upTo: 100).count == 10)
    }

    @Test func openingAMissingFileFails() throws {
        let tree = try TempTree()
        let folder = try fs.openFolder(at: tree.root.path)

        expectError(.openForReading, code: ENOENT) { _ = try fs.openForReading("nope.JPG", in: folder) }
    }

    @Test func readingFromAFileOpenedForWritingFails() throws {
        let tree = try TempTree()
        let folder = try fs.openFolder(at: tree.root.path)
        let out = try fs.createExclusively("a.bin", in: folder, uncached: false)

        expectError(.read, code: EBADF) { _ = try fs.read(out, upTo: 10) }
    }

    @Test func writingToAFileOpenedForReadingFails() throws {
        let tree = try TempTree()
        try tree.file("a.bin")
        let folder = try fs.openFolder(at: tree.root.path)
        let file = try fs.openForReading("a.bin", in: folder)

        expectError(.write, code: EBADF) { try fs.write(Data([1, 2, 3]), to: file) }
    }

    // MARK: Dates, renames, removal

    @Test func theModificationDateCanBeSet() throws {
        let tree = try TempTree()
        try tree.file("a.JPG")
        let folder = try fs.openFolder(at: tree.root.path)
        let taken = Date(timeIntervalSince1970: 1_726_800_000.25)

        try fs.setModified(taken, of: "a.JPG", in: folder)

        let modified = try #require(try fs.entry("a.JPG", in: folder)).modified
        #expect(abs(modified.timeIntervalSince(taken)) < 0.001)
    }

    @Test func settingTheDateOfAMissingFileFails() throws {
        let tree = try TempTree()
        let folder = try fs.openFolder(at: tree.root.path)

        expectError(.setModified, code: ENOENT) { try fs.setModified(.now, of: "nope", in: folder) }
    }

    @Test func renameMovesAFileToItsNewName() throws {
        let tree = try TempTree()
        try tree.file(".a.JPG.fujicull-partial", bytes: 7)
        let folder = try fs.openFolder(at: tree.root.path)

        try fs.rename(".a.JPG.fujicull-partial", to: "a.JPG", in: folder)

        #expect(try fs.entry("a.JPG", in: folder)?.size == 7)
        #expect(try fs.entry(".a.JPG.fujicull-partial", in: folder) == nil)
    }

    @Test func renamingAMissingFileFails() throws {
        let tree = try TempTree()
        let folder = try fs.openFolder(at: tree.root.path)

        expectError(.rename, code: ENOENT) { try fs.rename("nope", to: "a.JPG", in: folder) }
    }

    @Test func removeDeletesOneFile() throws {
        let tree = try TempTree()
        try tree.file("a.JPG")
        try tree.file("b.JPG")
        let folder = try fs.openFolder(at: tree.root.path)

        try fs.remove("a.JPG", in: folder)

        #expect(try FileManager.default.contentsOfDirectory(atPath: tree.root.path) == ["b.JPG"])
    }

    @Test func removingAMissingFileFails() throws {
        let tree = try TempTree()
        let folder = try fs.openFolder(at: tree.root.path)

        expectError(.remove, code: ENOENT) { try fs.remove("nope", in: folder) }
    }

    // MARK: Folders, listings, space

    @Test func aFolderIsCreatedOnceAndRefusedTheSecondTime() throws {
        let tree = try TempTree()
        let folder = try fs.openFolder(at: tree.root.path)

        try fs.createFolder("Japan 2026", in: folder)

        #expect(try fs.entry("Japan 2026", in: folder)?.isRegularFile == false)
        do {
            try fs.createFolder("japan 2026", in: folder)
            Issue.record("the volume ignores case, so this is the same name")
        } catch {
            #expect(error.alreadyExists)
        }
    }

    @Test func aListingHasEveryNameIncludingHiddenOnes() throws {
        let tree = try TempTree()
        try tree.file("DSCF0001.JPG")
        try tree.file(".DSCF0002.JPG.fujicull-partial")
        try tree.file("Google Photos/DSCF0001.JPG")
        let folder = try fs.openFolder(at: tree.root.path)

        #expect(
            try fs.names(in: folder).sorted() == [".DSCF0002.JPG.fujicull-partial", "DSCF0001.JPG", "Google Photos"])
        #expect(try fs.names(in: folder).count == 3, "listing twice gives the same answer")
    }

    @Test func aVolumeReportsItsFreeSpaceAndAllocationSize() throws {
        let tree = try TempTree()
        let folder = try fs.openFolder(at: tree.root.path)

        let space = try fs.volumeSpace(of: folder)

        #expect(space.freeBytes > 0 && space.allocationSize >= 512)
    }

    // MARK: Tags and the Trash, which take a path (SR7)

    @Test func tagsAreSetReadBackAndCleared() throws {
        let tree = try TempTree()
        try tree.file("DSCF0001.JPG")
        let folder = try fs.openFolder(at: tree.root.path)

        #expect(try fs.tags(of: "DSCF0001.JPG", in: folder).isEmpty)
        try fs.setTags(["Favourite", "Print"], of: "DSCF0001.JPG", in: folder)
        #expect(try fs.tags(of: "DSCF0001.JPG", in: folder) == ["Favourite", "Print"])
        try fs.setTags([], of: "DSCF0001.JPG", in: folder)
        #expect(try fs.tags(of: "DSCF0001.JPG", in: folder).isEmpty)
    }

    @Test func taggingAMissingFileFails() throws {
        let tree = try TempTree()
        let folder = try fs.openFolder(at: tree.root.path)

        expectError(.writeTags, code: ENOENT) { try fs.setTags(["Favourite"], of: "nope.JPG", in: folder) }
        expectError(.readTags, code: ENOENT) { _ = try fs.tags(of: "nope.JPG", in: folder) }
    }

    @Test func aTagThatCannotBeWrittenIsAnErrorNotASilentSkip() throws {
        let tree = try TempTree()
        let file = try tree.file("locked.JPG")
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: file.path)
        defer {
            do {
                try FileManager.default.setAttributes([.immutable: false], ofItemAtPath: file.path)
            } catch {
                Issue.record("could not unlock the test file: \(error)")
            }
        }
        let folder = try fs.openFolder(at: tree.root.path)

        do {
            try fs.setTags(["Favourite"], of: "locked.JPG", in: folder)
            Issue.record("expected the tag write to fail")
        } catch {
            #expect(error.operation == .writeTags)
        }
    }

    @Test func aFolderThatWasMovedIsStillTheOneThatGetsTagged() throws {
        // The folder is renamed after it was opened. The path is taken from the open folder as it is now,
        // so the tag lands on the right file and nothing is created at the old path.
        let tree = try TempTree()
        try tree.file("Japan/DSCF0001.JPG")
        let folder = try fs.openFolder(at: tree.url("Japan").path)
        try FileManager.default.moveItem(at: tree.url("Japan"), to: tree.url("Japan renamed"))

        try fs.setTags(["Favourite"], of: "DSCF0001.JPG", in: folder)

        let tags = try tree.url("Japan renamed/DSCF0001.JPG").resourceValues(forKeys: [.tagNamesKey]).tagNames
        #expect(tags == ["Favourite"])
        #expect(!FileManager.default.fileExists(atPath: tree.url("Japan").path))
    }

    @Test func movingToTheTrashTakesTheFileOutOfItsFolderWithoutDeletingIt() throws {
        // The one test that uses the real Trash: a 5-byte file, removed from the Trash again afterwards.
        let tree = try TempTree()
        try tree.file("FujiCull-test-\(UUID().uuidString).JPG", bytes: 5)
        let name = try #require(try FileManager.default.contentsOfDirectory(atPath: tree.root.path).first)
        let folder = try fs.openFolder(at: tree.root.path)

        let trashed = try #require(try fs.moveToTrash(name, in: folder))
        defer {
            do { try FileManager.default.removeItem(atPath: trashed) } catch {
                Issue.record("cleanup failed: \(error)")
            }
        }

        #expect(try fs.entry(name, in: folder) == nil)
        #expect(try Data(contentsOf: URL(fileURLWithPath: trashed)).count == 5)
    }

    @Test func trashingAMissingFileFailsAndNothingElseIsTouched() throws {
        let tree = try TempTree()
        try tree.file("keep.JPG")
        let folder = try fs.openFolder(at: tree.root.path)

        expectError(.trash, code: ENOENT) { _ = try fs.moveToTrash("nope.JPG", in: folder) }
        #expect(try fs.names(in: folder) == ["keep.JPG"])
    }
}
