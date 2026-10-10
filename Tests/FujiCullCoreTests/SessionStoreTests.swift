import Foundation
import Testing

@testable import FujiCullCore

private func sampleFile(key: String = "vol-TEST", decisions: Int = 2) -> SessionFile {
    let frames = (1...max(decisions, 1)).map { n in
        Frame(
            id: FrameID("DCIM/124_FUJI/DSCF\(n)"),
            jpg: SourceFile(relativePath: "DCIM/124_FUJI/DSCF\(n).JPG", size: Int64(n), modified: .distantPast),
            raf: nil)
    }
    var session = CullSession(frameIDs: frames.map(\.id))
    for _ in 0..<decisions { session.apply(.keep) }
    return SessionFile(key: key, rootHint: "/Volumes/Fuji SD", session: session, frames: frames)
}

/// Lists every file under `root`, with sizes, so tests can prove a tree wasn't touched.
private func snapshot(_ root: URL) throws -> [String: Int] {
    var result: [String: Int] = [:]
    let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey])
    while let url = walker?.nextObject() as? URL {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? -1
        result[url.path] = size
    }
    return result
}

// SessionStore: one locked, crash-safe session file per card in Application Support (DESIGN §5.3; SR3–SR5).
@Suite struct SessionStoreTests {

    @Test func savedSessionsReadBackAfterReopening() async throws {
        let support = try TempTree()
        let file = sampleFile()

        let store = SessionStore(directory: support.root)
        _ = try await store.open(key: file.key)
        try await store.save(file)
        try await store.close()

        let reopened = SessionStore(directory: support.root)
        let loaded = try await reopened.open(key: file.key)
        try await reopened.close()
        #expect(loaded == file)
    }

    @Test func aCardWithNoSavedSessionOpensEmpty() async throws {
        let support = try TempTree()
        let store = SessionStore(directory: support.root)

        #expect(try await store.open(key: "vol-NEW") == nil)
        try await store.close()
    }

    @Test func savesAreDebouncedAndTheLatestStateWins() async throws {
        let support = try TempTree()
        let store = SessionStore(directory: support.root, debounce: .milliseconds(50))
        _ = try await store.open(key: "vol-TEST")

        await store.scheduleSave(sampleFile(decisions: 1))
        await store.scheduleSave(sampleFile(decisions: 3))
        try await Task.sleep(for: .milliseconds(300))

        let onDisk = try JSONDecoder().decode(
            SessionFile.self, from: Data(contentsOf: support.url("Sessions/vol-TEST.json")))
        #expect(onDisk.frames.count == 3)
        try await store.close()
    }

    @Test func closingFlushesAPendingSave() async throws {
        let support = try TempTree()
        let store = SessionStore(directory: support.root, debounce: .seconds(60))
        _ = try await store.open(key: "vol-TEST")

        await store.scheduleSave(sampleFile(decisions: 2))
        try await store.close()

        let onDisk = try JSONDecoder().decode(
            SessionFile.self, from: Data(contentsOf: support.url("Sessions/vol-TEST.json")))
        #expect(onDisk.frames.count == 2)
    }

    @Test func aSecondStoreCannotOpenACardThatIsAlreadyOpen() async throws {
        let support = try TempTree()
        let first = SessionStore(directory: support.root)
        let second = SessionStore(directory: support.root)
        _ = try await first.open(key: "vol-TEST")

        await #expect(throws: SessionStore.StoreError.alreadyOpen(key: "vol-TEST")) {
            _ = try await second.open(key: "vol-TEST")
        }

        try await first.close()
        _ = try await second.open(key: "vol-TEST")
        try await second.close()
    }

    @Test func aCorruptSessionIsSetAsideAndTheCardOpensFresh() async throws {
        let support = try TempTree()
        try support.file("Sessions/vol-TEST.json", bytes: 0)
        try Data("{ not json".utf8).write(to: support.url("Sessions/vol-TEST.json"))
        let store = SessionStore(directory: support.root)

        #expect(try await store.open(key: "vol-TEST") == nil)
        try await store.close()

        let names = try FileManager.default.contentsOfDirectory(atPath: support.url("Sessions").path)
        #expect(names.contains { $0.hasPrefix("vol-TEST.json.bad") }, "the damaged file is kept for inspection")
        let reset = try JSONDecoder().decode(
            SessionFile.self, from: Data(contentsOf: support.url("Sessions/vol-TEST.json")))
        #expect(reset.frames.isEmpty, "the live file is reset to an empty, valid session")
    }

    @Test func aNewerSchemaIsNotOverwritten() async throws {
        let support = try TempTree()
        var future = sampleFile()
        future.schemaVersion = SessionFile.currentSchemaVersion + 1
        try FileManager.default.createDirectory(at: support.url("Sessions"), withIntermediateDirectories: true)
        try JSONEncoder().encode(future).write(to: support.url("Sessions/vol-TEST.json"))
        let store = SessionStore(directory: support.root)

        await #expect(throws: SessionStore.StoreError.newerVersion(key: "vol-TEST")) {
            _ = try await store.open(key: "vol-TEST")
        }
    }

    @Test func startingFreshArchivesTheOldSessionAndLedger() async throws {
        let support = try TempTree()
        let store = SessionStore(directory: support.root)
        _ = try await store.open(key: "vol-TEST")
        try await store.save(sampleFile())
        try support.file("Ledger/vol-TEST.jsonl", bytes: 10)

        try await store.startFresh()
        try await store.close()

        let reset = try JSONDecoder().decode(
            SessionFile.self, from: Data(contentsOf: support.url("Sessions/vol-TEST.json")))
        #expect(reset.frames.isEmpty)
        #expect(try Data(contentsOf: support.url("Ledger/vol-TEST.jsonl")).isEmpty)
        let archived = try FileManager.default.contentsOfDirectory(atPath: support.url("Archive").path)
        #expect(archived.count == 1)
        let inside = try FileManager.default.contentsOfDirectory(
            atPath: support.url("Archive/\(try #require(archived.first))").path)
        #expect(Set(inside) == ["vol-TEST.json", "vol-TEST.jsonl"])
    }

    @Test func openingAnotherCardClosesTheFirstAndReleasesItsLock() async throws {
        let support = try TempTree()
        let store = SessionStore(directory: support.root)
        _ = try await store.open(key: "vol-A")
        _ = try await store.open(key: "vol-B")

        let other = SessionStore(directory: support.root)
        _ = try await other.open(key: "vol-A")
        try await other.close()
        try await store.close()
    }

    @Test func nothingHappensWithoutAnOpenCard() async throws {
        let support = try TempTree()
        let store = SessionStore(directory: support.root)

        await store.scheduleSave(sampleFile())
        await #expect(throws: SessionStore.StoreError.notOpen) { try await store.startFresh() }
        try await store.close()
        #expect(!FileManager.default.fileExists(atPath: support.url("Sessions").path))
    }

    @Test func savingWithoutOpeningIsRefused() async {
        let support = try? TempTree()
        let store = SessionStore(directory: support?.root ?? FileManager.default.temporaryDirectory)

        await #expect(throws: SessionStore.StoreError.notOpen) { try await store.save(sampleFile()) }
    }

    @Test func savingNeverWritesInsideTheSourceTree() async throws {
        let card = try TempTree()
        try card.file("DCIM/124_FUJI/DSCF0001.JPG", bytes: 12)
        try card.file("DCIM/124_FUJI/DSCF0001.RAF", bytes: 87)
        let before = try snapshot(card.root)
        let support = try TempTree()

        let store = SessionStore(directory: support.root)
        _ = try await store.open(key: try SessionKey.for(source: card.root))
        try await store.save(sampleFile(key: try SessionKey.for(source: card.root)))
        try await store.startFresh()
        try await store.close()

        #expect(try snapshot(card.root) == before, "the card is never written before Apply (R21)")
    }
}

// SessionKey: one key per card however it was opened (SR1).
@Suite struct SessionKeyTests {

    @Test func aFolderOnTheInternalDiskIsKeyedByItsPath() throws {
        let tree = try TempTree()
        let key = try SessionKey.for(source: tree.root)

        #expect(key.hasPrefix("path-"))
        #expect(try SessionKey.for(source: tree.root) == key, "stable for the same folder")
    }

    @Test func differentFoldersGetDifferentKeys() throws {
        let a = try TempTree()
        let b = try TempTree()

        #expect(try SessionKey.for(source: a.root) != SessionKey.for(source: b.root))
    }

    @Test func aCardIsKeyedByItsVolumeUUID() {
        // Fuji SD's real UUID, which stayed the same across a rename and a different reader (spike S3).
        let key = SessionKey.make(
            volumeUUID: "DB8E88CF-4EEB-30E1-85B7-2D06B3D78E33", baseIsVolumeRoot: true,
            canonicalPath: "/Volumes/Fuji SD")

        #expect(key == "vol-DB8E88CF-4EEB-30E1-85B7-2D06B3D78E33")
    }

    @Test func theSameCardUnderADifferentNameKeepsItsKey() {
        let before = SessionKey.make(volumeUUID: "DB8E88CF", baseIsVolumeRoot: true, canonicalPath: "/Volumes/Untitled")
        let after = SessionKey.make(volumeUUID: "DB8E88CF", baseIsVolumeRoot: true, canonicalPath: "/Volumes/Fuji SD")

        #expect(before == after)
    }

    @Test func aVolumeWithoutAUUIDFallsBackToItsPath() {
        let key = SessionKey.make(volumeUUID: nil, baseIsVolumeRoot: true, canonicalPath: "/Volumes/Fuji SD")

        #expect(key.hasPrefix("path-"))
    }

    @Test func keysAreSafeFilenames() throws {
        let tree = try TempTree()
        let key = try SessionKey.for(source: tree.url("."))

        #expect(!key.contains("/") && !key.contains(":"))
    }
}
