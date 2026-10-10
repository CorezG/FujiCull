import Foundation
import Testing

@testable import FujiCullCore

// One Apply at a time per trip folder (SR3).
@Suite struct ArchiveLockTests {
    let japan = Ledger.Destination(volumeUUID: "7CA26A15", folder: "Japan 2026")

    @Test func aSecondApplyToTheSameFolderIsRefusedUntilTheFirstLetsGo() throws {
        let tree = try TempTree()
        var first: ArchiveLock? = try ArchiveLock.acquire(in: tree.root, for: japan)

        #expect(throws: ArchiveLock.LockError.busy) { try ArchiveLock.acquire(in: tree.root, for: japan) }
        // The volume ignores case, so the same folder in other capitals is the same folder.
        #expect(throws: ArchiveLock.LockError.busy) {
            try ArchiveLock.acquire(
                in: tree.root, for: Ledger.Destination(volumeUUID: "7CA26A15", folder: "JAPAN 2026"))
        }

        first = nil
        _ = first
        #expect(throws: Never.self) { try ArchiveLock.acquire(in: tree.root, for: japan) }
    }

    @Test func differentFoldersAndDifferentDrivesDoNotBlockEachOther() throws {
        let tree = try TempTree()
        let held = try ArchiveLock.acquire(in: tree.root, for: japan)

        #expect(throws: Never.self) {
            try ArchiveLock.acquire(
                in: tree.root, for: Ledger.Destination(volumeUUID: "7CA26A15", folder: "Italy 2025"))
        }
        #expect(throws: Never.self) {
            try ArchiveLock.acquire(in: tree.root, for: Ledger.Destination(volumeUUID: "OTHER", folder: "Japan 2026"))
        }
        withExtendedLifetime(held) {}
    }

    @Test func aLockThatCannotBeCreatedIsAnError() throws {
        let tree = try TempTree()
        let file = try tree.file("not-a-folder")

        #expect(throws: ArchiveLock.LockError.self) { try ArchiveLock.acquire(in: file, for: japan) }
    }
}
