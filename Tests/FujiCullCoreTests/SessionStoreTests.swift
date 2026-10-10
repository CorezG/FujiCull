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

    @Test func anOlderRevisionArrivingLateNeverOverwritesANewerOne() async throws {
        let support = try TempTree()
        let store = SessionStore(directory: support.root, debounce: .milliseconds(50))
        _ = try await store.open(key: "vol-TEST")

        await store.scheduleSave(sampleFile(decisions: 3), revision: 2)
        await store.scheduleSave(sampleFile(decisions: 1), revision: 1)
        try await store.close()

        let onDisk = try JSONDecoder().decode(
            SessionFile.self, from: Data(contentsOf: support.url("Sessions/vol-TEST.json")))
        #expect(onDisk.frames.count == 3)
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

@Suite struct SessionStoreApplyTests {
    @Test func theOpenCardsJournalSitsBesideItsSession() async throws {
        let tree = try TempTree()
        let store = SessionStore(directory: tree.root, debounce: .zero)

        await #expect(throws: SessionStore.StoreError.notOpen) { try await store.ledgerURL() }
        _ = try await store.open(key: "vol-ABC")

        #expect(try await store.ledgerURL() == tree.url("Ledger/vol-ABC.jsonl"))
        #expect(await store.locksDirectory == tree.url("Locks"))
        try await store.close()
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
            volumeUUID: "DB8E88CF-4EEB-30E1-85B7-2D06B3D78E33", isCard: true, formatted: nil, capacity: nil,
            canonicalPath: "/Volumes/Fuji SD")

        #expect(key == "vol-DB8E88CF-4EEB-30E1-85B7-2D06B3D78E33")
    }

    @Test func theSameCardUnderADifferentNameKeepsItsKey() {
        let before = SessionKey.make(
            volumeUUID: "DB8E88CF", isCard: true, formatted: nil, capacity: nil, canonicalPath: "/Volumes/Untitled")
        let after = SessionKey.make(
            volumeUUID: "DB8E88CF", isCard: true, formatted: nil, capacity: nil, canonicalPath: "/Volumes/Fuji SD")

        #expect(before == after)
    }

    @Test func aCardWithoutAVolumeIDIsKeyedByWhenItWasFormattedAndItsSize() throws {
        // The X-T50 formats a small (FAT32) card without a volume serial, so macOS reports no UUID and every
        // such card is called "NO NAME" (measured 2026-10-10). The format time and capacity tell them apart.
        let utc = try #require(TimeZone(identifier: "UTC"))
        let formatted = try date(2026, 10, 11, 3, 55, 20, in: utc)

        let key = SessionKey.make(
            volumeUUID: nil, isCard: true, formatted: formatted, capacity: 8_001_716_224,
            canonicalPath: "/Volumes/NO NAME", timeZone: utc)

        #expect(key == "card-8001716224-20261011T035520")
    }

    @Test func twoUnnamedCardsFormattedAtDifferentTimesGetDifferentKeys() throws {
        let utc = try #require(TimeZone(identifier: "UTC"))
        let first = SessionKey.make(
            volumeUUID: nil, isCard: true, formatted: try date(2026, 10, 11, 3, 55, 20, in: utc),
            capacity: 8_001_716_224, canonicalPath: "/Volumes/NO NAME", timeZone: utc)
        let second = SessionKey.make(
            volumeUUID: nil, isCard: true, formatted: try date(2026, 10, 12, 9, 0, 0, in: utc),
            capacity: 8_001_716_224, canonicalPath: "/Volumes/NO NAME", timeZone: utc)

        #expect(first != second)
    }

    @Test func aCardKeyStaysTheSameWhenTheMacChangesTimeZone() throws {
        // FAT stores local time without a zone, so the same card reads as a different instant after travel.
        // The key uses the wall-clock digits, which don't move.
        let newYork = try #require(TimeZone(identifier: "America/New_York"))
        let tokyo = try #require(TimeZone(identifier: "Asia/Tokyo"))

        let atHome = SessionKey.make(
            volumeUUID: nil, isCard: true, formatted: try date(2026, 10, 10, 23, 55, 20, in: newYork),
            capacity: 8_001_716_224, canonicalPath: "/Volumes/NO NAME", timeZone: newYork)
        let away = SessionKey.make(
            volumeUUID: nil, isCard: true, formatted: try date(2026, 10, 10, 23, 55, 20, in: tokyo),
            capacity: 8_001_716_224, canonicalPath: "/Volumes/NO NAME", timeZone: tokyo)

        #expect(atHome == away)
    }

    @Test func anAllZeroVolumeIDCountsAsNoID() throws {
        let utc = try #require(TimeZone(identifier: "UTC"))
        let key = SessionKey.make(
            volumeUUID: "00000000-0000-0000-0000-000000000000", isCard: true,
            formatted: try date(2026, 10, 11, 3, 55, 20, in: utc), capacity: 8_001_716_224,
            canonicalPath: "/Volumes/NO NAME", timeZone: utc)

        #expect(key.hasPrefix("card-"))
    }

    @Test func aCardWithNeitherAnIDNorAFormatDateFallsBackToItsPath() {
        let key = SessionKey.make(
            volumeUUID: nil, isCard: true, formatted: nil, capacity: 8_001_716_224, canonicalPath: "/Volumes/NO NAME")

        #expect(key.hasPrefix("path-"))
    }

    @Test func aFolderThatIsNotACardIsKeyedByItsPathEvenOnADriveWithAnID() {
        // Two trip folders on one USB drive must not share a session.
        let a = SessionKey.make(
            volumeUUID: "7CA26A15", isCard: false, formatted: nil, capacity: nil, canonicalPath: "/Volumes/Stick/Trip A"
        )
        let b = SessionKey.make(
            volumeUUID: "7CA26A15", isCard: false, formatted: nil, capacity: nil, canonicalPath: "/Volumes/Stick/Trip B"
        )

        #expect(a.hasPrefix("path-") && b.hasPrefix("path-") && a != b)
    }

    @Test func keysAreSafeFilenames() throws {
        let tree = try TempTree()
        let key = try SessionKey.for(source: tree.url("."))

        #expect(!key.contains("/") && !key.contains(":"))
    }
}

private func date(
    _ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int, _ second: Int, in zone: TimeZone
) throws -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = zone
    return try #require(
        calendar.date(
            from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second)))
}
