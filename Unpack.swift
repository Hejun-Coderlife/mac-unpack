// 解压：把压缩包拖进来就解开（zip/7z/rar/tar/gz/xz/zst/iso…，加密包、分卷包、Windows 中文乱码都能处理）；拖进文件夹或普通文件就压成 zip
// 引擎是打包在 App 里的 7-Zip（Contents/Resources/7zz，命令行版），界面 SwiftUI
// 编译：./build.sh（只要命令行开发工具，不用 Xcode）
// 自测（不弹窗口）：UNPACK_TEST=压缩包1:压缩包2 [UNPACK_PW=密码] [UNPACK_DEST=目录] Contents/MacOS/Unpack
import SwiftUI
import QuickLook
import UniformTypeIdentifiers
import Security

// 界面语言跟随系统：系统首选语言是中文就显示中文，否则英文
let isZh = Locale.preferredLanguages.first?.hasPrefix("zh") ?? false
func L(_ zh: String, _ en: String) -> String { isZh ? zh : en }
let appName = L("解压", "Unpack")

func ui(_ f: @escaping () -> Void) { DispatchQueue.main.async(execute: f) }
func bytes(_ n: Int64) -> String { ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }

// ---- 设置（存在 UserDefaults，界面用 @AppStorage 读写同一批键）----
enum Pref {
    static let dest = "dest"             // 解压到哪：空 = 压缩包旁边
    static let trashAfter = "trashAfter" // 解完把压缩包（连同分卷）扔进废纸篓
    static let cleanJunk = "cleanJunk"   // 删掉 __MACOSX、.DS_Store、Thumbs.db 这类垃圾
    static let reveal = "reveal"         // 解完在访达里选中
    static let nestedTar = "nestedTar"   // .tar.gz 这类一次解到底
    static let quitAfter = "quitAfter"   // 双击压缩包打开时，全部解完自动退出
    static let rememberPw = "rememberPw" // 输对的密码记进密码本
    static func register() {
        UserDefaults.standard.register(defaults: [dest: "", trashAfter: false, cleanJunk: true, reveal: true,
                                                  nestedTar: true, quitAfter: true, rememberPw: true])
    }
    static func on(_ k: String) -> Bool { UserDefaults.standard.bool(forKey: k) }
}

// ---- 密码本：输对过的密码存在钥匙串里，遇到加密包先挨个自动试 ----
enum Passwords {
    private static let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                              kSecAttrService as String: "com.hejun.unpack",
                                              kSecAttrAccount as String: "passwords"]
    static func all() -> [String] {
        var q = base
        q[kSecReturnData as String] = true
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data,
              let list = try? JSONDecoder().decode([String].self, from: d) else { return [] }
        return list
    }
    static func save(_ list: [String]) {
        SecItemDelete(base as CFDictionary)
        guard !list.isEmpty, let d = try? JSONEncoder().encode(list) else { return }
        var q = base
        q[kSecValueData as String] = d
        SecItemAdd(q as CFDictionary, nil)
    }
    static func remember(_ p: String) {
        guard !p.isEmpty else { return }
        var list = all()
        list.removeAll { $0 == p }
        list.insert(p, at: 0)   // 最近用过的排前面，下次先试
        save(Array(list.prefix(100)))
    }
}

// ---- 压缩包里的一项 ----
struct Entry: Identifiable, Hashable {
    let id: Int
    let path: String       // 7-Zip 给的原始路径（选择性解压时原样传回去）
    let size: Int64
    let isDir: Bool
    let encrypted: Bool
}

struct Listing {
    var type = ""
    var entries: [Entry] = []
    var anyEncrypted: Bool { entries.contains { $0.encrypted } }
    var totalSize: Int64 { entries.reduce(0) { $0 + $1.size } }
}

enum ZError: Error {
    case needPassword, wrongPassword, missingVolume, notArchive, diskFull(String), cancelled, failed(String)
    var text: String {
        switch self {
        case .needPassword: return L("需要密码", "Password required")
        case .wrongPassword: return L("密码不对", "Wrong password")
        case .missingVolume: return L("缺分卷：把所有分卷放进同一个文件夹再试", "A volume is missing — put all parts in the same folder")
        case .notArchive: return L("不是压缩包，或者文件已损坏", "Not an archive, or the file is damaged")
        case .diskFull(let s): return s
        case .cancelled: return L("已取消", "Cancelled")
        case .failed(let s): return s
        }
    }
}

// ---- 调 7-Zip ----
final class Runner: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private(set) var cancelled = false
    func cancel() {
        lock.lock(); cancelled = true; let p = process; lock.unlock()
        if let p, p.isRunning { p.terminate() }
    }
    fileprivate func attach(_ p: Process) -> Bool {
        lock.lock(); defer { lock.unlock() }
        process = p
        return !cancelled
    }
}

enum SevenZip {
    static let bin: String = Bundle.main.path(forResource: "7zz", ofType: nil) ?? "/opt/homebrew/bin/7zz"
    // RAR 的解码器有版权限制，Homebrew 版 7-Zip 没带（能认出 rar 但解不了，报 Unsupported Method），RAR 交给 unar（The Unarchiver 的命令行版，LGPL）
    static let unar: String = Bundle.main.path(forResource: "unar", ofType: nil) ?? "/opt/homebrew/bin/unar"

    struct Result { var code: Int32; var out: String; var err: String; var all: String { out + "\n" + err } }

    /// 跑一次 7zz；onOut 收到标准输出的每一块（进度百分比在里面）
    static func run(_ args: [String], exe: String = bin, runner: Runner? = nil,
                    onOut: ((String) -> Void)? = nil, onErr: ((String) -> Void)? = nil) -> Result {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        // 从访达启动时没有 LANG，7-Zip 会按 C 区域处理文件名，中文全变问号——强制 UTF-8
        var env = ProcessInfo.processInfo.environment
        env["LANG"] = "en_US.UTF-8"; env["LC_ALL"] = "en_US.UTF-8"
        p.environment = env
        p.standardInput = FileHandle.nullDevice   // 万一 7-Zip 想问问题，直接读到空，不会卡住
        let outPipe = Pipe(), errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        let lock = NSLock()
        var out = Data(), err = Data()
        outPipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            guard !d.isEmpty else { return }
            lock.lock(); out.append(d); lock.unlock()
            if let onOut, let s = String(data: d, encoding: .utf8) { onOut(s) }
        }
        errPipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            lock.lock(); err.append(d); lock.unlock()
            if let onErr, !d.isEmpty, let s = String(data: d, encoding: .utf8) { onErr(s) }
        }
        if let runner, !runner.attach(p) { return Result(code: 255, out: "", err: "") }
        do { try p.run() } catch { return Result(code: -1, out: "", err: error.localizedDescription) }
        p.waitUntilExit()
        outPipe.fileHandleForReading.readabilityHandler = nil
        errPipe.fileHandleForReading.readabilityHandler = nil
        lock.lock()
        out.append(outPipe.fileHandleForReading.readDataToEndOfFile())
        err.append(errPipe.fileHandleForReading.readDataToEndOfFile())
        let r = Result(code: p.terminationStatus,
                       out: String(decoding: out, as: UTF8.self), err: String(decoding: err, as: UTF8.self))
        lock.unlock()
        return r
    }

    /// 把 7-Zip 的报错翻译成人话
    static func classify(_ r: Result, runner: Runner? = nil) -> ZError {
        if runner?.cancelled == true { return .cancelled }
        let s = r.all
        if s.contains("Wrong password") || s.contains("Incorrect passphrase") || s.contains("Failed! (Wrong password)") || s.contains("This archive requires a password") || s.contains("Passphrase required") { return .wrongPassword }
        if s.contains("Missing volume") || s.contains("There are some data after the end") && s.contains("volume") { return .missingVolume }
        if s.contains("Unexpected end of archive") { return .failed(L("压缩包不完整（没下载完，或缺分卷）", "The archive is incomplete (unfinished download or missing volume)")) }
        if s.contains("Cannot open the file as archive") || s.contains("Can not open the file as archive") { return .notArchive }
        if s.contains("No space left") || s.contains("not enough space") { return .diskFull(L("磁盘空间不够", "Not enough disk space")) }
        if s.contains("CRC Failed") || s.contains("Data Error") { return .failed(L("数据校验失败，压缩包可能已损坏", "Checksum failed — the archive may be damaged")) }
        let line = s.split(separator: "\n").first { $0.hasPrefix("ERROR") }.map(String.init)
        return .failed(line ?? L("解压失败（错误码 \(r.code)）", "Failed (code \(r.code))"))
    }

    static func list(_ arc: URL, password: String) -> Swift.Result<Listing, ZError> {
        let r = run(["l", "-slt", "-sccUTF-8", "-p" + password, arc.path])
        if r.code != 0 || r.all.contains("Wrong password") { return .failure(classify(r)) }
        return .success(parse(r.out))
    }

    /// 用最小的一个加密文件验证密码（不用把整个包解一遍）
    static func test(_ arc: URL, password: String, probe: Entry) -> Bool {
        let r = run(["t", "-spd", "-sccUTF-8", "-p" + password, arc.path, probe.path])
        if r.all.contains("Unsupported Method") {   // RAR：7-Zip 没有解码器，改用 unar 把这一个文件解到临时目录试
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("unpack-probe-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: dir) }
            let u = run(["-o", dir.path, "-f", "-D", "-nr", "-p", password, arc.path, probe.path], exe: unar)
            return u.code == 0 && !u.all.lowercased().contains("password")
        }
        return r.code == 0 && !r.all.contains("Wrong password")
    }

    /// 解析 `7zz l -slt`：头部是压缩包本身的属性，"----------" 之后每个空行分隔一项
    static func parse(_ out: String) -> Listing {
        var listing = Listing()
        let parts = out.components(separatedBy: "\n----------\n")
        for line in parts[0].split(separator: "\n") where line.hasPrefix("Type = ") {
            listing.type = String(line.dropFirst(7))
        }
        guard parts.count > 1 else { return listing }
        for block in parts.dropFirst().joined(separator: "\n").components(separatedBy: "\n\n") {
            var f: [String: String] = [:]
            for line in block.split(separator: "\n") {
                guard let r = line.range(of: " = ") else { continue }
                f[String(line[..<r.lowerBound])] = String(line[r.upperBound...])
            }
            guard let path = f["Path"], !path.isEmpty else { continue }
            listing.entries.append(Entry(id: listing.entries.count, path: path,
                                         size: Int64(f["Size"] ?? "") ?? 0,
                                         isDir: f["Folder"] == "+" || (f["Attributes"] ?? "").hasPrefix("D"),
                                         encrypted: f["Encrypted"] == "+"))
        }
        return listing
    }
}

// ---- 乱码修复 ----
// Windows 上做的 zip 用 GBK（日文 Shift-JIS、繁体 Big5）存文件名、又不打 UTF-8 标记，7-Zip 在 Mac 上会把这种名字解成有损的乱码，没法事后还原。
// 所以先从 zip 的中央目录读出原始字节判断真正的编码；是旧编码就改用系统自带的 bsdtar（libarchive）按这个编码解。
// （Mac 访达做的 zip 是 UTF-8 不打标记，7-Zip 自己能认对，不用管）
struct NameFixer {
    static let gbk = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
    static let big5 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.big5_HKSCS_1999.rawValue)))
    let encoding: String.Encoding?   // 需要按旧编码解时才有
    let charset: String?             // 传给 bsdtar 的 iconv 编码名
    let names: [String]              // 中央目录里按顺序的正确名字（和 7-Zip 列出的顺序一致）

    init(_ arc: URL) {
        let raw = NameFixer.rawNames(arc)
        let legacy = raw.filter { !$0.utf8Flag && $0.bytes.contains(where: { $0 > 127 }) }.map(\.bytes)
        let e = NameFixer.detect(legacy)
        guard let e, e != .utf8 else { encoding = nil; charset = nil; names = []; return }
        encoding = e
        charset = e == NameFixer.gbk ? "GB18030" : e == .shiftJIS ? "CP932" : "BIG5-HKSCS"
        names = raw.map { r in
            let n = String(data: r.bytes, encoding: r.utf8Flag ? .utf8 : e) ?? String(decoding: r.bytes, as: UTF8.self)
            return n.hasSuffix("/") ? String(n.dropLast()) : n
        }
    }

    /// 浏览内容时显示的名字
    func display(_ e: Entry, total: Int) -> String {
        names.count == total && names.indices.contains(e.id) ? names[e.id] : e.path
    }

    /// 按顺序读出 zip 中央目录里每一项的原始文件名字节，以及有没有打 UTF-8 标记
    static func rawNames(_ arc: URL) -> [(bytes: Data, utf8Flag: Bool)] {
        guard let fh = try? FileHandle(forReadingFrom: arc) else { return [] }
        defer { try? fh.close() }
        guard let size = try? fh.seekToEnd(), size > 22 else { return [] }
        let tailLen = min(size, 65_557)
        try? fh.seek(toOffset: size - tailLen)
        let tail = [UInt8](fh.readData(ofLength: Int(tailLen)))
        func u16(_ b: [UInt8], _ i: Int) -> Int { Int(b[i]) | Int(b[i + 1]) << 8 }
        func u32(_ b: [UInt8], _ i: Int) -> UInt64 { UInt64(u16(b, i)) | UInt64(u16(b, i + 2)) << 16 }
        func u64(_ b: [UInt8], _ i: Int) -> UInt64 { u32(b, i) | u32(b, i + 4) << 32 }
        guard tail.count >= 22, let eocd = stride(from: tail.count - 22, through: 0, by: -1).first(where: {
            tail[$0] == 0x50 && tail[$0 + 1] == 0x4b && tail[$0 + 2] == 5 && tail[$0 + 3] == 6
        }) else { return [] }
        var cdSize = u32(tail, eocd + 12), cdOff = u32(tail, eocd + 16)
        if cdOff == 0xFFFF_FFFF, eocd >= 20, tail[eocd - 20] == 0x50, tail[eocd - 19] == 0x4b, tail[eocd - 18] == 6, tail[eocd - 17] == 7 {
            // zip64：真正的目录位置记在 zip64 结尾记录里
            try? fh.seek(toOffset: u64(tail, eocd - 20 + 8))
            let z = [UInt8](fh.readData(ofLength: 56))
            guard z.count == 56 else { return [] }
            cdSize = u64(z, 40); cdOff = u64(z, 48)
        }
        guard cdSize < 64 << 20, cdOff + cdSize <= size else { return [] }
        try? fh.seek(toOffset: cdOff)
        let cd = [UInt8](fh.readData(ofLength: Int(cdSize)))
        var names: [(bytes: Data, utf8Flag: Bool)] = [], i = 0
        while i + 46 <= cd.count, cd[i] == 0x50, cd[i + 1] == 0x4b, cd[i + 2] == 1, cd[i + 3] == 2 {
            let flags = u16(cd, i + 8), n = u16(cd, i + 28), x = u16(cd, i + 30), c = u16(cd, i + 32)
            guard i + 46 + n <= cd.count else { break }
            let name = cd[(i + 46)..<(i + 46 + n)]
            names.append((Data(name), flags & 0x800 != 0))
            i += 46 + n + x + c
        }
        return names
    }

    /// 猜编码：UTF-8 → 简体 GBK（国标常用汉字区占多数）→ 日文 Shift-JIS → 繁体 Big5 → GB18030 兜底
    static func detect(_ names: [Data]) -> String.Encoding? {
        guard !names.isEmpty else { return nil }
        func all(_ e: String.Encoding) -> Bool { names.allSatisfy { String(data: $0, encoding: e) != nil } }
        if all(.utf8) { return .utf8 }
        var pairs = 0, common = 0
        for d in names {
            let b = [UInt8](d)
            var i = 0
            while i < b.count {
                if b[i] > 127, i + 1 < b.count {
                    pairs += 1
                    if (0xB0...0xF7).contains(b[i]) && b[i + 1] >= 0xA1 { common += 1 }
                    i += 2
                } else { i += 1 }
            }
        }
        if pairs > 0, Double(common) / Double(pairs) > 0.6, all(gbk) { return gbk }
        if all(.shiftJIS) { return .shiftJIS }
        if all(big5) { return big5 }
        return all(gbk) ? gbk : nil
    }
}

// ---- 认压缩包、找分卷 ----
enum Archive {
    static let exts: Set<String> = ["zip", "7z", "rar", "tar", "gz", "tgz", "bz2", "tbz", "tbz2", "xz", "txz", "zst", "tzst",
                                    "lz", "lzma", "tlz", "z", "taz", "cab", "iso", "arj", "lzh", "lha", "wim", "cpio",
                                    "rpm", "deb", "xar", "squashfs", "001", "zipx", "jar", "apk", "ipa", "vhd", "vhdx", "vmdk"]
    // 名字里的分卷写法：xxx.part3.rar / xxx.7z.002 / xxx.z01 / xxx.r00
    static let partRar = try! NSRegularExpression(pattern: #"^(.*)\.part(\d+)\.rar$"#, options: .caseInsensitive)
    static let numbered = try! NSRegularExpression(pattern: #"^(.*\.[a-z0-9]+)\.(\d{3})$"#, options: .caseInsensitive)
    static let zxx = try! NSRegularExpression(pattern: #"^(.*)\.z(\d{2})$"#, options: .caseInsensitive)
    static let rxx = try! NSRegularExpression(pattern: #"^(.*)\.r(\d{2})$"#, options: .caseInsensitive)

    static func groups(_ re: NSRegularExpression, _ s: String) -> [String]? {
        guard let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { return nil }
        return (1..<m.numberOfRanges).map { String(s[Range(m.range(at: $0), in: s)!]) }
    }

    static func isArchive(_ u: URL) -> Bool {
        var dir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: u.path, isDirectory: &dir), !dir.boolValue else { return false }
        let n = u.lastPathComponent
        return exts.contains(u.pathExtension.lowercased()) || [numbered, zxx, rxx].contains { groups($0, n) != nil }
    }

    /// 不管拖进来的是第几卷，都换成第一卷（7-Zip 要从第一卷开始读）
    static func firstVolume(_ u: URL) -> URL {
        let dir = u.deletingLastPathComponent(), n = u.lastPathComponent
        var cands: [String] = []
        if let g = groups(partRar, n) { cands.append(g[0] + ".part" + String(repeating: "0", count: g[1].count - 1) + "1.rar") }
        if let g = groups(numbered, n) { cands.append(g[0] + ".001") }
        if let g = groups(zxx, n) { cands.append(g[0] + ".zip") }
        if let g = groups(rxx, n) { cands.append(g[0] + ".rar") }
        for c in cands where FileManager.default.fileExists(atPath: dir.appendingPathComponent(c).path) {
            return dir.appendingPathComponent(c)
        }
        return u
    }

    /// 同一套分卷的全部文件（解完扔废纸篓时一起扔）
    static func volumes(_ first: URL) -> [URL] {
        let dir = first.deletingLastPathComponent(), n = first.lastPathComponent
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        var set: [String] = [n]
        if let g = groups(partRar, n) { set += files.filter { groups(partRar, $0)?[0] == g[0] } }
        if let g = groups(numbered, n) { set += files.filter { groups(numbered, $0)?[0] == g[0] } }
        if n.lowercased().hasSuffix(".zip") { let b = String(n.dropLast(4)); set += files.filter { groups(zxx, $0)?[0] == b } }
        if n.lowercased().hasSuffix(".rar"), groups(partRar, n) == nil { let b = String(n.dropLast(4)); set += files.filter { groups(rxx, $0)?[0] == b } }
        return Array(Set(set)).sorted().map { dir.appendingPathComponent($0) }
    }

    /// 压缩包去掉各种后缀后的名字，用来起文件夹名：照片.part1.rar → 照片，代码.tar.gz → 代码
    static func baseName(_ u: URL) -> String {
        var n = u.lastPathComponent
        if let g = groups(partRar, n) { return g[0] }
        if let g = groups(numbered, n) { n = g[0] }
        for _ in 0..<2 {
            let e = (n as NSString).pathExtension.lowercased()
            guard exts.contains(e) || e == "tar" else { break }
            n = (n as NSString).deletingPathExtension
        }
        return n.isEmpty ? L("解压", "Extracted") : n
    }
}

/// 同名已存在就加编号：资料 → 资料 2 → 资料 3
func uniqueURL(_ u: URL) -> URL {
    let fm = FileManager.default
    guard fm.fileExists(atPath: u.path) else { return u }
    let dir = u.deletingLastPathComponent(), ext = u.pathExtension, base = u.deletingPathExtension().lastPathComponent
    for i in 2... {
        let c = dir.appendingPathComponent(ext.isEmpty ? "\(base) \(i)" : "\(base) \(i).\(ext)")
        if !fm.fileExists(atPath: c.path) { return c }
    }
    return u
}

// 从网上下载的压缩包带「隔离」标记，解出来的文件也带上（和系统自带的归档实用工具一样），这样陌生程序第一次打开时系统照常检查
func copyQuarantine(from arc: URL, to root: URL) {
    let key = "com.apple.quarantine"
    let n = getxattr(arc.path, key, nil, 0, 0, 0)
    guard n > 0 else { return }
    var buf = [UInt8](repeating: 0, count: n)
    guard getxattr(arc.path, key, &buf, n, 0, 0) == n else { return }
    var all = [root]
    if let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) { all += e.compactMap { $0 as? URL } }
    for u in all { setxattr(u.path, key, buf, n, 0, XATTR_NOFOLLOW) }
}

// ---- 解压/压缩：找密码、解到隐藏的临时文件夹、修名字、去垃圾、拆 tar、放到最终位置 ----
enum Engine {
    /// 读出内容，并找到能用的密码：先用给定的，没给就从密码本里挨个试
    static func unlock(_ arc: URL, given: String?) -> Swift.Result<(Listing, String?), ZError> {
        var saved: [String]?
        func book() -> [String] { if saved == nil { saved = Passwords.all() }; return saved! }
        switch SevenZip.list(arc, password: given ?? "") {
        case .failure(.wrongPassword):   // 文件名也加密了（7z/rar 的「加密文件名」）
            if given != nil { return .failure(.wrongPassword) }
            for c in book() { if case .success(let l) = SevenZip.list(arc, password: c) { return .success((l, c)) } }
            return .failure(.needPassword)
        case .failure(let e): return .failure(e)
        case .success(let l):
            guard let probe = l.entries.filter({ $0.encrypted && !$0.isDir }).min(by: { $0.size < $1.size }) else {
                return .success((l, given))
            }
            if let g = given { return SevenZip.test(arc, password: g, probe: probe) ? .success((l, g)) : .failure(.wrongPassword) }
            for c in book() where SevenZip.test(arc, password: c, probe: probe) { return .success((l, c)) }
            return .failure(.needPassword)
        }
    }

    static var testDest: String?   // 自测时临时指定，不写进设置

    static func destDir(for src: URL) -> URL {
        let d = testDest ?? UserDefaults.standard.string(forKey: Pref.dest) ?? ""
        if !d.isEmpty, FileManager.default.isWritableFile(atPath: d) { return URL(fileURLWithPath: d) }
        let beside = src.deletingLastPathComponent()
        // 压缩包在只读的地方（挂载的光盘、别人共享的盘），就放到「下载」
        return FileManager.default.isWritableFile(atPath: beside.path) ? beside
            : FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
    }

    struct Progress: Sendable { var fraction: Double; var text: String }

    static func extract(_ arc: URL, password: String?, listing: Listing, selection: [String]?, runner: Runner,
                        progress: @escaping (Progress) -> Void) -> Swift.Result<URL, ZError> {
        let fm = FileManager.default
        let parent = destDir(for: arc)
        let need = selection == nil ? listing.totalSize
            : listing.entries.filter { selection!.contains($0.path) }.reduce(0) { $0 + $1.size }
        if let free = (try? parent.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage,
           free > 0, need > free {
            return .failure(.diskFull(L("磁盘空间不够：解开要 \(bytes(need))，只剩 \(bytes(free))", "Not enough space: needs \(bytes(need)), \(bytes(free)) free")))
        }
        let tmp = parent.appendingPathComponent(".解压中-\(UUID().uuidString.prefix(8))")
        defer { try? fm.removeItem(at: tmp) }
        do { try fm.createDirectory(at: tmp, withIntermediateDirectories: true) }
        catch { return .failure(.failed(L("没法在「\(parent.lastPathComponent)」里写文件", "Can't write to “\(parent.lastPathComponent)”"))) }

        let fixer = NameFixer(arc)
        let r: SevenZip.Result
        if listing.type.lowercased().hasPrefix("rar") {
            r = unarExtract(arc, into: tmp, password: password, need: need, selection: selection, runner: runner, progress: progress)
        } else if fixer.charset != nil, listing.type == "zip", fixer.names.count == listing.entries.count {
            r = bsdtar(arc, into: tmp, fixer: fixer, password: password, listing: listing, selection: selection, runner: runner, progress: progress)
        } else {
            r = sevenZipExtract(arc, into: tmp, password: password, need: need, selection: selection, runner: runner, progress: progress)
        }
        if r.code != 0 { return .failure(SevenZip.classify(r, runner: runner)) }

        if Pref.on(Pref.cleanJunk) { removeJunk(tmp) }
        var root = tmp
        // .tar.gz / .tgz：第一层只解出一个 .tar，接着把 tar 也解开
        var items = visible(root)
        if Pref.on(Pref.nestedTar), items.count == 1, items[0].pathExtension.lowercased() == "tar" {
            let inner = tmp.appendingPathComponent(".tar-\(UUID().uuidString.prefix(6))")
            try? fm.createDirectory(at: inner, withIntermediateDirectories: true)
            let size = sizeOf(items[0])
            let r2 = run7z(["x", "-y", "-bsp1", "-bso0", "-bse2", "-sccUTF-8", "-o" + inner.path, items[0].path],
                           total: size, label: L("解开 tar", "Unpacking tar"), runner: runner, progress: progress)
            if r2.code != 0 { return .failure(SevenZip.classify(r2, runner: runner)) }
            try? fm.removeItem(at: items[0])
            if Pref.on(Pref.cleanJunk) { removeJunk(inner) }
            root = inner
            items = visible(root)
        }
        if items.isEmpty { return .failure(.failed(L("压缩包是空的", "The archive is empty"))) }
        copyQuarantine(from: arc, to: root)

        // 放到最终位置：只有一个顶层文件夹/文件就直接放出来，零散的多个就装进以压缩包命名的文件夹
        do {
            let final: URL
            if items.count == 1 {
                final = uniqueURL(parent.appendingPathComponent(items[0].lastPathComponent))
                try fm.moveItem(at: items[0], to: final)
            } else {
                final = uniqueURL(parent.appendingPathComponent(Archive.baseName(arc)))
                try fm.createDirectory(at: final, withIntermediateDirectories: true)
                for u in items { try fm.moveItem(at: u, to: final.appendingPathComponent(u.lastPathComponent)) }
            }
            return .success(final)
        } catch {
            return .failure(.failed(error.localizedDescription))
        }
    }

    static func sevenZipExtract(_ arc: URL, into tmp: URL, password: String?, need: Int64, selection: [String]?, runner: Runner,
                                progress: @escaping (Progress) -> Void) -> SevenZip.Result {
        var args = ["x", "-y", "-bsp1", "-bso0", "-bse2", "-sccUTF-8", "-p" + (password ?? ""), "-o" + tmp.path, arc.path]
        var listFile: URL?
        if let selection {
            let lf = FileManager.default.temporaryDirectory.appendingPathComponent("unpack-\(UUID().uuidString).txt")
            try? selection.joined(separator: "\n").write(to: lf, atomically: true, encoding: .utf8)
            args += ["-spd", "-scsUTF-8", "@" + lf.path]
            listFile = lf
        }
        defer { if let listFile { try? FileManager.default.removeItem(at: listFile) } }
        return run7z(args, total: need, label: L("解压", "Extracting"), runner: runner, progress: progress)
    }

    /// RAR 交给 unar；它不报百分比，就每 0.3 秒量一下临时文件夹已经写了多大来算进度
    static func unarExtract(_ arc: URL, into tmp: URL, password: String?, need: Int64, selection: [String]?, runner: Runner,
                            progress: @escaping (Progress) -> Void) -> SevenZip.Result {
        var args = ["-o", tmp.path, "-f", "-D", "-nr", "-q"]   // -nr：不自动解包里的包，tar 由我们自己处理
        if let password, !password.isEmpty { args += ["-p", password] }
        args.append(arc.path)
        args += selection ?? []
        let start = Date()
        let timer = DispatchSource.makeTimerSource(queue: .global())
        timer.schedule(deadline: .now() + 0.3, repeating: 0.3)
        timer.setEventHandler {
            let done = sizeOf(tmp), t = Date().timeIntervalSince(start)
            guard need > 0, done > 0 else { return }
            let f = min(0.99, Double(done) / Double(need))
            var text = L("解压", "Extracting") + " \(Int(f * 100))%"
            if t > 0.8 {
                let speed = Double(done) / t
                text += " · \(bytes(Int64(speed)))/s · " + L("还剩 ", "") + duration(Double(need - done) / max(speed, 1)) + L("", " left")
            }
            progress(Progress(fraction: f, text: text))
        }
        timer.resume()
        defer { timer.cancel() }
        return SevenZip.run(args, exe: SevenZip.unar, runner: runner)
    }

    /// 旧编码文件名的 zip 交给系统的 bsdtar，按检测到的编码解名字；它没有百分比，按解出的条数算进度
    static func bsdtar(_ arc: URL, into tmp: URL, fixer: NameFixer, password: String?, listing: Listing, selection: [String]?,
                       runner: Runner, progress: @escaping (Progress) -> Void) -> SevenZip.Result {
        var args = ["-xvf", arc.path, "-C", tmp.path, "--options", "hdrcharset=" + fixer.charset!]
        if let password, !password.isEmpty { args += ["--passphrase", password] }
        var total = listing.entries.count
        if let selection {
            let pick = listing.entries.filter { selection.contains($0.path) }
            args += pick.map { fixer.names[$0.id] }
            total = pick.count
        }
        let lock = NSLock()
        var done = 0
        return SevenZip.run(args, exe: "/usr/bin/bsdtar", runner: runner, onErr: { chunk in
            lock.lock()
            done += chunk.split(separator: "\n").filter { $0.hasPrefix("x ") }.count
            let f = min(1, Double(done) / Double(max(total, 1)))
            lock.unlock()
            progress(Progress(fraction: f, text: L("解压", "Extracting") + " \(Int(f * 100))% · " + L("按 \(fixer.charset!) 编码修正文件名", "decoding names as \(fixer.charset!)")))
        })
    }

    static func compress(_ srcs: [URL], runner: Runner, progress: @escaping (Progress) -> Void) -> Swift.Result<URL, ZError> {
        let parent = destDir(for: srcs[0])
        let name = srcs.count == 1 ? srcs[0].lastPathComponent : L("归档", "Archive")
        let out = uniqueURL(parent.appendingPathComponent(name + ".zip"))
        let total = srcs.reduce(Int64(0)) { $0 + sizeOf($1) }
        // -mcu=on：文件名一律存 UTF-8 并打标记，发到 Windows 上也不乱码；不带 Mac 的 .DS_Store 和 ._ 资源文件
        let args = ["a", "-tzip", "-mcu=on", "-mx=5", "-bsp1", "-bso0", "-bse2", "-sccUTF-8",
                    "-xr!.DS_Store", "-xr!__MACOSX", "-xr!._*", out.path] + srcs.map(\.path)
        let r = run7z(args, total: total, label: L("压缩", "Compressing"), runner: runner, progress: progress)
        if r.code != 0 { try? FileManager.default.removeItem(at: out); return .failure(SevenZip.classify(r, runner: runner)) }
        return .success(out)
    }

    static let pctRegex = try! NSRegularExpression(pattern: #"(\d+)%"#)

    /// 跑 7zz 并把输出里的百分比换算成进度、速度、剩余时间
    static func run7z(_ args: [String], total: Int64, label: String, runner: Runner, progress: @escaping (Progress) -> Void) -> SevenZip.Result {
        let start = Date()
        var last = -1
        return SevenZip.run(args, runner: runner, onOut: { chunk in
            let nums = pctRegex.matches(in: chunk, range: NSRange(chunk.startIndex..., in: chunk)).compactMap { Int((chunk as NSString).substring(with: $0.range(at: 1))) }
            guard let pct = nums.last, pct != last else { return }
            last = pct
            let t = Date().timeIntervalSince(start)
            var text = "\(label) \(pct)%"
            if pct >= 2, t > 0.8, total > 0 {
                let speed = Double(total) * Double(pct) / 100 / t
                let left = t * Double(100 - pct) / Double(pct)
                text += " · \(bytes(Int64(speed)))/s · " + L("还剩 ", "") + duration(left) + L("", " left")
            }
            progress(Progress(fraction: Double(pct) / 100, text: text))
        })
    }

    static func duration(_ s: Double) -> String {
        let s = Int(s.rounded(.up))
        if s < 60 { return L("\(s) 秒", "\(s)s") }
        return L("\(s / 60) 分 \(s % 60) 秒", "\(s / 60)m \(s % 60)s")
    }

    static func sizeOf(_ u: URL) -> Int64 {
        guard let e = FileManager.default.enumerator(at: u, includingPropertiesForKeys: [.fileSizeKey]) else {
            return Int64((try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        var n = Int64((try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        for case let f as URL in e { n += Int64((try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        return n
    }

    static let junk: Set<String> = ["__MACOSX", ".DS_Store", "Thumbs.db", "desktop.ini", "ehthumbs.db"]
    static func removeJunk(_ root: URL) {
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return }
        var kill: [URL] = []
        for case let u as URL in e {
            let n = u.lastPathComponent
            if junk.contains(n) || n.hasPrefix("._") { kill.append(u); if n == "__MACOSX" { e.skipDescendants() } }
        }
        kill.forEach { try? FileManager.default.removeItem(at: $0) }
    }

    static func visible(_ dir: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { !$0.lastPathComponent.hasPrefix(".tar-") }   // 拆 tar 用的临时夹不算
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}

// ---- 一个任务（一个压缩包，或者一批要压缩的文件）----
final class Job: ObservableObject, Identifiable {
    enum Kind { case extract, compress }
    enum State { case waiting, working, needPassword, done, failed }
    let id = UUID()
    let kind: Kind
    let sources: [URL]
    let selection: [String]?   // 只解其中几项（从「查看内容」里勾的）
    @Published var state = State.waiting
    @Published var fraction = 0.0
    @Published var detail = ""
    @Published var result: URL?
    @Published var wrongPassword = false
    var password: String?
    var listing: Listing?
    private var runner = Runner()

    init(kind: Kind, sources: [URL], selection: [String]? = nil, password: String? = nil) {
        self.kind = kind; self.sources = sources; self.selection = selection; self.password = password
    }

    var title: String {
        switch kind {
        case .extract: return sources[0].lastPathComponent + (selection.map { L("（选中 \($0.count) 项）", " (\($0.count) selected)") } ?? "")
        case .compress: return sources.count == 1 ? sources[0].lastPathComponent : L("\(sources.count) 个项目", "\(sources.count) items")
        }
    }
    var volumeCount: Int { kind == .extract ? Archive.volumes(sources[0]).count : 0 }

    func cancel() { runner.cancel() }

    /// 在后台线程跑完整个任务（由队列调用）
    func execute() {
        runner = Runner()
        let runner = runner
        let report: (Engine.Progress) -> Void = { p in ui { self.fraction = p.fraction; self.detail = p.text } }
        switch kind {
        case .compress:
            ui { self.detail = L("准备压缩…", "Preparing…") }
            finish(Engine.compress(sources, runner: runner, progress: report))
        case .extract:
            let arc = sources[0]
            ui { self.detail = L("读取内容…", "Reading…") }
            let typed = password
            switch Engine.unlock(arc, given: typed) {
            case .failure(let e) where e.isPassword:
                ui {
                    self.state = .needPassword
                    self.wrongPassword = typed != nil
                    self.password = nil
                    self.detail = ""
                }
                return
            case .failure(let e):
                finish(.failure(e))
            case .success(let (listing, pw)):
                self.listing = listing
                self.password = pw
                if let typed, typed == pw, Pref.on(Pref.rememberPw) { Passwords.remember(typed) }
                finish(Engine.extract(arc, password: pw, listing: listing, selection: selection, runner: runner, progress: report))
            }
        }
    }

    private func finish(_ r: Swift.Result<URL, ZError>) {
        ui {
            switch r {
            case .success(let u):
                self.state = .done
                self.result = u
                self.fraction = 1
                self.detail = L("已放到「\(u.deletingLastPathComponent().lastPathComponent)」里：\(u.lastPathComponent)",
                                "Saved to “\(u.deletingLastPathComponent().lastPathComponent)”: \(u.lastPathComponent)")
                if self.kind == .extract, self.selection == nil, Pref.on(Pref.trashAfter) {
                    NSWorkspace.shared.recycle(Archive.volumes(self.sources[0]))
                }
                if Pref.on(Pref.reveal) { NSWorkspace.shared.activateFileViewerSelecting([u]) }
            case .failure(let e):
                self.state = .failed
                self.detail = e.text
            }
        }
    }
}

extension ZError {
    var isPassword: Bool { if case .needPassword = self { return true }; if case .wrongPassword = self { return true }; return false }
}

// ---- 任务队列：一次只跑一个（7-Zip 自己会用满多核）----
final class JobQueue: ObservableObject {
    static let shared = JobQueue()
    @Published var jobs: [Job] = []
    private let work = DispatchQueue(label: "unpack.work", qos: .userInitiated)
    var openedByFinder = false

    func add(_ urls: [URL]) {
        var loose: [URL] = []
        for u in urls {
            if Archive.isArchive(u) {
                let first = Archive.firstVolume(u)
                // 一套分卷一起拖进来时只算一个任务
                if jobs.contains(where: { $0.kind == .extract && $0.selection == nil && $0.sources[0] == first && $0.state != .done && $0.state != .failed }) { continue }
                jobs.append(Job(kind: .extract, sources: [first]))
            } else {
                loose.append(u)
            }
        }
        if !loose.isEmpty { jobs.append(Job(kind: .compress, sources: loose)) }
        pump()
    }

    func add(_ job: Job) { jobs.append(job); pump() }

    func retry(_ job: Job, password: String? = nil) {
        job.password = password
        job.wrongPassword = false
        job.state = .waiting
        job.fraction = 0
        pump()
    }

    func remove(_ job: Job) { job.cancel(); jobs.removeAll { $0.id == job.id } }
    func clearFinished() { jobs.removeAll { $0.state == .done } }

    func pump() {
        updateDock()
        guard !jobs.contains(where: { $0.state == .working }),
              let next = jobs.first(where: { $0.state == .waiting }) else { maybeQuit(); return }
        next.state = .working
        next.fraction = 0
        work.async {
            next.execute()
            ui { self.pump() }
        }
    }

    private func updateDock() {
        let busy = jobs.filter { $0.state == .working || $0.state == .waiting }.count
        NSApp?.dockTile.badgeLabel = busy > 0 ? "\(busy)" : nil
    }

    // 双击压缩包打开、而且全部顺利解完：自动退出（设置里打开才这样）
    private func maybeQuit() {
        guard openedByFinder, Pref.on(Pref.quitAfter), !jobs.isEmpty, jobs.allSatisfy({ $0.state == .done }) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { NSApp.terminate(nil) }
    }

    /// 退出时停掉正在跑的 7-Zip（临时文件夹由各任务自己清掉）
    func cancelAll() { jobs.forEach { $0.cancel() } }
}

// ---- App ----
final class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        JobQueue.shared.openedByFinder = true
        JobQueue.shared.add(urls)
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) {
        JobQueue.shared.cancelAll()
        Thread.sleep(forTimeInterval: 0.3)
    }
    // 访达右键 → 服务 →「用解压处理」
    @objc func unpackFiles(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let urls = (pboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        NSApp.activate(ignoringOtherApps: true)
        JobQueue.shared.add(urls)
    }
}

@main
struct UnpackApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    init() {
        Pref.register()
        if let t = ProcessInfo.processInfo.environment["UNPACK_TEST"] { selfTest(t) }
    }
    var body: some Scene {
        Window(appName, id: "main") {
            ContentView().frame(minWidth: 520, minHeight: 440)
        }
        .windowStyle(.hiddenTitleBar)   // 像 Typora：不要标题栏，整窗就是一页纸
        .defaultSize(width: 640, height: 560)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button(L("打开…", "Open…")) { pickFiles() }.keyboardShortcut("o")
            }
        }
    }
}

func pickFiles() {
    let p = NSOpenPanel()
    p.allowsMultipleSelection = true
    p.canChooseDirectories = true
    p.message = L("选压缩包解开；选文件夹或普通文件则压成 zip", "Choose archives to extract, or folders/files to zip")
    if p.runModal() == .OK { JobQueue.shared.add(p.urls) }
}

/// 自测：不开窗口，直接解，把结果打到标准输出
func selfTest(_ list: String) {
    let env = ProcessInfo.processInfo.environment
    Engine.testDest = env["UNPACK_DEST"]
    if let p = env["UNPACK_SAVE"] { Passwords.remember(p) }   // 先往密码本里存一个，测自动试密码
    for path in list.split(separator: ":") {
        let u = URL(fileURLWithPath: String(path))
        if !Archive.isArchive(u) {
            let r = Engine.compress([u], runner: Runner()) { _ in }
            print("COMPRESS \(u.lastPathComponent) →", (try? r.get().path) ?? "\(r)")
            continue
        }
        let arc = Archive.firstVolume(u)
        let fixer = NameFixer(arc)
        switch Engine.unlock(arc, given: env["UNPACK_PW"]) {
        case .failure(let e): print("FAIL \(u.lastPathComponent): \(e.text)")
        case .success(let (l, pw)):
            print("LIST \(arc.lastPathComponent) type=\(l.type) n=\(l.entries.count) pw=\(pw ?? "-") enc=\(fixer.charset ?? "-")")
            for e in l.entries.prefix(5) { print("   ", fixer.display(e, total: l.entries.count)) }
            let r = Engine.extract(arc, password: pw, listing: l, selection: nil, runner: Runner()) { _ in }
            switch r {
            case .success(let out): print("OK → \(out.path)")
            case .failure(let e): print("FAIL extract: \(e.text)")
            }
        }
    }
    exit(0)
}

// ---- 界面：仿 Typora（GitHub 主题）——白纸页面、正文排版、文字链接代替按钮、底部细状态栏；深色模式用它 Night 主题的配色 ----
enum Theme {
    static func hex(_ v: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat(v >> 16 & 0xFF) / 255, green: CGFloat(v >> 8 & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }
    static func dyn(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { a in a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? hex(dark) : hex(light) })
    }
    static let bg = dyn(0xFFFFFF, 0x363B40)
    static let text = dyn(0x333333, 0xB8BFC6)
    static let heading = dyn(0x222222, 0xE6E6E6)
    static let secondary = dyn(0x777777, 0x8B939B)
    static let faint = dyn(0xAAAAAA, 0x666D74)
    static let rule = dyn(0xEEEEEE, 0x474D54)
    static let quoteBar = dyn(0xDFE2E5, 0x575E66)
    static let link = dyn(0x4183C4, 0x7FB2E8)
    static let error = dyn(0xC7254E, 0xE8899A)
    static let ok = dyn(0x4E9A5B, 0x8CC796)
    static let bar = dyn(0xF8F8F8, 0x2E3236)
}

/// 细分割线
struct Rule: View {
    var body: some View { Rectangle().fill(Theme.rule).frame(height: 1) }
}

/// 蓝色文字链接（悬停加下划线、变手形）
struct LinkButton: View {
    let title: String
    var color = Theme.link
    let action: () -> Void
    @State private var hover = false
    @Environment(\.isEnabled) private var enabled
    var body: some View {
        Button(action: action) { Text(title).underline(hover && enabled) }
            .buttonStyle(.plain)
            .foregroundStyle(enabled ? color : Theme.faint)
            .onHover { h in
                hover = h
                (h && enabled ? NSCursor.pointingHand : NSCursor.arrow).set()
            }
    }
}

/// 链接之间的「·」
struct Dot: View { var body: some View { Text("·").foregroundStyle(Theme.faint) } }

/// 正文里能点的 [文字](unpack://open) 链接
func para(_ md: String) -> Text {
    var s = (try? AttributedString(markdown: md)) ?? AttributedString(md)
    for run in s.runs where run.link != nil { s[run.range].foregroundColor = Theme.link }
    return Text(s)
}

struct ContentView: View {
    @ObservedObject var queue = JobQueue.shared
    @State private var targeted = false
    @State private var browsing: Job?

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            VStack(spacing: 0) {
                if queue.jobs.isEmpty { Intro() } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(appName).font(.system(size: 30, weight: .bold)).foregroundStyle(Theme.heading)
                            .padding(.bottom, 10)
                        Rule().padding(.bottom, 18)
                        do {
                            para(L("继续把压缩包拖进来，或者 [选择文件](unpack://open)。", "Drop more archives, or [choose files](unpack://open)."))
                                .font(.system(size: 14)).foregroundStyle(Theme.secondary).padding(.bottom, 6)
                            ForEach(queue.jobs) { JobRow(job: $0, browse: { browsing = $0 }) }
                        }
                    }
                    .frame(maxWidth: 600, alignment: .leading)
                    .padding(.horizontal, 44).padding(.top, 46).padding(.bottom, 28)
                    .frame(maxWidth: .infinity)
                }
                .scrollContentBackground(.hidden)
                }
                StatusBar()
            }
            if targeted { DropOverlay().transition(.opacity) }
        }
        .foregroundStyle(Theme.text)
        .environment(\.openURL, OpenURLAction { url in
            if url.scheme == "unpack" { pickFiles(); return .handled }
            return .systemAction
        })
        .dropDestination(for: URL.self) { urls, _ in
            queue.add(urls); return !urls.isEmpty
        } isTargeted: { t in withAnimation(.easeOut(duration: 0.15)) { targeted = t } }
        .sheet(item: $browsing) { BrowserView(job: $0) }
        .onChange(of: queue.jobs.count) { _, n in   // 自测截图用：UNPACK_BROWSE=1 时自动打开第一个包的内容
            if n > 0, browsing == nil, ProcessInfo.processInfo.environment["UNPACK_BROWSE"] != nil { browsing = queue.jobs.first }
        }
    }
}

/// 空窗口：和宣传视频结尾那张卡一样——图标 + 名字 + 一句话。格式、密码、乱码这些都是自动的，不用在这里讲
struct Intro: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 22) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 84, height: 84)
                VStack(alignment: .leading, spacing: 0) {
                    Text(appName).font(.system(size: 34, weight: .semibold)).foregroundStyle(Theme.heading).padding(.bottom, 6)
                    Rule().frame(width: 200).padding(.bottom, 10)
                    Text(L("拖进来，就解开。", "Drop it in. It opens.")).font(.system(size: 15, weight: .medium)).padding(.bottom, 6)
                    Text(L("zip · 7z · rar · 分卷 · 加密包 · 乱码修复", "zip · 7z · rar · split · encrypted · garbled names"))
                        .font(.system(size: 11)).foregroundStyle(Theme.faint)
                }
            }
            para(L("[选择文件](unpack://open)　⌘O", "[Choose a file](unpack://open)　⌘O"))
                .font(.system(size: 13)).foregroundStyle(Theme.faint)
                .padding(.leading, 84 + 22)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct DropOverlay: View {
    var body: some View {
        ZStack {
            Theme.bg.opacity(0.94).ignoresSafeArea()
            RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.link.opacity(0.5), lineWidth: 2).padding(14)
            VStack(spacing: 8) {
                Text(L("松手即可", "Release to unpack")).font(.system(size: 26, weight: .bold)).foregroundStyle(Theme.heading)
                Text(L("压缩包会被解开，文件夹会被压成 zip", "Archives are extracted, folders are zipped"))
                    .font(.system(size: 14)).foregroundStyle(Theme.secondary)
            }
        }
        .allowsHitTesting(false)
    }
}

struct JobRow: View {
    @ObservedObject var job: Job
    let browse: (Job) -> Void
    @State private var pw = ""
    @State private var shake = 0
    @State private var hover = false
    @AppStorage(Pref.rememberPw) private var remember = true

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: job.sources[0].path))
                .resizable().frame(width: 22, height: 22).padding(.top, 1)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(job.title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.heading)
                        .lineLimit(1).truncationMode(.middle)
                    if job.volumeCount > 1 { Text(L("\(job.volumeCount) 卷", "\(job.volumeCount) parts")).foregroundStyle(Theme.faint) }
                    if job.kind == .compress { Text(L("→ zip", "→ zip")).foregroundStyle(Theme.faint) }
                    Spacer(minLength: 0)
                    if hover && job.state != .working {
                        LinkButton(title: L("移除", "Remove"), color: Theme.faint) { withAnimation { JobQueue.shared.remove(job) } }
                            .font(.system(size: 12))
                    }
                }
                .font(.system(size: 13))
                status.font(.system(size: 13))
                if job.state == .working { ThinProgress(value: job.fraction).padding(.top, 2) }
            }
        }
        .padding(.vertical, 14)
        .overlay(alignment: .bottom) { Rule() }
        .contentShape(Rectangle())
        .onHover { hover = $0 }
    }

    @ViewBuilder var status: some View {
        switch job.state {
        case .waiting:
            Text(L("排队中", "Waiting")).foregroundStyle(Theme.secondary)
        case .working:
            HStack(spacing: 6) {
                Text(job.detail).monospacedDigit().foregroundStyle(Theme.secondary)
                Dot()
                LinkButton(title: L("取消", "Cancel")) { JobQueue.shared.remove(job) }
            }
        case .needPassword:
            VStack(alignment: .leading, spacing: 8) {
                Text(job.wrongPassword ? L("密码不对，再试一次。", "Wrong password, try again.")
                     : L("这个包加了密码，存过的密码都不对。", "This archive is encrypted and no saved password fits."))
                    .foregroundStyle(job.wrongPassword ? Theme.error : Theme.secondary)
                HStack(spacing: 12) {
                    VStack(spacing: 3) {
                        SecureField(L("输入密码", "Password"), text: $pw)
                            .textFieldStyle(.plain).font(.system(size: 14)).onSubmit(submit)
                        Rectangle().fill(Theme.quoteBar).frame(height: 1)
                    }
                    .frame(width: 200)
                    .modifier(Shake(amount: CGFloat(shake)))
                    Toggle(L("记住", "Remember"), isOn: $remember).toggleStyle(.checkbox).foregroundStyle(Theme.secondary)
                    LinkButton(title: L("解开", "Unlock"), action: submit).disabled(pw.isEmpty)
                }
            }
            .onChange(of: job.wrongPassword) { _, wrong in if wrong { withAnimation(.default) { shake += 1 } } }
        case .done:
            HStack(spacing: 6) {
                Text("✓").foregroundStyle(Theme.ok)
                Text(job.detail).foregroundStyle(Theme.secondary).lineLimit(1).truncationMode(.middle)
                Dot()
                LinkButton(title: L("在访达中显示", "Show in Finder")) {
                    if let r = job.result { NSWorkspace.shared.activateFileViewerSelecting([r]) }
                }.fixedSize()
                if job.kind == .extract, job.selection == nil {
                    Dot()
                    LinkButton(title: L("查看内容", "Contents")) { browse(job) }.fixedSize()
                }
            }
        case .failed:
            VStack(alignment: .leading, spacing: 6) {
                Text(job.detail).foregroundStyle(Theme.error).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    LinkButton(title: L("重试", "Retry")) { JobQueue.shared.retry(job, password: job.password) }
                    if job.kind == .extract, job.selection == nil {
                        Dot()
                        LinkButton(title: L("查看内容", "Contents")) { browse(job) }
                    }
                }
            }
        }
    }

    func submit() {
        guard !pw.isEmpty else { return }
        JobQueue.shared.retry(job, password: pw)
        pw = ""
    }
}

/// 2 像素的细进度线
struct ThinProgress: View {
    let value: Double
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.rule)
                Capsule().fill(Theme.link).frame(width: max(2, g.size.width * value))
            }
        }
        .frame(height: 2)
        .animation(.linear(duration: 0.25), value: value)
    }
}

struct Shake: GeometryEffect {
    var amount: CGFloat
    var animatableData: CGFloat { get { amount } set { amount = newValue } }
    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: 6 * sin(amount * .pi * 6), y: 0))
    }
}

/// 底部状态栏（像 Typora 窗口底下那条）：解压到哪、清除已完成、设置
struct StatusBar: View {
    @ObservedObject var queue = JobQueue.shared
    @AppStorage(Pref.dest) private var dest = ""
    @State private var showSettings = false

    var body: some View {
        VStack(spacing: 0) {
            Rule()
            HStack(spacing: 14) {
                Menu {
                    Button(L("压缩包所在的文件夹", "Next to the archive")) { dest = "" }
                    Button(L("下载", "Downloads")) { dest = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0].path }
                    Button(L("桌面", "Desktop")) { dest = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0].path }
                    Divider()
                    Button(L("其他文件夹…", "Other…")) {
                        let p = NSOpenPanel()
                        p.canChooseDirectories = true; p.canChooseFiles = false; p.canCreateDirectories = true
                        if p.runModal() == .OK, let u = p.url { dest = u.path }
                    }
                } label: {
                    Text(L("解压到：", "Extract to: ") + (dest.isEmpty ? L("压缩包旁边", "next to the archive") : (dest as NSString).lastPathComponent) + "  ⌄")
                        .foregroundStyle(Theme.secondary)
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                Spacer()
                if queue.jobs.contains(where: { $0.state == .done }) {
                    LinkButton(title: L("清除已完成", "Clear finished"), color: Theme.secondary) { withAnimation { queue.clearFinished() } }
                }
                Button { showSettings.toggle() } label: { Image(systemName: "gearshape").foregroundStyle(Theme.secondary) }
                    .buttonStyle(.plain)
                    .popover(isPresented: $showSettings, arrowEdge: .bottom) { SettingsView() }
            }
            .font(.system(size: 12))
            .padding(.horizontal, 16).frame(height: 30)
        }
        .background(Theme.bar)
    }
}

struct SettingsView: View {
    @AppStorage(Pref.cleanJunk) private var cleanJunk = true
    @AppStorage(Pref.nestedTar) private var nestedTar = true
    @AppStorage(Pref.reveal) private var reveal = true
    @AppStorage(Pref.trashAfter) private var trashAfter = false
    @AppStorage(Pref.quitAfter) private var quitAfter = true
    @AppStorage(Pref.rememberPw) private var rememberPw = true
    @State private var saved = Passwords.all().count

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("设置", "Settings")).font(.system(size: 17, weight: .bold)).foregroundStyle(Theme.heading)
            Rule()
            Toggle(L("去掉 __MACOSX、.DS_Store、Thumbs.db 等垃圾", "Remove __MACOSX, .DS_Store, Thumbs.db"), isOn: $cleanJunk)
            Toggle(L(".tar.gz / .tgz 一次解到底", "Unpack .tar.gz in one step"), isOn: $nestedTar)
            Toggle(L("解完在访达里选中", "Show in Finder when done"), isOn: $reveal)
            Toggle(L("解完把压缩包移到废纸篓（分卷一起）", "Move archive (all parts) to Trash when done"), isOn: $trashAfter)
            Toggle(L("双击压缩包打开时，解完自动退出", "Quit after extracting files opened from Finder"), isOn: $quitAfter)
            Rule()
            Toggle(L("输对的密码记进密码本（存在钥匙串）", "Save correct passwords to Keychain"), isOn: $rememberPw)
            HStack {
                Text(L("密码本里有 \(saved) 个密码", "\(saved) saved passwords")).foregroundStyle(Theme.secondary)
                Spacer()
                LinkButton(title: L("清空", "Clear")) { Passwords.save([]); saved = 0 }.disabled(saved == 0)
            }
        }
        .font(.system(size: 13))
        .toggleStyle(.checkbox)
        .padding(18)
        .frame(width: 370)
    }
}

// ---- 查看内容：搜索、勾选只解几个、空格键快速预览 ----
struct BrowserView: View {
    @ObservedObject var job: Job
    @Environment(\.dismiss) private var dismiss
    @State private var listing: Listing?
    @State private var password: String?
    @State private var error: String?
    @State private var query = ""
    @State private var checked = Set<Int>()
    @State private var selected = Set<Int>()
    @State private var preview: URL?
    private var fixer: NameFixer { NameFixer(job.sources[0]) }

    struct Row: Identifiable { let id: Int; let name: String; let size: Int64; let isDir: Bool; let entry: Entry }

    var rows: [Row] {
        guard let listing else { return [] }
        let f = fixer
        return listing.entries.map { Row(id: $0.id, name: f.display($0, total: listing.entries.count), size: $0.size, isDir: $0.isDir, entry: $0) }
            .filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(job.sources[0].lastPathComponent).font(.system(size: 20, weight: .bold)).foregroundStyle(Theme.heading)
                    .lineLimit(1).truncationMode(.middle)
                if let t = listing?.type, !t.isEmpty { Text(t).font(.system(size: 12)).foregroundStyle(Theme.faint) }
                Spacer()
                HStack(spacing: 5) {
                    Image(systemName: "magnifyingglass").foregroundStyle(Theme.faint)
                    TextField(L("搜索", "Search"), text: $query).textFieldStyle(.plain)
                }
                .font(.system(size: 13))
                .frame(width: 170)
                .padding(.bottom, 3)
                .overlay(alignment: .bottom) { Rectangle().fill(Theme.quoteBar).frame(height: 1) }
            }
            .padding(.horizontal, 28).padding(.top, 24).padding(.bottom, 10)
            Rule().padding(.horizontal, 28)
            Group {
                if let error {
                    Text(error).font(.system(size: 15)).foregroundStyle(Theme.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if listing == nil {
                    Text(L("正在读取…", "Reading…")).font(.system(size: 15)).foregroundStyle(Theme.faint)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    table
                }
            }
            .frame(maxHeight: .infinity)
            Rule()
            HStack(spacing: 14) {
                if let listing {
                    Text(L("\(listing.entries.filter { !$0.isDir }.count) 个文件，解开共 \(bytes(listing.totalSize))；双击或空格键预览",
                           "\(listing.entries.filter { !$0.isDir }.count) files, \(bytes(listing.totalSize)); double-click or Space to preview"))
                        .foregroundStyle(Theme.secondary)
                }
                Spacer()
                LinkButton(title: L("关闭", "Close"), color: Theme.secondary) { dismiss() }.keyboardShortcut(.cancelAction)
                LinkButton(title: checkedFiles.isEmpty ? L("勾选后可只解这几项", "Check items to extract")
                           : L("解压勾选的 \(checkedFiles.count) 项", "Extract \(checkedFiles.count) checked")) {
                    JobQueue.shared.add(Job(kind: .extract, sources: job.sources, selection: checkedFiles, password: password))
                    dismiss()
                }
                .disabled(checkedFiles.isEmpty)
            }
            .font(.system(size: 13))
            .padding(.horizontal, 28).frame(height: 44)
        }
        .frame(width: 660, height: 500)
        .background(Theme.bg)
        .foregroundStyle(Theme.text)
        .quickLookPreview($preview)
        .task { await load() }
    }

    /// 勾了文件夹就连同它里面的全部文件
    var checkedFiles: [String] {
        guard let listing else { return [] }
        let dirs = listing.entries.filter { checked.contains($0.id) && $0.isDir }.map { $0.path + "/" }
        return listing.entries.filter { e in !e.isDir && (checked.contains(e.id) || dirs.contains { e.path.hasPrefix($0) }) }.map(\.path)
    }

    var table: some View {
        Table(rows, selection: $selected) {
            TableColumn("") { r in
                Toggle("", isOn: Binding(get: { checked.contains(r.id) },
                                         set: { if $0 { checked.insert(r.id) } else { checked.remove(r.id) } }))
                    .labelsHidden().toggleStyle(.checkbox)
            }
            .width(22)
            TableColumn(L("名称", "Name")) { r in
                HStack(spacing: 7) {
                    Image(systemName: r.isDir ? "folder" : (r.entry.encrypted ? "lock" : "doc"))
                        .foregroundStyle(r.isDir ? Theme.link : Theme.faint).frame(width: 16)
                    Text(r.name).lineLimit(1).truncationMode(.head)
                }
            }
            TableColumn(L("大小", "Size")) { r in Text(r.isDir ? "" : bytes(r.size)).monospacedDigit().foregroundStyle(Theme.secondary) }
                .width(90)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: false))
        .scrollContentBackground(.hidden)
        .font(.system(size: 13))
        .padding(.horizontal, 16)
        .contextMenu(forSelectionType: Int.self) { ids in
            Button(L("快速预览", "Quick Look")) { if let id = ids.first { quickLook(id) } }
        } primaryAction: { ids in if let id = ids.first { quickLook(id) } }
        .onKeyPress(.space) {
            if let id = selected.first { quickLook(id) }
            return .handled
        }
    }

    func load() async {
        let arc = job.sources[0], given = job.password
        let r = await Task.detached { Engine.unlock(arc, given: given) }.value
        switch r {
        case .success(let (l, pw)): listing = l; password = pw
        case .failure(let e):
            error = e.isPassword ? L("文件名也加密了，先在列表里输入密码。", "Filenames are encrypted — enter the password first.") : e.text
        }
    }

    /// 把这一项单独解到临时目录，用系统的快速预览打开（RAR 7-Zip 解不了，换 unar）
    func quickLook(_ id: Int) {
        guard let e = listing?.entries.first(where: { $0.id == id }), !e.isDir else { return }
        let arc = job.sources[0], pw = password ?? "", good = (fixer.display(e, total: listing?.entries.count ?? 0) as NSString).lastPathComponent
        Task.detached {
            let fm = FileManager.default
            let dir = fm.temporaryDirectory.appendingPathComponent("unpack-preview-\(id)-\(UUID().uuidString.prefix(6))")
            _ = SevenZip.run(["e", "-y", "-spd", "-sccUTF-8", "-p" + pw, "-o" + dir.path, arc.path, e.path])
            func files() -> [URL] {
                guard let en = fm.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
                return en.compactMap { $0 as? URL }.filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
            }
            if files().isEmpty {
                _ = SevenZip.run(["-o", dir.path, "-f", "-D", "-nr", "-q", "-p", pw, arc.path, e.path], exe: SevenZip.unar)
            }
            guard var u = files().first else { return }
            if good != u.lastPathComponent {
                let g = u.deletingLastPathComponent().appendingPathComponent(good)
                if (try? fm.moveItem(at: u, to: g)) != nil { u = g }
            }
            let shown = u
            await MainActor.run { preview = shown }
        }
    }
}
