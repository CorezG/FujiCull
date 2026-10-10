import Darwin
import Foundation
func pattern(_ count: Int, seed: UInt8) -> [UInt8] {
    var out = [UInt8](repeating: 0, count: count)
    var x: UInt32 = 0x9E37_79B9 &+ UInt32(seed)
    for i in 0..<count { x = x &* 1_664_525 &+ 1_013_904_223; out[i] = UInt8(truncatingIfNeeded: x >> 24) }
    let marker = Array("FUJICULL-PROBE-MARKER-\(seed)-".utf8)
    for offset in stride(from: 0, to: count - marker.count, by: 65_536) { out.replaceSubrange(offset..<(offset + marker.count), with: marker) }
    return out
}
let a = CommandLine.arguments
let size = 8 * 1024 * 1024
if a[1] == "write" {   // write <path> <seed> <nocache 0|1>
    let fd = open(a[2], O_WRONLY | O_CREAT | O_EXCL, 0o644); precondition(fd >= 0)
    if a[4] == "1" { precondition(fcntl(fd, F_NOCACHE, 1) == 0) }
    let data = pattern(size, seed: UInt8(a[3])!)
    precondition(data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) } == size)
    print("  wrote \(a[2].split(separator: "/").last!) nocache=\(a[4]) F_FULLFSYNC rc \(fcntl(fd, F_FULLFSYNC))")
    close(fd)
} else {               // read <path> <seed> <nocache 0|1>
    let fd = open(a[2], O_RDONLY); precondition(fd >= 0)
    if a[4] == "1" { precondition(fcntl(fd, F_NOCACHE, 1) == 0) }
    var buffer = [UInt8](repeating: 0, count: size)
    var got = 0
    while got < size { let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress! + got, min(1 << 20, size - got)) }; if n <= 0 { break }; got += n }
    close(fd)
    let expected = pattern(size, seed: UInt8(a[3])!)
    var counts: [UInt8: Int] = [:]
    for i in 0..<size where buffer[i] != expected[i] { counts[buffer[i], default: 0] += 1 }
    let desc = counts.isEmpty ? "identical to what was written (tampering NOT seen)" : "differs: " + counts.map { "\($0.value) bytes are '\(Character(UnicodeScalar($0.key)))'" }.joined(separator: ", ")
    print("  read \(a[2].split(separator: "/").last!) nocache=\(a[4]): \(got) bytes, \(desc)")
}
