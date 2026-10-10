import Foundation
import os

@testable import FujiCullCore

/// The real file system, misbehaving on demand, so every failure path in Apply can be reached (DESIGN §9).
/// Calls are counted per operation, starting at 1.
final class FaultyFileSystem: FileSystem {
    enum Fault: Sendable {
        /// The nth call of this operation fails with `code`; nothing else is affected.
        case fail(FileOperation, call: Int, code: Int32)
        /// From the nth call of this operation on, every call of any kind fails with `EIO`: the drive was
        /// unplugged, or the app died. What is on disk afterwards is what a crash would leave.
        case die(FileOperation, call: Int)
        /// Every read from a file whose name contains this text comes back altered.
        case corruptReads(nameContains: String)
        /// Runs just before the nth call of this operation, e.g. to put a file in the way.
        case before(FileOperation, call: Int, @Sendable () -> Void)
        /// Runs just after the nth call of this operation succeeds.
        case after(FileOperation, call: Int, @Sendable () -> Void)
    }

    private struct State {
        var calls: [FileOperation: Int] = [:]
        var dead = false
    }

    private let base = LocalFileSystem()
    private let faults: [Fault]
    /// When set, the volume reports this much free space instead of the real figure.
    let freeBytes: Int64?
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(_ faults: Fault..., freeBytes: Int64? = nil) {
        self.faults = faults
        self.freeBytes = freeBytes
    }

    /// How many times `operation` has been called.
    func calls(_ operation: FileOperation) -> Int {
        state.withLock { $0.calls[operation] ?? 0 }
    }

    /// Counts the call, runs any "before" hook, and throws if a fault says this call fails.
    private func enter(_ operation: FileOperation, _ name: String) throws(FileSystemError) -> Int {
        let (call, dead) = state.withLock { state -> (Int, Bool) in
            let call = (state.calls[operation] ?? 0) + 1
            state.calls[operation] = call
            for case .die(operation, call) in faults { state.dead = true }
            return (call, state.dead)
        }
        if dead { throw FileSystemError(operation: operation, name: name, code: EIO) }
        for fault in faults {
            switch fault {
            case .before(operation, call, let hook): hook()
            case .fail(operation, call, let code): throw FileSystemError(operation: operation, name: name, code: code)
            default: break
            }
        }
        return call
    }

    private func leave(_ operation: FileOperation, _ call: Int) {
        for case .after(operation, call, let hook) in faults { hook() }
    }

    func openFolder(at path: String) throws(FileSystemError) -> OpenFolder {
        let call = try enter(.openFolder, path)
        let result = try base.openFolder(at: path)
        leave(.openFolder, call)
        return result
    }

    func openFolder(_ name: String, in folder: OpenFolder) throws(FileSystemError) -> OpenFolder {
        let call = try enter(.openFolder, name)
        let result = try base.openFolder(name, in: folder)
        leave(.openFolder, call)
        return result
    }

    func volumeUUID(of folder: OpenFolder) throws(FileSystemError) -> String? {
        let call = try enter(.volumeUUID, folder.path)
        let result = try base.volumeUUID(of: folder)
        leave(.volumeUUID, call)
        return result
    }

    func entry(_ name: String, in folder: OpenFolder) throws(FileSystemError) -> EntryInfo? {
        let call = try enter(.entry, name)
        let result = try base.entry(name, in: folder)
        leave(.entry, call)
        return result
    }

    func createExclusively(_ name: String, in folder: OpenFolder, uncached: Bool) throws(FileSystemError) -> OpenFile {
        let call = try enter(.create, name)
        let result = try base.createExclusively(name, in: folder, uncached: uncached)
        leave(.create, call)
        return result
    }

    func openForReading(_ path: String, in folder: OpenFolder) throws(FileSystemError) -> OpenFile {
        let call = try enter(.openForReading, path)
        let result = try base.openForReading(path, in: folder)
        leave(.openForReading, call)
        return result
    }

    func read(_ file: OpenFile, upTo count: Int) throws(FileSystemError) -> Data {
        let call = try enter(.read, file.name)
        var result = try base.read(file, upTo: count)
        for case .corruptReads(let text) in faults where file.name.contains(text) && !result.isEmpty {
            result[result.startIndex] ^= 0xFF
        }
        leave(.read, call)
        return result
    }

    func write(_ data: Data, to file: OpenFile) throws(FileSystemError) {
        let call = try enter(.write, file.name)
        try base.write(data, to: file)
        leave(.write, call)
    }

    func syncToDevice(_ file: OpenFile) throws(FileSystemError) {
        let call = try enter(.syncFile, file.name)
        try base.syncToDevice(file)
        leave(.syncFile, call)
    }

    func syncToDevice(_ folder: OpenFolder) throws(FileSystemError) {
        let call = try enter(.syncFolder, folder.path)
        try base.syncToDevice(folder)
        leave(.syncFolder, call)
    }

    func setModified(_ date: Date, of name: String, in folder: OpenFolder) throws(FileSystemError) {
        let call = try enter(.setModified, name)
        try base.setModified(date, of: name, in: folder)
        leave(.setModified, call)
    }

    func rename(_ name: String, to newName: String, in folder: OpenFolder) throws(FileSystemError) {
        let call = try enter(.rename, name)
        try base.rename(name, to: newName, in: folder)
        leave(.rename, call)
    }

    func remove(_ name: String, in folder: OpenFolder) throws(FileSystemError) {
        let call = try enter(.remove, name)
        try base.remove(name, in: folder)
        leave(.remove, call)
    }

    func createFolder(_ name: String, in folder: OpenFolder) throws(FileSystemError) {
        let call = try enter(.createFolder, name)
        try base.createFolder(name, in: folder)
        leave(.createFolder, call)
    }

    func names(in folder: OpenFolder) throws(FileSystemError) -> [String] {
        let call = try enter(.list, folder.path)
        let result = try base.names(in: folder)
        leave(.list, call)
        return result
    }

    func volumeSpace(of folder: OpenFolder) throws(FileSystemError) -> VolumeSpace {
        let call = try enter(.volumeSpace, folder.path)
        var result = try base.volumeSpace(of: folder)
        if let freeBytes { result = VolumeSpace(freeBytes: freeBytes, allocationSize: 4096) }
        leave(.volumeSpace, call)
        return result
    }

    func tags(of name: String, in folder: OpenFolder) throws(FileSystemError) -> Set<String> {
        let call = try enter(.readTags, name)
        let result = try base.tags(of: name, in: folder)
        leave(.readTags, call)
        return result
    }

    func setTags(_ tags: Set<String>, of name: String, in folder: OpenFolder) throws(FileSystemError) {
        let call = try enter(.writeTags, name)
        try base.setTags(tags, of: name, in: folder)
        leave(.writeTags, call)
    }

    /// A stand-in Trash: the file moves into `.TestTrash` inside its own folder, under a name that never
    /// collides. The real Trash is the user's; tests don't put files in it.
    func moveToTrash(_ name: String, in folder: OpenFolder) throws(FileSystemError) -> String? {
        let call = try enter(.trash, name)
        if try base.entry(".TestTrash", in: folder) == nil { try base.createFolder(".TestTrash", in: folder) }
        let leaf = name.split(separator: "/").last.map(String.init) ?? name
        let trashed = ".TestTrash/\(leaf) \(call)"
        try base.rename(name, to: trashed, in: folder)
        leave(.trash, call)
        return folder.path + "/" + trashed
    }
}
