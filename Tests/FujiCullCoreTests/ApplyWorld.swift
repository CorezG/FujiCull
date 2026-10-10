import CryptoKit
import Foundation
import Testing

@testable import FujiCullCore

/// A card, an archive drive and FujiCull's own state, all in temporary folders, for running Apply for real
/// on small files. Nothing here touches a real card, drive or the user's Trash.
final class ApplyWorld {
    let card: TempTree
    let archive: TempTree
    let state: TempTree
    let archiveUUID: String
    var marks: [FrameID: FrameMark] = [:]
    var destination: Ledger.Destination
    /// Set to pretend the session was opened for a card with this volume UUID.
    var cardUUID: String?
    var archiveRoots: [String: String]

    init(trip: String = "Japan 2026") throws {
        card = try TempTree()
        archive = try TempTree()
        state = try TempTree()
        let fs = LocalFileSystem()
        archiveUUID = try #require(try fs.volumeUUID(of: try fs.openFolder(at: archive.root.path)))
        destination = Ledger.Destination(volumeUUID: archiveUUID, folder: trip)
        archiveRoots = [archiveUUID: archive.root.path]
    }

    // MARK: The card

    /// Different, repeatable bytes for every file.
    static func bytes(_ count: Int, seed: UInt64) -> Data {
        var state = seed &* 0x9E37_79B9_7F4A_7C15 &+ 1
        return Data(
            (0..<count).map { _ in
                state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                return UInt8(truncatingIfNeeded: state >> 56)
            })
    }

    private var seed: UInt64 = 0

    private func write(_ path: String, bytes count: Int) throws {
        seed += 1
        let url = card.url(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.bytes(count, seed: seed).write(to: url)
        // A whole-second date well in the past, as a camera writes, different for each file.
        let date = Date(timeIntervalSince1970: 1_726_800_000 + Double(seed) * 3)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }

    /// Adds `DCIM/124_FUJI/<name>.RAF` and `.JPG` and gives the frame a decision.
    @discardableResult
    func addPair(_ name: String, _ mark: FrameMark, folder: String = "DCIM/124_FUJI") throws -> FrameID {
        try write("\(folder)/\(name).RAF", bytes: 3_000)
        try write("\(folder)/\(name).JPG", bytes: 1_200)
        let id = FrameID("\(folder)/\(name)")
        marks[id] = mark
        return id
    }

    func addVideo(_ name: String) throws {
        try write("DCIM/124_FUJI/\(name).MOV", bytes: 5_000)
    }

    // MARK: Running

    func context() throws -> ApplyExecutor.Context {
        let scan = try SourceScanner.scan(card.root, identityBase: card.root)
        // Each frame's capture time is made from its name, so the same photo always has the same one.
        let times = Dictionary(
            uniqueKeysWithValues: scan.frames.map {
                ($0.id, CaptureTime(dateTime: "2026:09:20 05:08:11 \($0.id.rawValue)", subsecond: "42"))
            })
        return ApplyExecutor.Context(
            frames: scan.frames, videos: scan.videos, otherFiles: scan.otherFiles, marks: marks, captureTimes: times,
            source: ApplyInput.Source(volumeUUID: cardUUID, isCameraCard: true, isReadOnly: false),
            destination: destination,
            archiveRoots: archiveRoots)
    }

    var journalURL: URL { state.url("vol-TEST.jsonl") }

    /// A fresh executor, as a new run of the app would make: the journal is reopened and the card rescanned.
    func executor(_ fs: any FileSystem = FaultyFileSystem()) throws -> ApplyExecutor {
        let opened = try LedgerJournal.open(at: journalURL)
        return try ApplyExecutor(
            fs: fs, journal: opened.journal, records: opened.records, card: try fs.openFolder(at: card.root.path),
            context: try context())
    }

    /// One whole healthy pass: recover, plan, copy, tag. Returns the outcome and the executor for inspection.
    @discardableResult
    func run(_ fs: any FileSystem = FaultyFileSystem()) throws -> (
        outcome: ApplyExecutor.CopyOutcome, executor: ApplyExecutor
    ) {
        let executor = try executor(fs)
        _ = try executor.recover()
        let plan = try executor.makePlan()
        return (executor.copy(plan, isCancelled: { false }), executor)
    }

    // MARK: Looking at the archive

    /// Every file under the archive root (hidden ones too), relative path → SHA-256.
    func archiveFiles() throws -> [String: String] {
        var result: [String: String] = [:]
        let root = archive.root.resolvingSymlinksInPath().path
        guard let walker = FileManager.default.enumerator(atPath: root) else { return result }
        for case let path as String in walker {
            let url = URL(fileURLWithPath: root).appendingPathComponent(path)
            if try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                result[path] = SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
            }
        }
        return result
    }

    func archiveNames() throws -> [String] { try archiveFiles().keys.sorted() }

    func tags(_ path: String) throws -> [String] {
        try archive.url(path).resourceValues(forKeys: [.tagNamesKey]).tagNames ?? []
    }

    func setTags(_ tags: [String], on path: String) throws {
        try (archive.url(path) as NSURL).setResourceValue(tags, forKey: .tagNamesKey)
    }

    func cardNames() throws -> [String] {
        try SourceScanner.scan(card.root, identityBase: card.root).frames.flatMap {
            [$0.raf, $0.jpg].compactMap { $0?.relativePath }
        }
    }

    func sha(ofCardFile path: String) throws -> String {
        SHA256.hash(data: try Data(contentsOf: card.url(path))).map { String(format: "%02x", $0) }.joined()
    }

    func location(_ name: String, in subfolder: String? = nil, trip: String? = nil) -> ArchiveLocation {
        ArchiveLocation(volumeUUID: archiveUUID, folder: trip ?? destination.folder, subfolder: subfolder, name: name)
    }
}

let keepMark = FrameMark(decision: .keep)
let favouriteMark = FrameMark(decision: .keep, isFavourite: true)
let rejectMark = FrameMark(decision: .reject)
