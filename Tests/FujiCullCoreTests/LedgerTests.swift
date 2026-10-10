import Foundation
import Testing

@testable import FujiCullCore

private let frame1 = Owner.frame(FrameID("DCIM/124_FUJI/DSCF0001"))
private let frame2 = Owner.frame(FrameID("DCIM/124_FUJI/DSCF0002"))

private func at(_ name: String, subfolder: String? = nil, folder: String = "Japan 2026") -> ArchiveLocation {
    ArchiveLocation(volumeUUID: "7CA26A15", folder: folder, subfolder: subfolder, name: name)
}

private func source(_ path: String = "DCIM/124_FUJI/DSCF0001.JPG") -> SourceIdentity {
    SourceIdentity(
        path: path, size: 12_096_415, modified: Date(timeIntervalSince1970: 1_726_808_891),
        captureTime: CaptureTime(dateTime: "2026:09:20 05:08:11", subsecond: "42"), sha256: "ab12")
}

private func reserve(_ location: ArchiveLocation, by owner: Owner = frame1, as role: FileRole = .jpg) -> LedgerRecord {
    .reserve(owner: owner, role: role, location: location, partial: SafeCopy.partialName(for: location.name))
}

private func verified(_ location: ArchiveLocation, by owner: Owner = frame1, as role: FileRole = .jpg) -> LedgerRecord {
    .verified(owner: owner, role: role, location: location, source: source(), size: 12_096_415, sha256: "ab12")
}

// What the journal's records add up to (DESIGN §5.7 Ledger; SR15, SR25, SR26).
@Suite struct LedgerTests {
    let jpg = at("DSCF0001.JPG")
    let raf = at("DSCF0001.RAF")

    // MARK: An archive file's state

    @Test func aReservedFileIsNotYetVerified() {
        let ledger = Ledger([reserve(jpg)])

        #expect(ledger.file(at: jpg)?.status == .reserved)
        #expect(ledger.file(at: jpg)?.partial == ".DSCF0001.JPG.fujicull-partial")
        #expect(ledger.openReservations.map(\.location) == [jpg])
    }

    @Test func reserveThenVerifiedIsAFileFujiCullProvablyWrote() {
        let ledger = Ledger([reserve(jpg), verified(jpg)])
        let file = ledger.file(at: jpg)

        #expect(file?.status == .verified)
        #expect(file?.source == source())
        #expect(file?.size == 12_096_415)
        #expect(file?.sha256 == "ab12")
        #expect(ledger.openReservations.isEmpty)
    }

    @Test func aVerifiedRecordWithoutAReservationIsIgnored() {
        // No reserve means no proof that FujiCull created the file, so it must never look removable.
        let ledger = Ledger([verified(jpg)])

        #expect(ledger.file(at: jpg) == nil)
    }

    @Test func onlyTheFrameThatReservedANameCanVerifyIt() {
        let ledger = Ledger([
            reserve(jpg, by: frame1, as: .jpg), verified(jpg, by: frame2, as: .jpg),
            verified(jpg, by: frame1, as: .raw),
        ])

        #expect(ledger.file(at: jpg)?.status == .reserved)
    }

    @Test func aReleasedReservationIsNoLongerOpen() {
        let ledger = Ledger([reserve(jpg), .released(location: jpg)])

        #expect(ledger.file(at: jpg)?.status == .released)
        #expect(ledger.openReservations.isEmpty)
    }

    @Test func aReleasedNameCanBeReservedByAnotherFrame() {
        let ledger = Ledger([
            reserve(jpg, by: frame1, as: .jpg), .released(location: jpg), reserve(jpg, by: frame2, as: .jpg),
        ])

        #expect(ledger.file(at: jpg)?.owner == frame2)
        #expect(ledger.file(at: jpg)?.status == .reserved)
        #expect(ledger.allFiles.count == 1)
    }

    @Test func aVerifiedFileCannotBeReleased() {
        let ledger = Ledger([reserve(jpg), verified(jpg), .released(location: jpg)])

        #expect(ledger.file(at: jpg)?.status == .verified)
    }

    @Test func aSupersededFileStaysOnRecordButIsNoLongerCurrent() {
        let again = at("DSCF0001-2.JPG")
        let ledger = Ledger([reserve(jpg), verified(jpg), .superseded(location: jpg), reserve(again), verified(again)])

        #expect(ledger.file(at: jpg)?.status == .superseded)
        #expect(ledger.files(of: frame1).filter { $0.status == .verified }.map(\.location) == [again])
    }

    @Test func aSupersededFileCanNeverBeTrashed() {
        let ledger = Ledger([reserve(jpg), verified(jpg), .superseded(location: jpg), .trashing(location: jpg)])

        #expect(ledger.file(at: jpg)?.status == .superseded)
        #expect(ledger.unsettledTrashes.isEmpty)
    }

    // MARK: Intent, then outcome (SR25)

    @Test func aTrashMoveIsUnsettledUntilItsOutcomeIsRecorded() {
        var ledger = Ledger([reserve(jpg), verified(jpg), .trashing(location: jpg)])
        #expect(ledger.file(at: jpg)?.status == .trashing)
        #expect(ledger.unsettledTrashes.map(\.location) == [jpg])
        #expect(ledger.file(at: jpg)?.sha256 == "ab12", "what was verified is still known")

        ledger.record(.trashed(location: jpg, trashPath: "/Volumes/C&J Archive/.Trashes/501/DSCF0001.JPG"))

        #expect(ledger.file(at: jpg)?.status == .trashed)
        #expect(ledger.file(at: jpg)?.trashPath == "/Volumes/C&J Archive/.Trashes/501/DSCF0001.JPG")
        #expect(ledger.unsettledTrashes.isEmpty)
    }

    @Test func aTrashedRecordWithoutItsIntentIsIgnored() {
        let ledger = Ledger([reserve(jpg), verified(jpg), .trashed(location: jpg, trashPath: nil)])

        #expect(ledger.file(at: jpg)?.status == .verified)
    }

    @Test func aFileThatWasNeverVerifiedCannotBeTrashed() {
        let ledger = Ledger([reserve(jpg), .trashing(location: jpg)])

        #expect(ledger.file(at: jpg)?.status == .reserved)
    }

    @Test func aCardDeletionIsUnsettledUntilItsOutcomeIsRecorded() {
        var ledger = Ledger([
            .deleting(path: "DCIM/124_FUJI/DSCF0003.RAF"), .deleting(path: "DCIM/124_FUJI/DSCF0003.JPG"),
        ])
        #expect(ledger.cardFileStatus("DCIM/124_FUJI/DSCF0003.RAF") == .deleting)
        #expect(ledger.unsettledDeletes == ["DCIM/124_FUJI/DSCF0003.JPG", "DCIM/124_FUJI/DSCF0003.RAF"])

        ledger.record(.deleted(path: "DCIM/124_FUJI/DSCF0003.RAF"))

        #expect(ledger.cardFileStatus("DCIM/124_FUJI/DSCF0003.RAF") == .deleted)
        #expect(ledger.unsettledDeletes == ["DCIM/124_FUJI/DSCF0003.JPG"])
        #expect(ledger.cardFileStatus("DCIM/124_FUJI/DSCF0001.JPG") == nil)
    }

    // MARK: Tags are their own family (SR12)

    @Test func aTagRecordDoesNotChangeTheFilesState() {
        let ledger = Ledger([reserve(jpg), verified(jpg), .tagged(location: jpg)])

        #expect(ledger.file(at: jpg)?.status == .verified, "a later tag record doesn't replace 'verified'")
        #expect(ledger.file(at: jpg)?.taggedByUs == true)
    }

    @Test func theLatestTagRecordWins() {
        let ledger = Ledger([reserve(jpg), verified(jpg), .tagged(location: jpg), .untagged(location: jpg)])

        #expect(ledger.file(at: jpg)?.taggedByUs == false)
    }

    @Test func aTagOnAFileFujiCullDidNotWriteIsNotRecorded() {
        let ledger = Ledger([.tagged(location: jpg)])

        #expect(ledger.file(at: jpg) == nil)
    }

    // MARK: Destinations and owners

    @Test func theLatestChosenDestinationIsRemembered() {
        let ledger = Ledger([
            .destination(volumeUUID: "7CA26A15", folder: "Japan 2026"),
            .destination(volumeUUID: "7CA26A15", folder: "Japan 2026 part 2"),
        ])

        #expect(ledger.chosenDestination == Ledger.Destination(volumeUUID: "7CA26A15", folder: "Japan 2026 part 2"))
        #expect(Ledger().chosenDestination == nil)
    }

    @Test func filesAreListedPerOwnerInTheOrderReserved() {
        let google = at("DSCF0001.JPG", subfolder: "Google Photos")
        let other = at("DSCF0002.JPG")
        let ledger = Ledger([
            reserve(raf, by: frame1, as: .raw), reserve(other, by: frame2, as: .jpg),
            reserve(jpg, by: frame1, as: .jpg),
            reserve(google, by: frame1, as: .googlePhotos),
        ])

        #expect(ledger.files(of: frame1).map(\.location) == [raf, jpg, google])
        #expect(ledger.files(of: frame1).map(\.role) == [.raw, .jpg, .googlePhotos])
        #expect(ledger.files(of: .video("DCIM/124_FUJI/DSCF0009.MOV")).isEmpty)
    }

    @Test func theSameNameInAnotherFolderOrSubfolderIsADifferentFile() {
        let ledger = Ledger([reserve(jpg), verified(jpg)])

        #expect(ledger.file(at: at("DSCF0001.JPG", subfolder: "Google Photos")) == nil)
        #expect(ledger.file(at: at("DSCF0001.JPG", folder: "Italy 2025")) == nil)
    }

    @Test func recordsForUnknownFilesAreIgnored() {
        let ledger = Ledger([
            .released(location: jpg), .superseded(location: jpg), .trashing(location: jpg), .untagged(location: jpg),
        ])

        #expect(ledger == Ledger())
    }

    // MARK: Records as JSON lines

    @Test func everyKindOfRecordRoundTripsAsOneLineOfJSON() throws {
        let records: [LedgerRecord] = [
            .destination(volumeUUID: "7CA26A15", folder: "Japan 2026"),
            reserve(at("DSCF0009.MOV", subfolder: "Videos"), by: .video("DCIM/124_FUJI/DSCF0009.MOV"), as: .video),
            verified(jpg), .released(location: jpg), .superseded(location: jpg), .tagged(location: jpg),
            .untagged(location: jpg), .trashing(location: jpg), .trashed(location: jpg, trashPath: nil),
            .trashed(location: jpg, trashPath: "/Volumes/C&J Archive/.Trashes/501/a\nb.JPG"),
            .deleting(path: "DCIM/124_FUJI/DSCF0003.RAF"), .deleted(path: "DCIM/124_FUJI/DSCF0003.RAF"),
        ]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        for record in records {
            let line = try encoder.encode(record)

            #expect(!line.contains(UInt8(ascii: "\n")), "one record, one line")
            #expect(try JSONDecoder().decode(LedgerRecord.self, from: line) == record)
        }
    }
}

// The journal on disk: append-only, durable per record, repairable after a crash (SR5, SR15).
@Suite struct LedgerJournalTests {
    let tree: TempTree
    let url: URL
    let jpg = at("DSCF0001.JPG")

    init() throws {
        tree = try TempTree()
        url = tree.url("Ledger/vol-ABC.jsonl")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    }

    private func load() throws -> [LedgerRecord] { try LedgerJournal.open(at: url).records }

    @Test func aNewJournalIsEmpty() throws {
        #expect(try load().isEmpty)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test func recordsComeBackInTheOrderTheyWereAppended() throws {
        let records = [reserve(jpg), verified(jpg), .tagged(location: jpg)]
        do {
            let journal = try LedgerJournal.open(at: url).journal
            for record in records { try journal.append(record) }
        }

        #expect(try load() == records)
        #expect(Ledger(try load()).file(at: jpg)?.status == .verified)
    }

    @Test func reopeningAndAppendingKeepsWhatWasThere() throws {
        try LedgerJournal.open(at: url).journal.append(reserve(jpg))
        try LedgerJournal.open(at: url).journal.append(verified(jpg))

        #expect(try load() == [reserve(jpg), verified(jpg)])
    }

    @Test func aCrashPartWayThroughAnAppendLosesOnlyThatRecord() throws {
        // Whatever part of the new line reached the disk, the next open sees exactly the old journal.
        do {
            let journal = try LedgerJournal.open(at: url).journal
            try journal.append(reserve(jpg))
            try journal.append(verified(jpg))
        }
        let whole = try Data(contentsOf: url)
        let old = whole.prefix(try #require(whole.firstIndex(of: UInt8(ascii: "\n"))) + 1)

        for cut in old.count..<(whole.count - 1) {
            try whole.prefix(cut).write(to: url)

            let records = try load()

            #expect(records == [reserve(jpg)], "cut after \(cut - old.count) bytes of the second record")
            #expect(try Data(contentsOf: url) == old, "the torn tail is removed from the file")
        }
    }

    @Test func aJournalRepairedAfterACrashAcceptsNewRecords() throws {
        try LedgerJournal.open(at: url).journal.append(reserve(jpg))
        var torn = try Data(contentsOf: url)
        torn.append(Data(#"{"verified":{"loc"#.utf8))
        try torn.write(to: url)

        try LedgerJournal.open(at: url).journal.append(.released(location: jpg))

        #expect(try load() == [reserve(jpg), .released(location: jpg)])
    }

    @Test func aJournalThatIsOnlyATornFirstRecordBecomesEmpty() throws {
        try Data(#"{"reserve":{"#.utf8).write(to: url)

        #expect(try load().isEmpty)
        #expect(try Data(contentsOf: url).isEmpty)
    }

    @Test func aDamagedLineInTheMiddleStopsEverythingAndTheJournalIsNotTouched() throws {
        do {
            let journal = try LedgerJournal.open(at: url).journal
            try journal.append(reserve(jpg))
            try journal.append(verified(jpg))
        }
        var lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map(String.init)
        lines.insert("this is not a record", at: 1)
        let damaged = Data((lines.joined(separator: "\n") + "\n").utf8)
        try damaged.write(to: url)

        #expect(throws: LedgerJournal.JournalError.corrupt(line: 2)) { try LedgerJournal.open(at: url) }
        #expect(try Data(contentsOf: url) == damaged)
    }

    @Test func aBlankLineIsDamageToo() throws {
        try LedgerJournal.open(at: url).journal.append(reserve(jpg))
        var damaged = try Data(contentsOf: url)
        damaged.append(Data("\n".utf8))
        try damaged.write(to: url)

        #expect(throws: LedgerJournal.JournalError.corrupt(line: 2)) { try LedgerJournal.open(at: url) }
    }

    @Test func aCompleteLastLineThatIsNotARecordIsDamageNotATornTail() throws {
        try LedgerJournal.open(at: url).journal.append(reserve(jpg))
        var damaged = try Data(contentsOf: url)
        damaged.append(Data("{\"reserve\":{}}\n".utf8))
        try damaged.write(to: url)

        #expect(throws: LedgerJournal.JournalError.corrupt(line: 2)) { try LedgerJournal.open(at: url) }
        #expect(try Data(contentsOf: url) == damaged)
    }

    @Test func aJournalThatCannotBeOpenedIsAnError() {
        let missing = tree.url("NoSuchFolder/vol-ABC.jsonl")

        #expect(throws: LedgerJournal.JournalError.self) { try LedgerJournal.open(at: missing) }
    }
}
