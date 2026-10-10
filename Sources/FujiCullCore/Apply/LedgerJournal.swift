import Foundation

/// A card's Apply journal on disk: `Ledger/<key>.jsonl`, one JSON record per line, append-only, forced to
/// the disk after every record (SR5, SR15). It is the only proof FujiCull has of which archive files it
/// wrote, so a record counts only once it is complete and durable.
public final class LedgerJournal: Sendable {
    public enum JournalError: Error, Equatable {
        /// A complete line that isn't a record. Apply stops and asks; the journal is not touched.
        case corrupt(line: Int)
        case io(String)
    }

    private let descriptor: Int32

    private init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    deinit { _ = close(descriptor) }

    /// Opens the journal, creating it if needed, and returns its records.
    ///
    /// A final line with no newline is a record that was being written when the app or the Mac stopped.
    /// It is cut back to the last complete line. This is the only time the journal is ever shortened.
    public static func open(at url: URL) throws(JournalError) -> (journal: LedgerJournal, records: [LedgerRecord]) {
        let existed = FileManager.default.fileExists(atPath: url.path)
        let descriptor = Darwin.open(url.path, O_RDWR | O_CREAT | O_APPEND | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else { throw .io("could not open \(url.path): errno \(errno)") }
        let journal = LedgerJournal(descriptor: descriptor)
        if !existed { try sync(url.deletingLastPathComponent().path) }

        var bytes = try journal.readAll()
        if let last = bytes.last, last != UInt8(ascii: "\n") {
            let complete = (bytes.lastIndex(of: UInt8(ascii: "\n")).map { $0 + 1 }) ?? 0
            guard ftruncate(descriptor, off_t(complete)) == 0 else {
                throw .io("could not repair the journal's last line")
            }
            try journal.sync()
            bytes = Data(bytes.prefix(complete))
        }

        var records: [LedgerRecord] = []
        let decoder = JSONDecoder()
        for (index, line) in bytes.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false).dropLast()
            .enumerated()
        {
            guard let record = try? decoder.decode(LedgerRecord.self, from: Data(line)) else {
                throw .corrupt(line: index + 1)
            }
            records.append(record)
        }
        return (journal, records)
    }

    /// Appends one record and forces it to the disk before returning.
    public func append(_ record: LedgerRecord) throws(JournalError) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard var line = try? encoder.encode(record) else { throw .io("could not encode a journal record") }
        line.append(UInt8(ascii: "\n"))
        // One write call: with O_APPEND the line lands whole at the end, or a crash leaves a torn tail
        // that the next open cuts off.
        let written = line.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
        guard written == line.count else { throw .io("could not write to the journal: errno \(errno)") }
        try sync()
    }

    private func readAll() throws(JournalError) -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1 << 16)
        var offset: off_t = 0
        while true {
            let count = pread(descriptor, &buffer, buffer.count, offset)
            guard count >= 0 else { throw .io("could not read the journal: errno \(errno)") }
            if count == 0 { return data }
            data.append(contentsOf: buffer[..<count])
            offset += off_t(count)
        }
    }

    private func sync() throws(JournalError) {
        guard fcntl(descriptor, F_FULLFSYNC) != -1 else { throw .io("could not sync the journal: errno \(errno)") }
    }

    private static func sync(_ path: String) throws(JournalError) {
        let descriptor = Darwin.open(path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else { throw .io("could not open \(path) to sync: errno \(errno)") }
        defer { _ = close(descriptor) }
        guard fcntl(descriptor, F_FULLFSYNC) != -1 else { throw .io("could not sync \(path): errno \(errno)") }
    }
}
