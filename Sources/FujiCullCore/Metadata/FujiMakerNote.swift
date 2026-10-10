import Foundation

/// Reads the film simulation from Fujifilm's MakerNote (R17; spike S2). ImageIO can't, because it needs the
/// whole file; this works on the first 64 KB that T0 already reads. Pure and bounds-checked.
///
/// Layout: "FUJIFILM", then a little-endian offset (from the start of the MakerNote) to an IFD whose
/// offsets are also relative to the MakerNote. Colour simulations are in FilmMode (0x1401); monochrome
/// ones have no FilmMode and are encoded in Saturation (0x1003). Values follow ExifTool's Fuji tables.
public enum FujiMakerNote {
    public struct Values: Equatable, Sendable {
        public let filmMode: Int?
        public let saturation: Int?
    }

    private static let colour: [Int: String] = [
        0x000: "Provia", 0x120: "Astia", 0x200: "Velvia", 0x400: "Velvia", 0x500: "Pro Neg. Std",
        0x501: "Pro Neg. Hi", 0x600: "Classic Chrome", 0x700: "Eterna", 0x800: "Classic Neg.",
        0x900: "Eterna Bleach Bypass", 0xA00: "Nostalgic Neg.", 0xB00: "Reala Ace",
    ]
    private static let monochrome: [Int: String] = [
        0x300: "Monochrome", 0x301: "Monochrome + R", 0x302: "Monochrome + Ye", 0x303: "Monochrome + G",
        0x310: "Sepia", 0x500: "Acros", 0x501: "Acros + R", 0x502: "Acros + Ye", 0x503: "Acros + G",
    ]

    /// The camera's name for the simulation, or nil when it isn't one FujiCull knows (shown as "—").
    public static func filmSimulation(filmMode: Int?, saturation: Int?) -> String? {
        if let filmMode { return colour[filmMode] }
        return saturation.flatMap { monochrome[$0] }
    }

    /// FilmMode and Saturation from a MakerNote, or nil if it isn't a readable Fuji one.
    public static func read(_ note: Data) -> Values? {
        let bytes = [UInt8](note)
        guard bytes.count >= 12, bytes[0..<8].elementsEqual(Array("FUJIFILM".utf8)),
            let ifd = u32(bytes, 8), let count = u16(bytes, ifd), count <= 500
        else { return nil }
        var filmMode: Int?
        var saturation: Int?
        for index in 0..<count {
            let entry = ifd + 2 + index * 12
            guard let tag = u16(bytes, entry), let type = u16(bytes, entry + 2) else { return nil }
            // Both tags are a single SHORT, stored inline in the entry's value field.
            guard type == 3 else { continue }
            switch tag {
            case 0x1401: filmMode = u16(bytes, entry + 8)
            case 0x1003: saturation = u16(bytes, entry + 8)
            default: break
            }
        }
        return Values(filmMode: filmMode, saturation: saturation)
    }

    private static func u16(_ bytes: [UInt8], _ at: Int) -> Int? {
        guard at >= 0, at + 2 <= bytes.count else { return nil }
        return Int(bytes[at]) | Int(bytes[at + 1]) << 8
    }

    private static func u32(_ bytes: [UInt8], _ at: Int) -> Int? {
        guard at >= 0, at + 4 <= bytes.count else { return nil }
        return Int(bytes[at]) | Int(bytes[at + 1]) << 8 | Int(bytes[at + 2]) << 16 | Int(bytes[at + 3]) << 24
    }
}

/// The EXIF line's pieces, as the camera would show them (R17), e.g. "1/1700 s", "f/8", "ISO 500", "23 mm",
/// "Classic Chrome". Missing values are left out; an unknown film simulation shows "—".
public enum ExifLine {
    public static func parts(_ exif: ExifSummary) -> [String] {
        var parts: [String] = []
        if let seconds = exif.exposureTime?.value {
            parts.append(seconds >= 0.3 ? "\(number(seconds)) s" : "1/\(Int((1 / seconds).rounded())) s")
        }
        if let fNumber = exif.fNumber { parts.append("f/\(number(fNumber))") }
        if let iso = exif.iso { parts.append("ISO \(iso)") }
        if let focalLength = exif.focalLength { parts.append("\(number(focalLength)) mm") }
        parts.append(exif.filmSimulation ?? "—")
        return parts
    }

    /// 8 → "8", 2.8 → "2.8", 7.5 → "7.5".
    private static func number(_ value: Double) -> String {
        String(format: "%g", value)
    }
}
