/// A precomputed, numeric-aware, case-insensitive sort key: "IMG_9" < "IMG_10", "dscf0001" == "DSCF0001".
/// Built once per item so sorting thousands of frames never re-parses strings (DESIGN §5.1 performance).
struct NaturalSortKey: Comparable {
    private enum Chunk: Comparable {
        case number(value: UInt64, digits: Int)
        case text(String)

        static func < (lhs: Chunk, rhs: Chunk) -> Bool {
            switch (lhs, rhs) {
            case (.number(let a, let ad), .number(let b, let bd)): return a != b ? a < b : ad < bd
            case (.number, .text): return true
            case (.text, .number): return false
            case (.text(let a), .text(let b)): return a < b
            }
        }
    }

    private let chunks: [Chunk]

    init(_ string: String) {
        var chunks: [Chunk] = []
        var text = ""
        var digits = ""
        func flushText() {
            if !text.isEmpty { chunks.append(.text(text.lowercased())) }
            text = ""
        }
        func flushDigits() {
            // Runs longer than UInt64 can hold fall back to text order, which is still deterministic.
            if !digits.isEmpty {
                chunks.append(UInt64(digits).map { .number(value: $0, digits: digits.count) } ?? .text(digits))
            }
            digits = ""
        }
        for character in string {
            if character.isASCII, character.isNumber {
                flushText()
                digits.append(character)
            } else {
                flushDigits()
                text.append(character)
            }
        }
        flushText()
        flushDigits()
        self.chunks = chunks
    }

    static func < (lhs: NaturalSortKey, rhs: NaturalSortKey) -> Bool {
        lhs.chunks.lexicographicallyPrecedes(rhs.chunks)
    }
}
