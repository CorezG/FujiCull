import Darwin
import Foundation

func err() -> String { "errno \(errno) (\(String(cString: strerror(errno))))" }
func report(_ name: String, _ rc: Int32) { print("  \(name): \(rc == 0 ? "ok" : "FAILED " + err())") }
let args = CommandLine.arguments
let mode = args[1]
let root = args[2]
let dir = open(root, O_RDONLY | O_DIRECTORY)
precondition(dir >= 0, "open dir: \(err())")

func volumeUUID(fd: Int32) -> String? {
    var attrs = attrlist()
    attrs.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
    attrs.volattr = attrgroup_t(ATTR_VOL_INFO) | attrgroup_t(ATTR_VOL_UUID)
    var buffer = [UInt8](repeating: 0, count: 64)
    guard fgetattrlist(fd, &attrs, &buffer, buffer.count, 0) == 0 else { print("  fgetattrlist: FAILED \(err())"); return nil }
    let bytes = Array(buffer[4..<20])
    return NSUUID(uuidBytes: bytes).uuidString
}
func pattern(_ count: Int, seed: UInt8) -> [UInt8] {
    var out = [UInt8](repeating: 0, count: count)
    var x: UInt32 = 0x9E37_79B9 &+ UInt32(seed)
    for i in 0..<count { x = x &* 1_664_525 &+ 1_013_904_223; out[i] = UInt8(truncatingIfNeeded: x >> 24) }
    let marker = Array("FUJICULL-PROBE-MARKER-\(seed)-".utf8)
    for offset in stride(from: 0, to: count - marker.count, by: 65_536) { out.replaceSubrange(offset..<(offset + marker.count), with: marker) }
    return out
}

switch mode {
case "identity":
    var fs = statfs()
    report("fstatfs", fstatfs(dir, &fs))
    let type = withUnsafePointer(to: &fs.f_fstypename) { $0.withMemoryRebound(to: CChar.self, capacity: 16) { String(cString: $0) } }
    let on = withUnsafePointer(to: &fs.f_mntonname) { $0.withMemoryRebound(to: CChar.self, capacity: 1024) { String(cString: $0) } }
    let from = withUnsafePointer(to: &fs.f_mntfromname) { $0.withMemoryRebound(to: CChar.self, capacity: 1024) { String(cString: $0) } }
    print("  fstypename \(type), mnton \(on), mntfrom \(from), fsid \(fs.f_fsid.val.0):\(fs.f_fsid.val.1), bsize \(fs.f_bsize), iosize \(fs.f_iosize)")
    print("  flags: rdonly \(fs.f_flags & UInt32(MNT_RDONLY) != 0), removable \(fs.f_flags & UInt32(MNT_REMOVABLE) != 0), local \(fs.f_flags & UInt32(MNT_LOCAL) != 0)")
    print("  fgetattrlist ATTR_VOL_UUID on the directory descriptor: \(volumeUUID(fd: dir) ?? "nil")")
    let v = try URL(fileURLWithPath: root).resourceValues(forKeys: [
        .volumeUUIDStringKey, .volumeIsRemovableKey, .volumeIsEjectableKey, .volumeIsInternalKey, .volumeIsLocalKey,
        .volumeIsReadOnlyKey, .volumeLocalizedFormatDescriptionKey, .volumeCreationDateKey, .volumeSupportsRenamingKey,
        .volumeSupportsExclusiveRenamingKey, .volumeSupportsSwapRenamingKey, .volumeSupportsHardLinksKey,
        .volumeSupportsExtendedSecurityKey, .volumeSupportsCasePreservedNamesKey, .volumeSupportsCaseSensitiveNamesKey,
        .volumeSupportsFileCloningKey, .volumeAvailableCapacityKey, .volumeNameKey,
    ])
    print("  URL: uuid \(v.volumeUUIDString ?? "nil"), removable \(v.volumeIsRemovable as Any), ejectable \(v.volumeIsEjectable as Any), internal \(v.volumeIsInternal as Any), readOnly \(v.volumeIsReadOnly as Any)")
    print("  URL: format \(v.volumeLocalizedFormatDescription ?? "nil"), created \(v.volumeCreationDate as Any), exclusiveRename \(v.volumeSupportsExclusiveRenaming as Any), swapRename \(v.volumeSupportsSwapRenaming as Any), caseSensitive \(v.volumeSupportsCaseSensitiveNames as Any)")

case "write":
    // 1. exclusive create, F_NOCACHE on the write descriptor, write, F_FULLFSYNC.
    let fd = openat(dir, "a.fujicull-partial", O_WRONLY | O_CREAT | O_EXCL, 0o644)
    report("openat O_CREAT|O_EXCL (new)", fd >= 0 ? 0 : -1)
    report("fcntl F_NOCACHE (write fd)", fcntl(fd, F_NOCACHE, 1))
    let data = pattern(8 * 1024 * 1024, seed: 1)
    let wrote = data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
    print("  write: \(wrote) bytes")
    report("fcntl F_FULLFSYNC (file)", fcntl(fd, F_FULLFSYNC))
    report("fsync (file)", fsync(fd))
    var times = [timespec(tv_sec: 1_700_000_000, tv_nsec: 123_456_789), timespec(tv_sec: 1_700_000_001, tv_nsec: 987_654_321)]
    report("futimens", futimens(fd, &times))
    close(fd)
    let again = openat(dir, "a.fujicull-partial", O_WRONLY | O_CREAT | O_EXCL, 0o644)
    print("  openat O_CREAT|O_EXCL (existing): \(again < 0 ? "refused, " + err() : "OPENED (bad)")")
    // 2. exclusive rename.
    report("renameatx_np RENAME_EXCL (target absent)", renameatx_np(dir, "a.fujicull-partial", dir, "A.BIN", UInt32(RENAME_EXCL)))
    let other = openat(dir, "b.tmp", O_WRONLY | O_CREAT | O_EXCL, 0o644); write(other, "x", 1); close(other)
    let rc = renameatx_np(dir, "b.tmp", dir, "A.BIN", UInt32(RENAME_EXCL))
    print("  renameatx_np RENAME_EXCL (target exists): \(rc == 0 ? "REPLACED (bad)" : "refused, " + err())")
    let rc2 = renameatx_np(dir, "b.tmp", dir, "a.bin", UInt32(RENAME_EXCL))
    print("  renameatx_np RENAME_EXCL (target exists, different case): \(rc2 == 0 ? "REPLACED (bad)" : "refused, " + err())")
    report("unlinkat b.tmp", unlinkat(dir, "b.tmp", 0))
    report("fcntl F_FULLFSYNC (directory)", fcntl(dir, F_FULLFSYNC))
    report("fsync (directory)", fsync(dir))
    var st = stat()
    report("fstatat A.BIN", fstatat(dir, "A.BIN", &st, 0))
    print("  size \(st.st_size), mtime \(st.st_mtimespec.tv_sec).\(st.st_mtimespec.tv_nsec), nlink \(st.st_nlink), flags \(st.st_flags)")
    // 3. case-insensitive directory create.
    report("mkdirat Trip", mkdirat(dir, "Trip", 0o755))
    let m = mkdirat(dir, "TRIP", 0o755)
    print("  mkdirat TRIP after Trip: \(m == 0 ? "CREATED (bad)" : "refused, " + err())")
    let s1 = mkdirat(dir, "Straße", 0o755), s2 = mkdirat(dir, "STRASSE", 0o755), s3 = mkdirat(dir, "STRAßE", 0o755)
    print("  mkdirat Straße \(s1 == 0), STRASSE \(s2 == 0 ? "created (distinct)" : "refused"), STRAßE \(s3 == 0 ? "created (distinct)" : "refused")")
    let e1 = mkdirat(dir, "Cafe\u{301}", 0o755), e2 = mkdirat(dir, "Caf\u{e9}", 0o755)
    print("  mkdirat Café decomposed \(e1 == 0), precomposed \(e2 == 0 ? "created (distinct)" : "refused, " + err())")
    print("  listing: \(try FileManager.default.contentsOfDirectory(atPath: root).sorted())")

case "read":
    for (label, nocache) in [("F_NOCACHE read", true), ("plain read", false)] {
        let fd = openat(dir, "A.BIN", O_RDONLY)
        if nocache { report("fcntl F_NOCACHE (read fd)", fcntl(fd, F_NOCACHE, 1)) }
        var buffer = [UInt8](repeating: 0, count: 8 * 1024 * 1024)
        let got = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
        close(fd)
        let expected = pattern(8 * 1024 * 1024, seed: 1)
        let differing = zip(buffer, expected).filter { $0 != $1 }.count
        print("  \(label): \(got) bytes, \(differing) bytes differ from what was written")
    }

case "tags":
    let url = URL(fileURLWithPath: root).appendingPathComponent("A.BIN")
    var values = URLResourceValues(); values.tagNames = ["Favourite"]
    var u = url
    do { try u.setResourceValues(values); print("  set tag: ok") } catch { print("  set tag: FAILED \(error)") }
    print("  read back: \(try URL(fileURLWithPath: url.path).resourceValues(forKeys: [.tagNamesKey]).tagNames ?? [])")
    let names = try FileManager.default.contentsOfDirectory(atPath: root).sorted()
    print("  listing (FileManager): \(names)")
    var all: [String] = []
    if let d = opendir(root) { while let e = readdir(d) { all.append(withUnsafePointer(to: &e.pointee.d_name) { $0.withMemoryRebound(to: CChar.self, capacity: 256) { String(cString: $0) } }) }; closedir(d) }
    print("  listing (readdir): \(all.sorted())")
    let x = listxattr(url.path, nil, 0, 0)
    var buf = [CChar](repeating: 0, count: max(Int(x), 1)); listxattr(url.path, &buf, buf.count, 0)
    print("  xattrs: \(String(decoding: buf.map { UInt8(bitPattern: $0) }, as: UTF8.self).split(separator: "\0"))")

case "trash":
    let fm = FileManager.default
    for round in 1...2 {
        let url = URL(fileURLWithPath: root).appendingPathComponent("T.JPG")
        fm.createFile(atPath: url.path, contents: Data("round \(round)".utf8))
        var values = URLResourceValues(); values.tagNames = ["Favourite"]; var u = url; try? u.setResourceValues(values)
        var result: NSURL?
        do { try fm.trashItem(at: url, resultingItemURL: &result); print("  trashItem \(round): ok -> \(result?.path ?? "nil")") } catch { print("  trashItem \(round): FAILED \(error)") }
        if let p = result?.path { print("     tags on trashed file: \((try? URL(fileURLWithPath: p).resourceValues(forKeys: [.tagNamesKey]).tagNames) ?? nil ?? [])") }
    }
    var all: [String] = []
    if let e = fm.enumerator(atPath: root) { for case let p as String in e { all.append(p) } }
    print("  everything on the volume: \(all.sorted())")
default: break
}
