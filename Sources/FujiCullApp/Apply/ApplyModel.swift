import AppKit
import FujiCullCore
import Observation

/// A drive Apply could archive to: external, writable, with a volume ID, and not the card itself.
struct ArchiveVolume: Identifiable, Hashable {
    let uuid: String
    let name: String
    let path: String
    let freeBytes: Int64

    var id: String { uuid }

    /// Every mounted volume that qualifies, and where each volume with an ID is mounted (SR7).
    static func mounted(excluding source: URL?) -> (candidates: [ArchiveVolume], roots: [String: String]) {
        let keys: Set<URLResourceKey> = [
            .volumeUUIDStringKey, .volumeIsInternalKey, .volumeIsReadOnlyKey, .volumeLocalizedNameKey,
            .volumeAvailableCapacityKey,
        ]
        var candidates: [ArchiveVolume] = []
        var roots: [String: String] = [:]
        let volumes =
            FileManager.default.mountedVolumeURLs(
                includingResourceValuesForKeys: Array(keys), options: [.skipHiddenVolumes]) ?? []
        for url in volumes {
            guard let values = try? url.resourceValues(forKeys: keys), let uuid = values.volumeUUIDString else {
                continue
            }
            roots[uuid] = url.path
            let isSource = url.standardizedFileURL == source?.standardizedFileURL
            guard values.volumeIsInternal != true, values.volumeIsReadOnly != true, !isSource,
                !SourceLocator.isCameraCard(url)
            else { continue }
            candidates.append(
                ArchiveVolume(
                    uuid: uuid, name: values.volumeLocalizedName ?? url.lastPathComponent, path: url.path,
                    freeBytes: Int64(values.volumeAvailableCapacity ?? 0)))
        }
        return (candidates.sorted { $0.name < $1.name }, roots)
    }
}

/// The Apply sheet's state: choose where, review the plan, copy, confirm, see what happened (R22–R27).
/// The work itself is `ApplyRun`'s; this only moves between screens and words the results.
@MainActor @Observable
final class ApplyModel {
    enum Stage {
        case setup
        case checking
        case preflight(ApplyRun.Preflight)
        case copying
        case confirming(ApplyRun.CopyReport, ApplyExecutor.Confirmation)
        case removing
        case summary(ApplySummary)
        case failed(String)
    }

    private(set) var stage: Stage = .setup
    var tripName: String
    var archiveUUID: String?
    private(set) var volumes: [ArchiveVolume] = []
    /// The owner's answers on the pre-flight screen.
    var addToExistingFolder = false
    var removeLeftovers = false
    private(set) var bytesDone: Int64 = 0
    private(set) var bytesTotal: Int64 = 0
    private(set) var copyStarted: Date?

    @ObservationIgnored private unowned let host: CullModel
    @ObservationIgnored private var run: ApplyRun?
    @ObservationIgnored private var roots: [String: String] = [:]
    @ObservationIgnored private var copyTask: Task<Void, Never>?
    @ObservationIgnored private var activity: NSObjectProtocol?
    private static let rememberedArchive = "archiveVolumeUUID"

    init(host: CullModel, suggestedTrip: String?, suggestedArchive: String?) {
        self.host = host
        tripName = suggestedTrip ?? ""
        refreshVolumes()
        let remembered = suggestedArchive ?? UserDefaults.standard.string(forKey: Self.rememberedArchive)
        archiveUUID = volumes.first { $0.uuid == remembered }?.uuid ?? (volumes.count == 1 ? volumes[0].uuid : nil)
    }

    var archive: ArchiveVolume? { volumes.first { $0.uuid == archiveUUID } }
    var cardName: String { host.sourceName }

    func refreshVolumes() {
        let mounted = ArchiveVolume.mounted(excluding: host.sourceVolumeURL)
        volumes = mounted.candidates
        roots = mounted.roots
    }

    /// Why the typed trip name can't be used, in words; nil when it is fine or still empty.
    var tripNameProblem: String? {
        guard !tripName.isEmpty else { return nil }
        switch TripName.problem(with: tripName) {
        case nil, .empty: return nil
        case .forbiddenCharacter: return "A folder name on the SSD can't contain \" * / : < > ? \\ |"
        case .startsOrEndsWithSpaceOrDot: return "The name can't start or end with a space or a full stop."
        case .reserved: return "That name is reserved by Windows and can't be used on the SSD."
        case .tooLong: return "The name is too long."
        }
    }

    var canReview: Bool { archive != nil && !tripName.isEmpty && TripName.problem(with: tripName) == nil }

    // MARK: Steps

    /// Reads the card and the archive, cleans up after any interrupted run, and plans this one.
    func review() async {
        guard let archive, canReview else { return }
        stage = .checking
        run = nil
        refreshVolumes()
        let destination = Ledger.Destination(volumeUUID: archive.uuid, folder: tripName)
        do {
            let setup = try await host.applySetup(destination: destination, archiveRoots: roots)
            let run = try await Task.detached { try ApplyRun(setup: setup) }.value
            self.run = run
            let preflight = try await run.preflight()
            addToExistingFolder = false
            removeLeftovers = false
            stage = .preflight(preflight)
        } catch {
            run = nil
            stage = .failed(Self.describe(error, card: cardName, archive: archive.name))
        }
    }

    func back() {
        run = nil
        stage = .setup
    }

    /// Whether Start can be pressed on the pre-flight screen.
    func canStart(_ preflight: ApplyRun.Preflight) -> Bool {
        preflight.plan.destinationState != .existsNotOurs || addToExistingFolder
    }

    func start() {
        guard case .preflight(let preflight) = stage, let run, let archive else { return }
        UserDefaults.standard.set(archive.uuid, forKey: Self.rememberedArchive)
        bytesDone = 0
        bytesTotal = preflight.copyBytes
        copyStarted = Date()
        stage = .copying
        // Keeps the Mac awake for the whole run (R23).
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled], reason: "Copying photos to the archive")
        let agreed = addToExistingFolder
        let clearLeftovers = removeLeftovers
        copyTask = Task {
            do {
                if clearLeftovers { try await run.removeStrayPartials() }
                let report = try await run.copy(
                    addToExistingFolder: agreed,
                    onProgress: { done, total in Task { @MainActor [weak self] in self?.progress(done, total) } })
                if let confirmation = report.confirmation {
                    stage = .confirming(report, confirmation)
                } else {
                    await finish(confirmed: false)
                }
            } catch {
                endActivity()
                self.run = nil
                stage = .failed(Self.describe(error, card: cardName, archive: archive.name))
            }
        }
    }

    private func progress(_ done: Int64, _ total: Int64) {
        guard case .copying = stage else { return }
        bytesDone = done
        bytesTotal = total
    }

    /// Stops after the file in progress has been cleaned up. Nothing is deleted.
    func cancelCopy() {
        copyTask?.cancel()
    }

    /// A drive went away: stop at once (R23). Any I/O in progress fails on its own as well.
    func volumeUnmounted() {
        if case .copying = stage { copyTask?.cancel() }
    }

    func finish(confirmed: Bool) async {
        guard let run else { return }
        stage = .removing
        let summary = await run.finish(confirmed: confirmed)
        let ledger = await run.ledger
        // Let go of the journal, the lock and the open folders, so the drives can be ejected.
        self.run = nil
        endActivity()
        await host.applyFinished(ledger: ledger)
        stage = .summary(summary)
    }

    private func endActivity() {
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
    }

    func close() {
        copyTask?.cancel()
        endActivity()
        run = nil
        host.endApply()
    }

    // MARK: After the run

    var tripFolder: URL? { archive.map { URL(fileURLWithPath: $0.path).appendingPathComponent(tripName) } }

    func reveal(_ subfolder: String? = nil) {
        guard var url = tripFolder else { return }
        if let subfolder { url.appendPathComponent(subfolder) }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Ejects the archive drive, which also flushes everything to it (SR20). Returns what went wrong, if anything.
    func ejectArchive() -> String? {
        guard let archive else { return nil }
        do {
            try NSWorkspace.shared.unmountAndEjectDevice(at: URL(fileURLWithPath: archive.path))
            refreshVolumes()
            return nil
        } catch {
            return "\(archive.name) couldn't be ejected: \(error.localizedDescription)"
        }
    }

    /// Closes the card in FujiCull, then ejects it.
    func ejectCard() async -> String? {
        guard let card = host.sourceVolumeURL else { return nil }
        let name = cardName
        await host.closeSource()
        do {
            try NSWorkspace.shared.unmountAndEjectDevice(at: card)
            return nil
        } catch {
            return "\(name) couldn't be ejected: \(error.localizedDescription)"
        }
    }

    /// The size on the card of the files a confirmation lists for deletion.
    func bytes(of paths: [String]) -> Int64 {
        let sizes = Dictionary(
            host.frames.flatMap { [$0.raf, $0.jpg].compactMap { $0 } }.map { ($0.relativePath, $0.size) },
            uniquingKeysWith: { first, _ in first })
        return paths.reduce(0) { $0 + (sizes[$1] ?? 0) }
    }

    // MARK: Words

    static func describe(_ error: Error, card: String, archive: String) -> String {
        switch error {
        case let start as ApplyRun.StartError:
            switch start {
            case .cardChanged:
                return
                    "\(card) has changed since you opened it. Close it, open it again, and check your decisions before applying."
            case .busy: return "Another Apply is already using this trip folder."
            case .stopped(let stop): return describe(stop, card: card, archive: archive)
            case .failed(let message): return message
            }
        case let stop as ApplyStop:
            switch stop {
            case .cancelled: return "Cancelled. Nothing was deleted."
            case .journal:
                return
                    "FujiCull's record of this card's earlier Apply runs can't be read or written. Nothing was changed."
            case .plan(.insufficientSpace(let needed, let available)):
                return
                    "\(archive) doesn't have enough room: this needs \(needed.formatted(.byteCount(style: .file))) and \(available.formatted(.byteCount(style: .file))) is free. Nothing was copied."
            case .plan(.sameVolume):
                return "The photos and the archive are on the same drive. Choose a different archive drive."
            case .plan(.invalidTripName): return "That trip name can't be used as a folder name on \(archive)."
            case .plan(.ambiguousNames(let names)):
                return
                    "The archive folder has files whose names differ only in capitals (\(names.joined(separator: ", "))). Rename one of them and try again."
            case .wrongCard: return "This isn't the card your decisions were made on."
            case .archiveNotConnected: return "\(archive) isn't connected."
            case .wrongArchive: return "The drive mounted as \(archive) isn't the archive that was chosen."
            case .destinationAppeared(let destination):
                return
                    "A folder called “\(destination.folder)” already exists on \(archive). Review again to decide whether to add to it."
            case .verificationFailed(let location):
                return
                    "\(location.name) didn't read back correctly from \(archive), so the run stopped. Nothing was deleted."
            case .io(let failure):
                return
                    "The run stopped because a file operation failed (\(failure.operation.rawValue), \(failure.name), error \(failure.code)). Nothing was deleted."
            case .gateClosed: return "Nothing was removed, because not every keeper is confirmed on the archive."
            }
        default: return error.localizedDescription
        }
    }
}
