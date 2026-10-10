import Darwin
import Foundation
let a = CommandLine.arguments
let size = 1024 * 1024 + 1234
if a[1] == "write" {
    let fd = open(a[2], O_WRONLY | O_CREAT | O_EXCL, 0o644); _ = fcntl(fd, F_NOCACHE, 1)
    var data = [UInt8](repeating: 0x41, count: size)
    data.replaceSubrange((size - 600)..<(size - 600 + 16), with: Array("TAILMARK-FUJICUL".utf8))
    data.replaceSubrange(4096..<(4096 + 16), with: Array("HEADMARK-FUJICUL".utf8))
    _ = data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
    print("  wrote \(size) bytes, F_FULLFSYNC rc \(fcntl(fd, F_FULLFSYNC))"); close(fd)
} else {
    let fd = open(a[2], O_RDONLY); _ = fcntl(fd, F_NOCACHE, 1)
    var b = [UInt8](repeating: 0, count: size); var got = 0
    while got < size { let n = b.withUnsafeMutableBytes { read(fd, $0.baseAddress! + got, size - got) }; if n <= 0 { break }; got += n }
    print("  head region after marker: '\(String(decoding: b[(4096+16)..<(4096+24)], as: UTF8.self))'  tail region after marker: '\(String(decoding: b[(size-600+16)..<(size-600+24)], as: UTF8.self))'  (A = as written, # = read from disk)")
}
