import Darwin
import Foundation
// sync <mountdir> <image> : does a new file's name and data reach the image without sync, after fsync, after F_FULLFSYNC?
let a = CommandLine.arguments
func inImage(_ needle: [UInt8]) -> Bool {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: a[2]), options: .alwaysMapped) else { return false }
    return data.range(of: Data(needle)) != nil
}
func utf16(_ s: String) -> [UInt8] { s.utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] } }
let dir = open(a[1], O_RDONLY | O_DIRECTORY)
for (label, action) in [("nothing", 0), ("fsync(file)", 1), ("F_FULLFSYNC(file)", 2), ("F_FULLFSYNC(file)+F_FULLFSYNC(dir)", 3)] {
    for nocache in [false, true] {
        let name = "SP\(action)\(nocache ? "N" : "C")\(Int.random(in: 100000...999999)).BIN"
        let payload = Array("PAYLOAD-\(name)-".utf8) + [UInt8](repeating: 0x5A, count: 4096 * 4 - 8 - name.utf8.count - 1)
        let fd = openat(dir, name, O_WRONLY | O_CREAT | O_EXCL, 0o644)
        if nocache { _ = fcntl(fd, F_NOCACHE, 1) }
        _ = payload.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        var rc: Int32 = 0
        if action == 1 { rc = fsync(fd) }
        if action >= 2 { rc = fcntl(fd, F_FULLFSYNC) }
        if action == 3 { rc |= fcntl(dir, F_FULLFSYNC) }
        let nameThere = inImage(utf16(name)), dataThere = inImage(Array("PAYLOAD-\(name)-".utf8))
        print("  after \(label), write \(nocache ? "F_NOCACHE" : "cached  "): rc \(rc), name on disk: \(nameThere), data on disk: \(dataThere)")
        close(fd)
    }
}
usleep(0)
