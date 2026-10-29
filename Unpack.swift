// 解压：把压缩包拖进来就解开（zip/7z/rar/tar/gz/xz/zst/iso…，加密包、分卷包、Windows 中文乱码都能处理）；拖进文件夹或普通文件就压成 zip
// 引擎是打包在 App 里的 7-Zip（Contents/Resources/7zz，命令行版），界面 SwiftUI
// 编译：./build.sh（只要命令行开发工具，不用 Xcode）
// 自测（不弹窗口）：UNPACK_TEST=压缩包1:压缩包2 [UNPACK_PW=密码] [UNPACK_DEST=目录] Contents/MacOS/Unpack
import SwiftUI
import QuickLook
import UniformTypeIdentifiers
import Security
import UserNotifications
import ServiceManagement

// 界面语言：默认跟随系统（系统首选语言是中文就显示中文，否则英文）；设置里选了中文/English 就写进本程序自己的 AppleLanguages，
// 这样连菜单、程序名也跟着变，重新打开后生效
let isZh = Locale.preferredLanguages.first?.hasPrefix("zh") ?? false

enum UILanguage {
    static let key = "AppleLanguages"
    /// "auto" / "zh" / "en"：只看本程序自己设的，不看全局
    static var current: String {
        guard let l = UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "")?[key] as? [String], let f = l.first else { return "auto" }
        return f.hasPrefix("zh") ? "zh" : "en"
    }
    static func set(_ v: String) {
        if v == "auto" { UserDefaults.standard.removeObject(forKey: key) }
        else { UserDefaults.standard.set([v == "zh" ? "zh-Hans" : "en"], forKey: key) }
    }
    /// 换语言后重新打开自己
    static func relaunch() {
        let sh = Process()
        sh.executableURL = URL(fileURLWithPath: "/bin/sh")
        sh.arguments = ["-c", "while kill -0 \(getpid()) 2>/dev/null; do sleep 0.2; done; open \"$0\"", Bundle.main.bundlePath]
        try? sh.run()
        NSApp.terminate(nil)
    }
}
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
    static let autoUpdate = "autoUpdate" // 每天看一次 GitHub 上有没有新版本
    static let format = "format"         // 拖进来压缩时用的格式：zip / 7z
    static let level = "level"           // 压缩程度：0 只打包 / 1 快 / 5 标准 / 9 最小
    static let browseOnOpen = "browseOnOpen" // 双击压缩包时先看内容，不直接解开
    static let notify = "notify"         // 解完（窗口不在前面时）弹系统通知
    static let watchDownloads = "watchDownloads" // 自动解开「下载」里新下好的压缩包（解压开着时；打开后登录自动启动、关窗口不退出）
    static let lastCheck = "lastUpdateCheck", latestVersion = "latestVersion", latestAsset = "latestAsset"
    static func register() {
        UserDefaults.standard.register(defaults: [dest: "", trashAfter: false, cleanJunk: true, reveal: true,
                                                  nestedTar: true, quitAfter: true, rememberPw: true, autoUpdate: true,
                                                  format: "zip", level: 5, browseOnOpen: false,
                                                  notify: true, watchDownloads: false])
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
    var method = ""        // 比如 "AES-256 Deflate"：往加密 zip 里加文件时沿用同一种加密
    var modified: Date?    // 包里记的修改时间
}

struct Listing {
    var type = ""
    var entries: [Entry] = []
    var headerEncrypted = false   // 文件名也加密了（7z 的「加密文件名」）：往里加文件时要保持
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
    static func run(_ args: [String], exe: String = bin, cwd: URL? = nil, runner: Runner? = nil,
                    onOut: ((String) -> Void)? = nil, onErr: ((String) -> Void)? = nil) -> Result {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        if let cwd { p.currentDirectoryURL = cwd }   // 往包里加文件：在暂存目录里跑，传相对路径，包里就是这个路径
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

    /// 7-Zip 的时间写法：2026-10-29 15:08:13（后面可能还有小数秒）
    static let stampFormat: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd HH:mm:ss"; return f
    }()

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
                                         encrypted: f["Encrypted"] == "+", method: f["Method"] ?? "",
                                         modified: f["Modified"].flatMap { stampFormat.date(from: String($0.prefix(19))) }))
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

// ---- 压缩选项：直接拖进来就用设置里的格式和程度；按住 ⌥ 拖进来（或 ⌘N）可以另设名字、密码、分卷 ----
struct CompressOptions {
    var name = ""            // 空 = 按拖进来的东西起名
    var format = "zip"       // zip / 7z
    var level = 5            // 0 只打包 / 1 快 / 5 标准 / 9 最小
    var password = ""
    var encryptNames = true  // 7z 才有：连文件名也加密，不输密码看不到里面有什么
    var splitMB = 0          // 0 = 不分卷

    static func fromPrefs() -> CompressOptions {
        let d = UserDefaults.standard
        return CompressOptions(format: d.string(forKey: Pref.format) == "7z" ? "7z" : "zip", level: d.integer(forKey: Pref.level))
    }
    static func defaultName(_ srcs: [URL]) -> String {
        srcs.count == 1 ? srcs[0].lastPathComponent : L("归档", "Archive")
    }
    static let levels: [(Int, String)] = [(0, L("只打包，不压缩", "Store only")), (1, L("快", "Fast")),
                                          (5, L("标准", "Normal")), (9, L("最小（慢）", "Smallest (slow)"))]
    static let splits: [(Int, String)] = [(0, L("不分卷", "No split")), (25, L("每卷 25 MB（邮件附件）", "25 MB parts (email)")),
                                          (100, "100 MB"), (1000, "1 GB"), (4000, L("4 GB（U 盘 FAT32）", "4 GB (FAT32 drives)"))]
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
            for c in book() { if case .success(var l) = SevenZip.list(arc, password: c) { l.headerEncrypted = true; return .success((l, c)) } }
            return .failure(.needPassword)
        case .failure(let e): return .failure(e)
        case .success(var l):
            // 用手输的密码读出来的：不带密码读不读得出，决定了文件名是不是也加密了
            if let given, !given.isEmpty, case .failure(.wrongPassword) = SevenZip.list(arc, password: "") { l.headerEncrypted = true }
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

    /// into：解到哪个文件夹（nil = 设置里的位置）；wrap = false 时零散的多个也直接放进 into，不另建文件夹（转格式用）
    static func extract(_ arc: URL, password: String?, listing: Listing, selection: [String]?, into: URL? = nil, wrap: Bool = true,
                        runner: Runner, progress: @escaping (Progress) -> Void) -> Swift.Result<URL, ZError> {
        let fm = FileManager.default
        let parent = into ?? destDir(for: arc)
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

        let r = raw(arc, into: tmp, password: password, listing: listing, selection: selection, need: need, runner: runner, progress: progress)
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
            } else if !wrap {
                final = parent
                for u in items { try fm.moveItem(at: u, to: uniqueURL(parent.appendingPathComponent(u.lastPathComponent))) }
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

    /// 按格式挑解压的程序，原样解到 dir 里（RAR → unar，旧编码 zip → bsdtar，其他 → 7-Zip）
    static func raw(_ arc: URL, into dir: URL, password: String?, listing: Listing, selection: [String]?, need: Int64? = nil,
                    runner: Runner, progress: @escaping (Progress) -> Void = { _ in }) -> SevenZip.Result {
        let fixer = NameFixer(arc)
        let need = need ?? (selection == nil ? listing.totalSize : listing.entries.filter { selection!.contains($0.path) }.reduce(0) { $0 + $1.size })
        if listing.type.lowercased().hasPrefix("rar") {
            return unarExtract(arc, into: dir, password: password, need: need, selection: selection, runner: runner, progress: progress)
        } else if fixer.charset != nil, listing.type == "zip", fixer.names.count == listing.entries.count {
            return bsdtar(arc, into: dir, fixer: fixer, password: password, listing: listing, selection: selection, runner: runner, progress: progress)
        }
        return sevenZipExtract(arc, into: dir, password: password, need: need, selection: selection, runner: runner, progress: progress)
    }

    /// 检查完整性：7-Zip 把每个文件都解一遍、对校验码，不写到盘上；RAR 7-Zip 解不了，就用 unar 解到临时文件夹再删掉
    static func test(_ arc: URL, password: String?, listing: Listing, runner: Runner, progress: @escaping (Progress) -> Void) -> Swift.Result<URL, ZError> {
        let r: SevenZip.Result
        if listing.type.lowercased().hasPrefix("rar") {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("unpack-test-\(UUID().uuidString.prefix(8))")
            defer { try? FileManager.default.removeItem(at: dir) }
            r = unarExtract(arc, into: dir, password: password, need: listing.totalSize, selection: nil, runner: runner) { p in
                progress(Progress(fraction: p.fraction, text: p.text.replacingOccurrences(of: L("解压", "Extracting"), with: L("检查", "Checking"))))
            }
        } else {
            r = run7z(["t", "-bsp1", "-bso0", "-bse2", "-sccUTF-8", "-p" + (password ?? ""), arc.path],
                      total: listing.totalSize, label: L("检查", "Checking"), runner: runner, progress: progress)
        }
        return r.code == 0 ? .success(arc) : .failure(SevenZip.classify(r, runner: runner))
    }

    /// 转格式：整包解到旁边的隐藏临时文件夹，再压成 zip / 7z（压缩程度用设置里的），放在原包旁边
    static func convert(_ arc: URL, to format: String, password: String?, listing: Listing, runner: Runner,
                        progress: @escaping (Progress) -> Void) -> Swift.Result<URL, ZError> {
        let fm = FileManager.default
        let parent = destDir(for: arc)
        let tmp = parent.appendingPathComponent(".转换中-\(UUID().uuidString.prefix(8))")
        defer { try? fm.removeItem(at: tmp) }
        do { try fm.createDirectory(at: tmp, withIntermediateDirectories: true) }
        catch { return .failure(.failed(L("没法在「\(parent.lastPathComponent)」里写文件", "Can't write to “\(parent.lastPathComponent)”"))) }
        if case .failure(let e) = extract(arc, password: password, listing: listing, selection: nil, into: tmp, wrap: false, runner: runner, progress: { p in
            progress(Progress(fraction: p.fraction / 2, text: p.text))
        }) { return .failure(e) }
        var o = CompressOptions.fromPrefs()
        o.format = format
        o.name = Archive.baseName(arc)
        return compress(visible(tmp), options: o, outDir: parent, runner: runner) { p in
            progress(Progress(fraction: 0.5 + p.fraction / 2, text: p.text))
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

    static func compress(_ srcs: [URL], options o: CompressOptions, outDir: URL? = nil, runner: Runner,
                         progress: @escaping (Progress) -> Void) -> Swift.Result<URL, ZError> {
        let fm = FileManager.default
        let parent = outDir ?? destDir(for: srcs[0])
        let name = o.name.isEmpty ? CompressOptions.defaultName(srcs) : o.name
        // 分卷时实际文件是 名字.zip.001、.002…：编号要躲开这些已经存在的
        var out = parent.appendingPathComponent(name + "." + o.format), i = 1
        while fm.fileExists(atPath: out.path) || fm.fileExists(atPath: out.path + ".001") {
            i += 1
            out = parent.appendingPathComponent("\(name) \(i).\(o.format)")
        }
        let total = srcs.reduce(Int64(0)) { $0 + sizeOf($1) }
        // zip 用 -mcu=on：文件名一律存 UTF-8 并打标记，发到 Windows 上也不乱码；不带 Mac 的 .DS_Store 和 ._ 资源文件
        var args = ["a", "-t" + o.format, "-mx=\(o.level)", "-bsp1", "-bso0", "-bse2", "-sccUTF-8",
                    "-xr!.DS_Store", "-xr!__MACOSX", "-xr!._*"]
        if o.format == "zip" { args.append("-mcu=on") }
        if !o.password.isEmpty {
            args.append("-p" + o.password)
            args.append(o.format == "zip" ? "-mem=AES256" : "-mhe=" + (o.encryptNames ? "on" : "off"))
        }
        if o.splitMB > 0 { args.append("-v\(o.splitMB)m") }
        args += [out.path] + srcs.map(\.path)
        let r = run7z(args, total: total, label: L("压缩", "Compressing"), runner: runner, progress: progress)
        let parts = Archive.volumes(URL(fileURLWithPath: out.path + ".001"))
        if r.code != 0 {
            try? fm.removeItem(at: out)
            if o.splitMB > 0 { parts.forEach { try? fm.removeItem(at: $0) } }
            return .failure(SevenZip.classify(r, runner: runner))
        }
        // 设了分卷但没超过一卷：7-Zip 也会出一个 .001，改回正常名字
        if o.splitMB > 0, parts.count == 1 { try? fm.moveItem(at: parts[0], to: out) }
        return .success(o.splitMB > 0 && parts.count > 1 ? parts[0] : out)
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

// ---- 直接改压缩包：加文件、删文件、改名（7-Zip 先写临时包再换掉原包，中途失败原包不动）----
enum Editor {
    /// 改不了就返回原因；nil = 能改
    static func blocker(_ arc: URL, listing: Listing, fixer: NameFixer) -> String? {
        let t = listing.type.lowercased()
        if !["zip", "7z", "tar", "wim"].contains(t) {
            return L("\(listing.type) 格式只能看、不能改（能改的是 zip / 7z / tar）", "\(listing.type) can be viewed but not edited (zip / 7z / tar can)")
        }
        if Archive.volumes(arc).count > 1 { return L("分卷包只能看、不能改", "Split archives can't be edited") }
        if fixer.charset != nil { return L("这个包的文件名是旧编码（\(fixer.charset!)），改了会乱码，只能看", "Names use a legacy encoding (\(fixer.charset!)); editing would garble them") }
        if !FileManager.default.isWritableFile(atPath: arc.path) { return L("这个文件是只读的，不能改", "The file is read-only") }
        return nil
    }

    /// 原包加了密码：新加进去的也用同一个密码、同一种加密
    static func cryptArgs(_ listing: Listing, password: String?) -> [String] {
        let t = listing.type.lowercased()
        var a = t == "zip" ? ["-mcu=on"] : []
        guard let pw = password, !pw.isEmpty, listing.anyEncrypted || listing.headerEncrypted else { return a }
        a.append("-p" + pw)
        if t == "zip", listing.entries.contains(where: { $0.method.contains("AES") }) { a.append("-mem=AES256") }
        if t == "7z", listing.headerEncrypted { a.append("-mhe=on") }
        return a
    }

    /// 把 files 加到包里的 dir 文件夹下（dir 为空 = 最外层）；同名的会被替换
    static func add(_ files: [URL], into dir: String, arc: URL, listing: Listing, password: String?, runner: Runner) -> Swift.Result<Void, ZError> {
        let fm = FileManager.default
        let stage = fm.temporaryDirectory.appendingPathComponent("unpack-add-\(UUID().uuidString.prefix(8))")
        defer { try? fm.removeItem(at: stage) }
        let target = dir.isEmpty ? stage : stage.appendingPathComponent(dir)
        var rel: [String] = []
        do {
            try fm.createDirectory(at: target, withIntermediateDirectories: true)
            for f in files {
                try fm.copyItem(at: f, to: target.appendingPathComponent(f.lastPathComponent))   // APFS 上是克隆，不占空间、很快
                rel.append(dir.isEmpty ? f.lastPathComponent : dir + "/" + f.lastPathComponent)
            }
        } catch { return .failure(.failed(error.localizedDescription)) }
        let args = ["a", "-bso0", "-bse2", "-sccUTF-8", "-xr!.DS_Store", "-xr!__MACOSX", "-xr!._*"]
            + cryptArgs(listing, password: password) + [arc.path] + rel
        return check(SevenZip.run(args, cwd: stage, runner: runner), runner)
    }

    static func delete(_ paths: [String], arc: URL, listing: Listing, password: String?, runner: Runner) -> Swift.Result<Void, ZError> {
        // 名字表 + -spd：名字里有 * ? [ 也按原样认，不当通配符；删文件夹会连里面的一起删
        let lf = FileManager.default.temporaryDirectory.appendingPathComponent("unpack-del-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: lf) }
        do { try paths.joined(separator: "\n").write(to: lf, atomically: true, encoding: .utf8) }
        catch { return .failure(.failed(error.localizedDescription)) }
        let args = ["d", "-bso0", "-bse2", "-sccUTF-8", "-spd", "-scsUTF-8"] + cryptArgs(listing, password: password) + [arc.path, "@" + lf.path]
        return check(SevenZip.run(args, runner: runner), runner)
    }

    /// 改名（文件夹改名，里面的东西跟着走）
    static func rename(_ path: String, to newName: String, arc: URL, listing: Listing, password: String?, runner: Runner) -> Swift.Result<Void, ZError> {
        let parent = (path as NSString).deletingLastPathComponent
        let new = parent.isEmpty ? newName : parent + "/" + newName
        let args = ["rn", "-bso0", "-bse2", "-sccUTF-8"] + cryptArgs(listing, password: password) + [arc.path, path, new]
        return check(SevenZip.run(args, runner: runner), runner)
    }

    private static func check(_ r: SevenZip.Result, _ runner: Runner) -> Swift.Result<Void, ZError> {
        r.code == 0 ? .success(()) : .failure(SevenZip.classify(r, runner: runner))
    }
}

// ---- 一个任务（一个压缩包，或者一批要压缩的文件）----
final class Job: ObservableObject, Identifiable {
    enum Kind: Equatable { case extract, compress, test, convert(String) }   // convert 带目标格式 zip / 7z
    enum State { case waiting, working, needPassword, done, failed }
    let id = UUID()
    let kind: Kind
    let sources: [URL]
    let selection: [String]?   // 只解其中几项（从「查看内容」里勾的）
    let options: CompressOptions   // 压缩任务用
    var dest: URL?                 // 「解压到…」临时选的位置（nil = 设置里的）
    var fromWatch = false          // 「下载」里自动解的：解完把原包移进废纸篓
    @Published var state = State.waiting
    @Published var fraction = 0.0
    @Published var detail = ""
    @Published var result: URL?
    @Published var wrongPassword = false
    var password: String?
    var listing: Listing?
    private var runner = Runner()

    init(kind: Kind, sources: [URL], selection: [String]? = nil, password: String? = nil, options: CompressOptions = .fromPrefs()) {
        self.kind = kind; self.sources = sources; self.selection = selection; self.password = password; self.options = options
    }

    var title: String {
        switch kind {
        case .extract: return sources[0].lastPathComponent + (selection.map { L("（选中 \($0.count) 项）", " (\($0.count) selected)") } ?? "")
        case .compress: return sources.count == 1 ? sources[0].lastPathComponent : L("\(sources.count) 个项目", "\(sources.count) items")
        case .test, .convert: return sources[0].lastPathComponent
        }
    }
    /// 标题后面的灰字
    var tag: String? {
        switch kind {
        case .compress: return compressTag
        case .test: return L("检查完整性", "integrity check")
        case .convert(let f): return "→ " + f
        case .extract: return nil
        }
    }
    /// 标题后面的灰字：→ zip、→ 7z · 加密 · 分卷
    var compressTag: String {
        var t = "→ " + options.format
        if !options.password.isEmpty { t += L(" · 加密", " · encrypted") }
        if options.splitMB > 0 { t += L(" · 分卷", " · split") }
        return t
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
            finish(Engine.compress(sources, options: options, runner: runner, progress: report))
        case .extract, .test, .convert:
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
                    if typed == nil { Notify.done(self) }
                }
                return
            case .failure(let e):
                finish(.failure(e))
            case .success(let (listing, pw)):
                self.listing = listing
                self.password = pw
                if let typed, typed == pw, Pref.on(Pref.rememberPw) { Passwords.remember(typed) }
                switch kind {
                case .test:
                    let n = listing.entries.filter { !$0.isDir }.count
                    finish(Engine.test(arc, password: pw, listing: listing, runner: runner, progress: report),
                           note: L("完好：\(n) 个文件都校验通过", "OK: all \(n) files passed"))
                case .convert(let f):
                    finish(Engine.convert(arc, to: f, password: pw, listing: listing, runner: runner, progress: report))
                default:
                    finish(Engine.extract(arc, password: pw, listing: listing, selection: selection, into: dest, runner: runner, progress: report))
                }
            }
        }
    }

    /// note：完成后显示的话（检查完整性用）；没有就显示放到了哪
    private func finish(_ r: Swift.Result<URL, ZError>, note: String? = nil) {
        ui {
            switch r {
            case .success(let u):
                self.state = .done
                self.result = u
                self.fraction = 1
                if let note { self.detail = note; Notify.done(self); return }
                self.detail = L("已放到「\(u.deletingLastPathComponent().lastPathComponent)」里：\(u.lastPathComponent)",
                                "Saved to “\(u.deletingLastPathComponent().lastPathComponent)”: \(u.lastPathComponent)")
                if self.kind == .extract, self.selection == nil, Pref.on(Pref.trashAfter) || self.fromWatch {
                    NSWorkspace.shared.recycle(Archive.volumes(self.sources[0]))
                }
                if Pref.on(Pref.reveal), !self.fromWatch { NSWorkspace.shared.activateFileViewerSelecting([u]) }
                Notify.done(self)
            case .failure(let e):
                self.state = .failed
                self.detail = e.text
                Notify.done(self)
            }
        }
    }
}

extension ZError {
    var isPassword: Bool { if case .needPassword = self { return true }; if case .wrongPassword = self { return true }; return false }
}

/// 打开「查看内容」窗口要的：哪个包、已知的密码
struct BrowseTarget: Identifiable { let id = UUID(); let url: URL; var password: String? }
/// 打开「压缩选项」窗口要的：要压哪些东西
struct ComposeTarget: Identifiable { let id = UUID(); let urls: [URL] }

// ---- 任务队列：一次只跑一个（7-Zip 自己会用满多核）----
final class JobQueue: ObservableObject {
    static let shared = JobQueue()
    @Published var jobs: [Job] = []
    @Published var browsing: BrowseTarget?
    @Published var composing: ComposeTarget?
    @Published var managingPasswords = false
    private let work = DispatchQueue(label: "unpack.work", qos: .userInitiated)
    var openedByFinder = false

    /// 按住 ⌥ 拖进来：压缩包先看内容（可以改），其他东西先设压缩选项
    func addWithOptions(_ urls: [URL]) {
        let archives = urls.filter(Archive.isArchive), loose = urls.filter { !Archive.isArchive($0) }
        if let a = archives.first { browsing = BrowseTarget(url: Archive.firstVolume(a)) }
        else if !loose.isEmpty { composing = ComposeTarget(urls: loose) }
    }

    /// dest：「解压到…」选的位置；fromWatch：「下载」里自动发现的（解完扔废纸篓、不弹访达）
    func add(_ urls: [URL], dest: URL? = nil, fromWatch: Bool = false) {
        var loose: [URL] = []
        for u in urls {
            if Archive.isArchive(u) {
                let first = Archive.firstVolume(u)
                // 一套分卷一起拖进来时只算一个任务
                if jobs.contains(where: { $0.kind == .extract && $0.selection == nil && $0.sources[0] == first && $0.state != .done && $0.state != .failed }) { continue }
                let j = Job(kind: .extract, sources: [first])
                j.dest = dest; j.fromWatch = fromWatch
                jobs.append(j)
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
        guard openedByFinder, browsing == nil, !Pref.on(Pref.watchDownloads), Pref.on(Pref.quitAfter), !jobs.isEmpty, jobs.allSatisfy({ $0.state == .done }) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { NSApp.terminate(nil) }
    }

    /// 退出时停掉正在跑的 7-Zip（临时文件夹由各任务自己清掉）
    func cancelAll() { jobs.forEach { $0.cancel() } }
}

// ---- 系统通知：窗口不在前面时，解完 / 出错 / 要密码弹一条；点通知打开结果所在的文件夹 ----
enum Notify {
    static func done(_ job: Job) {
        guard Pref.on(Pref.notify), !NSApp.isActive, ProcessInfo.processInfo.environment["UNPACK_TEST"] == nil else { return }
        let c = UNUserNotificationCenter.current()
        c.requestAuthorization(options: [.alert, .sound]) { ok, _ in
            guard ok else { return }
            ui {
                let n = UNMutableNotificationContent()
                switch job.state {
                case .done: n.title = job.kind == .compress ? L("压缩好了", "Compressed") : job.kind == .test ? L("检查完了", "Check finished") : L("解压好了", "Extracted")
                case .needPassword: n.title = L("这个包要密码", "Password needed")
                default: n.title = L("没成功", "Failed")
                }
                n.body = job.title + "\n" + job.detail
                if let r = job.result { n.userInfo = ["path": r.path] }
                c.add(UNNotificationRequest(identifier: job.id.uuidString, content: n, trigger: nil))
            }
        }
    }
}

// ---- 盯着「下载」：新下好的压缩包（大小停住不变了、不是 .download/.crdownload/.part 半截文件）自动解开，原包移进废纸篓 ----
final class DownloadsWatcher {
    static let shared = DownloadsWatcher()
    private var timer: Timer?
    private var known = Set<String>()        // 打开时已经在的，不管
    private var sizes: [String: Int64] = [:] // 新出现、还在下的：上一次看到的大小
    // 自测：UNPACK_WATCH_DIR=目录 换成盯别的文件夹
    let dir = ProcessInfo.processInfo.environment["UNPACK_WATCH_DIR"].map { URL(fileURLWithPath: $0) } ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]

    func sync() {
        if Pref.on(Pref.watchDownloads) { start() } else { stop() }
    }

    private func start() {
        guard timer == nil else { return }
        known = Set(list())
        sizes = [:]
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.tick() }
    }

    private func stop() { timer?.invalidate(); timer = nil }

    private func list() -> [String] { (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [] }

    private func tick() {
        let now = list()
        var ready: [URL] = []
        for n in now where !known.contains(n) {
            let u = dir.appendingPathComponent(n)
            let ext = u.pathExtension.lowercased()
            if n.hasPrefix(".") || ["download", "crdownload", "part", "partial", "tmp"].contains(ext) { continue }
            guard Archive.isArchive(u) else { known.insert(n); continue }
            let size = Engine.sizeOf(u)
            if let last = sizes[n], last == size, size > 0 { ready.append(u); known.insert(n); sizes[n] = nil }
            else { sizes[n] = size }   // 下一轮大小还一样才算下完
        }
        known.formIntersection(now)
        if !ready.isEmpty { JobQueue.shared.add(ready, fromWatch: true) }
    }

    /// 登录时自动打开（盯「下载」要程序开着）
    static func setLoginItem(_ on: Bool) {
        if on { try? SMAppService.mainApp.register() } else { try? SMAppService.mainApp.unregister() }
    }
}

// ---- 自动更新：每天最多问一次 GitHub 最新发布版；有新版就在后台下好、解开，退出时换掉自己，下次打开就是新版 ----
// 状态栏会提示「已下好，退出后自动换上 · 现在更新」，点了立刻换、重新打开
final class Updater: ObservableObject {
    static let shared = Updater()
    enum State: Equatable { case idle, available(String), downloading, ready(String), working, failed }
    @Published var state = State.idle
    static let api = URL(string: "https://api.github.com/repos/Hejun-Coderlife/mac-unpack/releases/latest")!
    static let page = URL(string: "https://github.com/Hejun-Coderlife/mac-unpack/releases/latest")!
    static let assetName = "Unpack-macOS.zip"
    let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    private let d = UserDefaults.standard
    private var staged: URL?   // 下好、解开的新版 .app（在临时目录里）

    /// "1.10" 比 "1.9" 新：按点分开逐段比数字
    static func newer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return false
    }

    /// 能不能换掉自己：装在没权限写的地方（或者从「下载」里直接打开、被系统挪到临时位置）就不行
    private var canReplace: Bool {
        let target = Bundle.main.bundleURL
        return FileManager.default.isWritableFile(atPath: target.deletingLastPathComponent().path) && !target.path.contains("/AppTranslocation/")
    }

    @Published var note: String?   // 手动「检查更新」的结果

    /// force：设置里点「检查更新」，不管开没开自动更新、隔了多久都马上问一次
    func check(force: Bool = false) {
        guard force || Pref.on(Pref.autoUpdate) else { return }
        showPending()
        if force { note = L("正在检查…", "Checking…") }
        guard force || Date().timeIntervalSince1970 - d.double(forKey: Pref.lastCheck) > 86400 else { return }
        var req = URLRequest(url: Self.api, timeoutInterval: 20)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: req) { data, resp, _ in
            guard (resp as? HTTPURLResponse)?.statusCode == 200, let data,
                  let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let tag = j["tag_name"] as? String,
                  let url = (j["assets"] as? [[String: Any]] ?? []).first(where: { $0["name"] as? String == Self.assetName })?["browser_download_url"] as? String
            else { ui { if force { self.note = L("没连上 GitHub，稍后再试", "Couldn't reach GitHub") } }; return }
            let v = tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
            ui {
                self.d.set(Date().timeIntervalSince1970, forKey: Pref.lastCheck)
                self.d.set(v, forKey: Pref.latestVersion)
                self.d.set(url, forKey: Pref.latestAsset)
                if force { self.note = Self.newer(v, than: self.current) ? L("有新版本 \(v)，见底部状态栏", "Version \(v) is available") : L("已经是最新版", "You're up to date") }
                self.showPending()
            }
        }.resume()
    }

    /// 上次查到的新版还没装：能自己换就接着在后台下，换不了就只提示
    private func showPending() {
        guard state == .idle, let v = d.string(forKey: Pref.latestVersion), Self.newer(v, than: current) else { return }
        if canReplace { download(v) } else { state = .available(v) }
    }

    /// 下载新版 zip、解到临时目录，确认里面是同一个程序
    private func download(_ v: String, then: (() -> Void)? = nil) {
        guard let s = d.string(forKey: Pref.latestAsset), let url = URL(string: s) else { state = .available(v); return }
        state = .downloading
        URLSession.shared.downloadTask(with: url) { tmp, resp, _ in
            guard let tmp, (resp as? HTTPURLResponse)?.statusCode == 200 else { ui { self.state = .available(v) }; return }
            let fm = FileManager.default
            let dir = fm.temporaryDirectory.appendingPathComponent("unpack-update-" + UUID().uuidString)
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let unzip = Process()
            unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            unzip.arguments = ["-x", "-k", tmp.path, dir.path]
            try? unzip.run(); unzip.waitUntilExit()
            guard unzip.terminationStatus == 0,
                  let app = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil))?.first(where: { $0.pathExtension == "app" }),
                  Bundle(url: app)?.bundleIdentifier == Bundle.main.bundleIdentifier else { ui { self.state = .available(v) }; return }
            ui { self.staged = app; self.state = .ready(v); then?() }
        }.resume()
    }

    /// 等本程序退出 → 旧的挪开、新的换上（失败就把旧的放回去）→ 要的话重新打开
    private func swap(relaunch: Bool) -> Bool {
        guard let app = staged else { return false }
        staged = nil
        let target = Bundle.main.bundleURL
        let q = { (u: URL) in "'" + u.path.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let old = target.deletingLastPathComponent().appendingPathComponent(".unpack-old-\(UUID().uuidString).app")
        let script = """
        while kill -0 \(getpid()) 2>/dev/null; do sleep 0.2; done
        if mv \(q(target)) \(q(old)); then
          if mv \(q(app)) \(q(target)); then rm -rf \(q(old)); else mv \(q(old)) \(q(target)); fi
        fi
        rm -rf \(q(app.deletingLastPathComponent()))
        \(relaunch ? "open " + q(target) : "")
        """
        let sh = Process()
        sh.executableURL = URL(fileURLWithPath: "/bin/sh")
        sh.arguments = ["-c", script]
        return (try? sh.run()) != nil
    }

    /// 点「现在更新」：没下好就先下，然后换上、重新打开
    func install() {
        guard canReplace else { NSWorkspace.shared.open(Self.page); return }
        let go = { self.state = .working; if self.swap(relaunch: true) { NSApp.terminate(nil) } else { self.state = .failed } }
        if staged != nil { go() }
        else if let v = d.string(forKey: Pref.latestVersion) { download(v, then: go) }
    }

    /// 退出时调：有下好的新版就悄悄换上（不重新打开）
    func installOnQuit() {
        guard Pref.on(Pref.autoUpdate), case .ready = state else { return }
        _ = swap(relaunch: false)
    }
}

/// 状态栏里的「有新版本」提示
struct UpdateLink: View {
    @ObservedObject var u = Updater.shared
    var body: some View {
        switch u.state {
        case .available(let v): LinkButton(title: L("有新版本 \(v) · 更新", "Update to \(v)")) { u.install() }
        case .ready(let v): LinkButton(title: L("新版本 \(v) 已下好，退出后自动换上 · 现在更新", "\(v) installs when you quit · Update now")) { u.install() }
        case .working: Text(L("正在更新…", "Updating…")).foregroundStyle(Theme.faint)
        case .failed: LinkButton(title: L("更新失败，去下载", "Update failed — download"), color: Theme.error) { NSWorkspace.shared.open(Updater.page) }
        case .idle, .downloading: EmptyView()
        }
    }
}

// ---- App ----
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    // 点通知：在访达里选中结果
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler done: @escaping () -> Void) {
        if let p = response.notification.request.content.userInfo["path"] as? String { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)]) }
        done()
    }
    func application(_ application: NSApplication, open urls: [URL]) {
        JobQueue.shared.openedByFinder = true
        // 设置里选了「双击先看内容」：只打开一个压缩包时先看，一次打开好几个还是直接解
        if Pref.on(Pref.browseOnOpen), urls.count == 1, Archive.isArchive(urls[0]) {
            JobQueue.shared.browsing = BrowseTarget(url: Archive.firstVolume(urls[0]))
            return
        }
        JobQueue.shared.add(urls)
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()
        UNUserNotificationCenter.current().delegate = self
        DownloadsWatcher.shared.sync()
        // 登录时自动打开的（盯「下载」用）：不弹窗口，安静待在程序坞里
        let ev = NSAppleEventManager.shared().currentAppleEvent
        if ev?.eventID == kAEOpenApplication, ev?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem {
            DispatchQueue.main.async { NSApp.windows.filter(\.isVisible).forEach { $0.close() } }
        }
        Updater.shared.check()
        if ProcessInfo.processInfo.environment["UNPACK_UPDATE_NOW"] != nil { Updater.shared.install() }   // 自测用
        // 自测截图用：UNPACK_SHOW=browse:压缩包 / compose:文件 直接打开对应窗口
        if let s = ProcessInfo.processInfo.environment["UNPACK_SHOW"], let i = s.firstIndex(of: ":") {
            let u = URL(fileURLWithPath: String(s[s.index(after: i)...]))
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                if s.hasPrefix("browse") { JobQueue.shared.browsing = BrowseTarget(url: u) } else { JobQueue.shared.composing = ComposeTarget(urls: [u]) }
            }
        }
    }
    // 盯着「下载」时关窗口不退出（点程序坞图标再打开窗口）
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { !Pref.on(Pref.watchDownloads) }
    func applicationWillTerminate(_ notification: Notification) {
        JobQueue.shared.cancelAll()
        Updater.shared.installOnQuit()
        Thread.sleep(forTimeInterval: 0.3)
    }
    // 访达右键 → 服务 →「用解压查看内容」
    @objc func browseFiles(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let urls = (pboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        NSApp.activate(ignoringOtherApps: true)
        if let a = urls.first(where: Archive.isArchive) { JobQueue.shared.browsing = BrowseTarget(url: Archive.firstVolume(a)) }
        else { JobQueue.shared.add(urls) }
    }
    // 访达右键 → 服务 →「用解压解压到…」：这次临时选个地方
    @objc func extractTo(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let urls = (pboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async { pickDestThenExtract(urls) }
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
                Button(L("查看压缩包内容…", "Browse Archive…")) {
                    if let u = pick(L("选一个压缩包：先看里面有什么，可以加、删、改名", "Choose an archive to browse and edit"), dirs: false).first {
                        JobQueue.shared.browsing = BrowseTarget(url: Archive.firstVolume(u))
                    }
                }.keyboardShortcut("o", modifiers: [.command, .shift])
                Button(L("解压到…", "Extract To…")) {
                    let us = pick(L("选要解开的压缩包，下一步选解到哪", "Choose archives; next, pick where to extract"), dirs: false)
                    if !us.isEmpty { pickDestThenExtract(us) }
                }.keyboardShortcut("e", modifiers: [.command, .shift])
                Button(L("新建压缩包…", "New Archive…")) {
                    let us = pick(L("选要压缩的文件或文件夹，下一步可选格式、密码、分卷", "Choose files or folders; next you can pick format, password and split"), dirs: true)
                    if !us.isEmpty { JobQueue.shared.composing = ComposeTarget(urls: us) }
                }.keyboardShortcut("n")
            }
        }
    }
}

func pick(_ message: String, dirs: Bool) -> [URL] {
    let p = NSOpenPanel()
    p.allowsMultipleSelection = dirs
    p.canChooseDirectories = dirs
    p.message = message
    return p.runModal() == .OK ? p.urls : []
}

/// 「解压到…」：先选位置，再把这些压缩包解到那里
func pickDestThenExtract(_ urls: [URL]) {
    let archives = urls.filter(Archive.isArchive)
    guard !archives.isEmpty else { return }
    let p = NSOpenPanel()
    p.canChooseDirectories = true; p.canChooseFiles = false; p.canCreateDirectories = true
    p.prompt = L("解压到这里", "Extract Here")
    p.message = L("把 \(archives.count == 1 ? archives[0].lastPathComponent : "\(archives.count) 个压缩包") 解到哪？", "Where to extract?")
    if p.runModal() == .OK, let d = p.url { JobQueue.shared.add(archives, dest: d) }
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
            // 压缩选项：UNPACK_FORMAT=7z UNPACK_LEVEL=9 UNPACK_PW=密码 UNPACK_SPLIT=分卷MB
            var o = CompressOptions.fromPrefs()
            if let f = env["UNPACK_FORMAT"] { o.format = f }
            if let l = env["UNPACK_LEVEL"].flatMap(Int.init) { o.level = l }
            if let p = env["UNPACK_PW"] { o.password = p }
            if let s = env["UNPACK_SPLIT"].flatMap(Int.init) { o.splitMB = s }
            let r = Engine.compress([u], options: o, runner: Runner()) { _ in }
            print("COMPRESS \(u.lastPathComponent) →", (try? r.get().path) ?? "\(r)")
            continue
        }
        let arc = Archive.firstVolume(u)
        let fixer = NameFixer(arc)
        // 改包自测：UNPACK_EDIT="add 包里的文件夹 /本机/文件;rename 旧路径 新名字;delete 路径"（字段用 Tab 分开），改完列出内容
        if let ops = env["UNPACK_EDIT"] {
            for op in ops.split(separator: ";") {
                guard case .success(let (l, pw)) = Engine.unlock(arc, given: env["UNPACK_PW"]) else { print("FAIL unlock"); break }
                if let why = Editor.blocker(arc, listing: l, fixer: fixer) { print("BLOCKED \(why)"); break }
                let f = op.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
                let r: Swift.Result<Void, ZError>
                switch f[0] {
                case "add": r = Editor.add(f.dropFirst(2).map { URL(fileURLWithPath: $0) }, into: f[1], arc: arc, listing: l, password: pw, runner: Runner())
                case "rename": r = Editor.rename(f[1], to: f[2], arc: arc, listing: l, password: pw, runner: Runner())
                default: r = Editor.delete(Array(f.dropFirst()), arc: arc, listing: l, password: pw, runner: Runner())
                }
                print("EDIT \(f[0]):", (try? r.get()) != nil ? "ok" : "\(r)")
            }
            if case .success(let (l, _)) = Engine.unlock(arc, given: env["UNPACK_PW"]) {
                print("NOW enc=\(l.anyEncrypted) hdr=\(l.headerEncrypted)"); for e in l.entries { print("   ", e.path, e.method) }
            }
            continue
        }
        switch Engine.unlock(arc, given: env["UNPACK_PW"]) {
        case .failure(let e): print("FAIL \(u.lastPathComponent): \(e.text)")
        case .success(let (l, pw)):
            print("LIST \(arc.lastPathComponent) type=\(l.type) n=\(l.entries.count) pw=\(pw ?? "-") enc=\(fixer.charset ?? "-")")
            for e in l.entries.prefix(5) { print("   ", fixer.display(e, total: l.entries.count)) }
            // UNPACK_ACTION=test 只检查完整性；=zip / =7z 转格式
            let action = env["UNPACK_ACTION"]
            let r = action == "test" ? Engine.test(arc, password: pw, listing: l, runner: Runner()) { _ in }
                : action.map { f in Engine.convert(arc, to: f, password: pw, listing: l, runner: Runner()) { _ in } }
                ?? Engine.extract(arc, password: pw, listing: l, selection: nil, runner: Runner()) { _ in }
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
                            ForEach(queue.jobs) { JobRow(job: $0, browse: { queue.browsing = BrowseTarget(url: $0.sources[0], password: $0.password) }) }
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
            if NSEvent.modifierFlags.contains(.option) { queue.addWithOptions(urls) } else { queue.add(urls) }
            return !urls.isEmpty
        } isTargeted: { t in withAnimation(.easeOut(duration: 0.15)) { targeted = t } }
        .sheet(item: $queue.browsing) { BrowserView(target: $0) }
        .sheet(item: $queue.composing) { CompressSheet(target: $0) }
        .sheet(isPresented: $queue.managingPasswords) { PasswordBook() }
        .onChange(of: queue.jobs.count) { _, n in   // 自测截图用：UNPACK_BROWSE=1 时自动打开第一个包的内容
            if n > 0, queue.browsing == nil, ProcessInfo.processInfo.environment["UNPACK_BROWSE"] != nil, let j = queue.jobs.first {
                queue.browsing = BrowseTarget(url: j.sources[0], password: j.password)
            }
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
                Text(L("按住 ⌥ 松手：压缩包先看内容、可以改；文件夹先选格式、密码、分卷", "Hold ⌥ when releasing: browse the archive, or choose format, password and split"))
                    .font(.system(size: 12)).foregroundStyle(Theme.faint).padding(.top, 4)
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
                    if let t = job.tag { Text(t).foregroundStyle(Theme.faint) }
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
                UpdateLink()
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
    @AppStorage(Pref.browseOnOpen) private var browseOnOpen = false
    @AppStorage(Pref.notify) private var notify = true
    @AppStorage(Pref.watchDownloads) private var watch = false
    @AppStorage(Pref.rememberPw) private var rememberPw = true
    @AppStorage(Pref.autoUpdate) private var autoUpdate = true
    @AppStorage(Pref.format) private var format = "zip"
    @AppStorage(Pref.level) private var level = 5
    @State private var saved = Passwords.all().count
    @State private var language = UILanguage.current
    @ObservedObject private var updater = Updater.shared
    private let startLanguage = UILanguage.current

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("设置", "Settings")).font(.system(size: 17, weight: .bold)).foregroundStyle(Theme.heading)
            Rule()
            Toggle(L("去掉 __MACOSX、.DS_Store、Thumbs.db 等垃圾", "Remove __MACOSX, .DS_Store, Thumbs.db"), isOn: $cleanJunk)
            Toggle(L(".tar.gz / .tgz 一次解到底", "Unpack .tar.gz in one step"), isOn: $nestedTar)
            Toggle(L("解完在访达里选中", "Show in Finder when done"), isOn: $reveal)
            Toggle(L("解完把压缩包移到废纸篓（分卷一起）", "Move archive (all parts) to Trash when done"), isOn: $trashAfter)
            Toggle(L("双击压缩包时先看内容，不直接解开", "Double-click an archive to browse it first"), isOn: $browseOnOpen)
            Toggle(L("双击压缩包打开时，解完自动退出", "Quit after extracting files opened from Finder"), isOn: $quitAfter)
            Toggle(L("在后台解完时弹系统通知", "Notify me when done in the background"), isOn: $notify)
            Toggle(L("自动解开「下载」里新下好的压缩包（原包移进废纸篓）", "Auto-extract new archives in Downloads (then trash them)"), isOn: $watch)
                .onChange(of: watch) { _, on in DownloadsWatcher.shared.sync(); DownloadsWatcher.setLoginItem(on) }
            if watch {
                Text(L("开着这个：登录时自动打开「解压」，关掉窗口也不退出（在程序坞里）", "Unpack starts at login and keeps running in the Dock"))
                    .font(.system(size: 11)).foregroundStyle(Theme.faint).padding(.leading, 20)
            }
            Toggle(L("自动更新（有新版就在后台下好，退出时换上）", "Update automatically (downloads in the background, installs on quit)"), isOn: $autoUpdate)
            Rule()
            HStack(spacing: 8) {
                Text(L("拖进来压缩成", "Compress to"))
                FormatPicker(format: $format)
                LevelPicker(level: $level)
            }
            Text(L("要设密码、分卷：按住 ⌥ 拖进来，或 ⌘N", "For password or split: hold ⌥ while dropping, or ⌘N"))
                .font(.system(size: 12)).foregroundStyle(Theme.faint)
            Rule()
            Toggle(L("输对的密码记进密码本（存在钥匙串）", "Save correct passwords to Keychain"), isOn: $rememberPw)
            HStack {
                Text(L("密码本里有 \(saved) 个密码", "\(saved) saved passwords")).foregroundStyle(Theme.secondary)
                Spacer()
                LinkButton(title: L("管理…", "Manage…")) { JobQueue.shared.managingPasswords = true }.disabled(saved == 0)
                Dot()
                LinkButton(title: L("清空", "Clear")) { Passwords.save([]); saved = 0 }.disabled(saved == 0)
            }
            .onReceive(JobQueue.shared.$managingPasswords) { if !$0 { saved = Passwords.all().count } }
            Rule()
            HStack(spacing: 8) {
                Text(L("界面语言", "Language"))
                Picker("", selection: $language) {
                    Text(L("跟随系统", "System")).tag("auto"); Text("中文").tag("zh"); Text("English").tag("en")
                }
                .labelsHidden().fixedSize()
                .onChange(of: language) { _, v in UILanguage.set(v) }
                if language != startLanguage {
                    LinkButton(title: L("重新打开生效", "Relaunch to apply")) { UILanguage.relaunch() }
                }
            }
            HStack(spacing: 6) {
                Text(appName + " " + updater.current).foregroundStyle(Theme.secondary)
                Dot()
                LinkButton(title: L("检查更新", "Check for updates")) { updater.check(force: true) }
                if let n = updater.note { Text(n).foregroundStyle(Theme.faint) }
            }
        }
        .font(.system(size: 13))
        .toggleStyle(.checkbox)
        .padding(18)
        .frame(width: 370)
    }
}

/// 密码本：一个个看、一个个删
struct PasswordBook: View {
    @Environment(\.dismiss) private var dismiss
    @State private var list = Passwords.all()
    @State private var shown = Set<Int>()
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(L("密码本", "Password Book")).font(.system(size: 17, weight: .bold)).foregroundStyle(Theme.heading).padding(.bottom, 4)
            Text(L("遇到加密包时从上往下挨个试；最近用过的排在前面", "Tried in order on encrypted archives; most recent first"))
                .font(.system(size: 12)).foregroundStyle(Theme.faint).padding(.bottom, 10)
            Rule()
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(list.enumerated()), id: \.offset) { i, p in
                        HStack(spacing: 10) {
                            Text(shown.contains(i) ? p : String(repeating: "•", count: min(max(p.count, 6), 16)))
                                .font(.system(size: 13, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            LinkButton(title: shown.contains(i) ? L("隐藏", "Hide") : L("显示", "Show"), color: Theme.secondary) {
                                if shown.contains(i) { shown.remove(i) } else { shown.insert(i) }
                            }
                            LinkButton(title: L("删除", "Delete"), color: Theme.error) {
                                list.remove(at: i); shown = []; Passwords.save(list)
                            }
                        }
                        .padding(.vertical, 8)
                        .overlay(alignment: .bottom) { Rule() }
                    }
                }
            }
            .frame(height: 260)
            HStack { Spacer(); LinkButton(title: L("完成", "Done")) { dismiss() }.keyboardShortcut(.defaultAction) }.padding(.top, 12)
        }
        .font(.system(size: 13))
        .padding(22)
        .frame(width: 400)
        .background(Theme.bg)
        .foregroundStyle(Theme.text)
    }
}

// ---- 压缩选项：格式、压缩程度、密码、分卷 ----
struct FormatPicker: View {
    @Binding var format: String
    var body: some View {
        Picker("", selection: $format) { Text("zip").tag("zip"); Text("7z").tag("7z") }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
    }
}

struct LevelPicker: View {
    @Binding var level: Int
    var body: some View {
        Picker("", selection: $level) { ForEach(CompressOptions.levels, id: \.0) { Text($0.1).tag($0.0) } }
            .labelsHidden().fixedSize()
    }
}

struct CompressSheet: View {
    let target: ComposeTarget
    @Environment(\.dismiss) private var dismiss
    @State private var o = CompressOptions.fromPrefs()
    @State private var again = ""
    @State private var total: Int64?
    @State private var separate = false   // 拖进来好几个：每个各压一个包
    @AppStorage(Pref.rememberPw) private var rememberPw = true

    var mismatch: Bool { !o.password.isEmpty && again != o.password }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(L("新建压缩包", "New Archive")).font(.system(size: 20, weight: .bold)).foregroundStyle(Theme.heading)
                Text(target.urls.count == 1 ? target.urls[0].lastPathComponent : L("\(target.urls.count) 个项目", "\(target.urls.count) items"))
                    .foregroundStyle(Theme.secondary).lineLimit(1).truncationMode(.middle)
                if let total { Text(bytes(total)).foregroundStyle(Theme.faint) }
            }
            .padding(.bottom, 10)
            Rule().padding(.bottom, 16)
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 14) {
                if target.urls.count > 1 {
                    GridRow {
                        label(L("打包", "Pack"))
                        Toggle(L("每一项各压一个包（\(target.urls.count) 个）", "One archive per item (\(target.urls.count))"), isOn: $separate)
                    }
                }
                GridRow {
                    label(L("名字", "Name"))
                    if separate {
                        Text(L("各用自己的名字", "Each keeps its own name")).foregroundStyle(Theme.faint)
                    } else {
                        underlined(HStack(spacing: 2) {
                            TextField(CompressOptions.defaultName(target.urls), text: $o.name)
                            Text("." + o.format).foregroundStyle(Theme.faint)
                        })
                        .frame(width: 240)
                    }
                }
                GridRow {
                    label(L("格式", "Format"))
                    VStack(alignment: .leading, spacing: 4) {
                        FormatPicker(format: $o.format)
                        hint(o.format == "zip" ? L("Windows、Mac 双击就能打开", "Opens anywhere with a double-click")
                             : L("一般比 zip 小一些，对方要装解压软件（7-Zip、WinRAR、「解压」）", "Usually smaller; needs an app like 7-Zip to open"))
                    }
                }
                GridRow { label(L("压缩", "Level")); LevelPicker(level: $o.level) }
                GridRow {
                    label(L("密码", "Password"))
                    VStack(alignment: .leading, spacing: 8) {
                        underlined(SecureField(L("不设就留空", "Leave empty for none"), text: $o.password)).frame(width: 240)
                        if !o.password.isEmpty {
                            underlined(SecureField(L("再输一次", "Repeat"), text: $again)).frame(width: 240)
                            if mismatch && !again.isEmpty { Text(L("两次输的不一样", "Passwords don't match")).foregroundStyle(Theme.error) }
                            if o.format == "7z" {
                                Toggle(L("文件名也加密（不输密码看不到里面有什么）", "Encrypt file names too"), isOn: $o.encryptNames)
                            } else {
                                hint(L("AES-256 加密。Windows、Mac 自带的解压打不开，要用 7-Zip、WinRAR 或「解压」",
                                       "AES-256. The built-in Windows/Mac tools can't open it; use 7-Zip, WinRAR or Unpack"))
                            }
                            Toggle(L("记进密码本，自己以后解开不用再输", "Save to my password book"), isOn: $rememberPw)
                        }
                    }
                }
                GridRow {
                    label(L("分卷", "Split"))
                    VStack(alignment: .leading, spacing: 4) {
                        Picker("", selection: $o.splitMB) { ForEach(CompressOptions.splits, id: \.0) { Text($0.1).tag($0.0) } }
                            .labelsHidden().fixedSize()
                        if o.splitMB > 0 { hint(L("出来的是 名字.\(o.format).001、.002…，对方要全部收齐放一起再解", "Produces .001, .002…; all parts are needed to extract")) }
                    }
                }
            }
            .toggleStyle(.checkbox)
            Rule().padding(.top, 22)
            HStack(spacing: 14) {
                Spacer()
                LinkButton(title: L("取消", "Cancel"), color: Theme.secondary) { dismiss() }.keyboardShortcut(.cancelAction)
                LinkButton(title: L("压缩", "Compress")) {
                    o.name = o.name.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "/", with: "-")
                    if !o.password.isEmpty, rememberPw { Passwords.remember(o.password) }
                    if separate {
                        o.name = ""
                        for u in target.urls { JobQueue.shared.add(Job(kind: .compress, sources: [u], options: o)) }
                    } else {
                        JobQueue.shared.add(Job(kind: .compress, sources: target.urls, options: o))
                    }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(mismatch)
            }
            .padding(.top, 12)
        }
        .font(.system(size: 13))
        .padding(.horizontal, 28).padding(.top, 24).padding(.bottom, 14)
        .frame(width: 560, alignment: .topLeading)
        .fixedSize(horizontal: false, vertical: true)
        .background(Theme.bg)
        .foregroundStyle(Theme.text)
        .task {
            let us = target.urls
            total = await Task.detached { us.reduce(Int64(0)) { $0 + Engine.sizeOf($1) } }.value
        }
    }

    func label(_ s: String) -> some View { Text(s).foregroundStyle(Theme.secondary).gridColumnAlignment(.trailing) }
    func hint(_ s: String) -> some View { Text(s).font(.system(size: 12)).foregroundStyle(Theme.faint).fixedSize(horizontal: false, vertical: true) }
    func underlined(_ v: some View) -> some View {
        VStack(spacing: 3) { v.textFieldStyle(.plain).font(.system(size: 14)); Rectangle().fill(Theme.quoteBar).frame(height: 1) }
    }
}

// ---- 查看内容：像文件夹一样一层层点进去；搜索、勾选只解几个、空格键快速预览、拖出去就解到那里；
//      zip / 7z / tar 还能直接加、删、改名，双击文件用默认程序打开，改完保存自动写回压缩包 ----
struct BrowserView: View {
    let target: BrowseTarget
    @Environment(\.dismiss) private var dismiss
    @State private var listing: Listing?
    @State private var fixer: NameFixer?
    @State private var password: String?
    @State private var error: String?
    @State private var needPw = false
    @State private var wrongPw = false
    @State private var pwInput = ""
    @State private var blocker: String?           // 不能改的原因；nil = 能改
    @State private var query = ""
    @State private var cwd = ""                   // 现在在包里哪个文件夹（7-Zip 的原始路径），"" = 最外层
    @State private var checked = Set<String>()
    @State private var selected = Set<String>()
    @State private var preview: URL?
    @State private var busy: String?              // 正在改包
    @State private var editError: String?
    @State private var renaming: Node?
    @State private var newName = ""
    @State private var deleting: [Node] = []
    @State private var replacing: (files: [URL], count: Int)?
    @State private var dropping = false
    @State private var watching: [Watch] = []     // 双击打开、正在别的程序里改的文件
    @State private var savedNote: String?
    @State private var dragNote: String?          // 拖出去时正在解
    @State private var sortOrder = [KeyPathComparator(\Node.name, comparator: .localizedStandard)]
    private var arc: URL { target.url }

    /// 解到临时目录、用默认程序打开的一个文件：盯着它的修改时间，变了就写回压缩包
    struct Watch { let file: URL; let dir: String; var stamp: Date }
    static func stamp(_ u: URL) -> Date { (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast }

    /// 列表里的一行：真实的文件/文件夹，或者只是从路径里看出来的文件夹（包里没单独记它）
    struct Node: Identifiable, Hashable {
        let id: String         // 7-Zip 的原始路径
        let name: String       // 显示的名字（乱码已修）
        let isDir: Bool
        let size: Int64
        let encrypted: Bool
        var modified = Date.distantPast   // 文件夹 = 里面最新的那个
    }

    /// 按点的列头排序，文件夹总在前面
    var sortedNodes: [Node] {
        let all = nodes.sorted(using: sortOrder)
        return all.filter(\.isDir) + all.filter { !$0.isDir }
    }

    var nodes: [Node] {
        guard let listing, let fixer else { return [] }
        let total = listing.entries.count
        func disp(_ e: Entry) -> [String] {
            let raw = e.path.split(separator: "/").map(String.init), d = fixer.display(e, total: total).split(separator: "/").map(String.init)
            return d.count == raw.count ? d : raw
        }
        if !query.isEmpty {   // 搜索：整个包里找，显示完整路径
            return listing.entries.compactMap { e in
                let n = disp(e).joined(separator: "/")
                return n.localizedCaseInsensitiveContains(query) ? Node(id: e.path, name: n, isDir: e.isDir, size: e.isDir ? 0 : e.size, encrypted: e.encrypted, modified: e.modified ?? .distantPast) : nil
            }
        }
        let prefix = cwd.isEmpty ? "" : cwd + "/", depth = cwd.isEmpty ? 0 : cwd.split(separator: "/").count
        var dirs: [String: (name: String, size: Int64, date: Date)] = [:], files: [Node] = []
        for e in listing.entries where e.path.hasPrefix(prefix) {
            let raw = e.path.split(separator: "/").map(String.init)
            guard raw.count > depth else { continue }
            let d = disp(e)
            if raw.count == depth + 1, !e.isDir {
                files.append(Node(id: e.path, name: d[depth], isDir: false, size: e.size, encrypted: e.encrypted, modified: e.modified ?? .distantPast))
                continue
            }
            let key = raw[0...depth].joined(separator: "/")
            var v = dirs[key] ?? (d[depth], 0, .distantPast)
            if !e.isDir { v.size += e.size }
            if let m = e.modified, m > v.date { v.date = m }
            dirs[key] = v
        }
        let order: (Node, Node) -> Bool = { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return dirs.map { Node(id: $0.key, name: $0.value.name, isDir: true, size: $0.value.size, encrypted: false, modified: $0.value.date) }.sorted(by: order)
            + files.sorted(by: order)
    }

    /// 面包屑：包名 › 文件夹 › 子文件夹
    var crumbs: [(path: String, name: String)] {
        var out = [(path: "", name: arc.lastPathComponent)], acc = ""
        guard let listing, let fixer, !cwd.isEmpty else { return out }
        let probe = listing.entries.first { $0.path == cwd || $0.path.hasPrefix(cwd + "/") }
        let raw = cwd.split(separator: "/").map(String.init)
        var d = probe.map { fixer.display($0, total: listing.entries.count).split(separator: "/").map(String.init) } ?? raw
        if d.count < raw.count { d = raw }
        for (i, c) in raw.enumerated() { acc = acc.isEmpty ? c : acc + "/" + c; out.append((acc, d[i])) }
        return out
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(arc.lastPathComponent).font(.system(size: 20, weight: .bold)).foregroundStyle(Theme.heading)
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
            if listing != nil { toolbar.padding(.horizontal, 28).padding(.vertical, 8) }
            Group {
                if needPw {
                    passwordPrompt
                } else if let error {
                    Text(error).font(.system(size: 15)).foregroundStyle(Theme.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if listing == nil {
                    Text(L("正在读取…", "Reading…")).font(.system(size: 15)).foregroundStyle(Theme.faint)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    table
                        .overlay {
                            if dropping {
                                RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.link.opacity(0.6), lineWidth: 2).padding(.horizontal, 16)
                                    .allowsHitTesting(false)
                            }
                        }
                        .dropDestination(for: URL.self) { urls, _ in
                            guard blocker == nil, busy == nil, !urls.isEmpty else { return false }
                            add(urls); return true
                        } isTargeted: { dropping = $0 && blocker == nil }
                }
            }
            .frame(maxHeight: .infinity)
            Rule()
            footer
        }
        .frame(width: 720, height: 540)
        .background(Theme.bg)
        .foregroundStyle(Theme.text)
        .quickLookPreview($preview)
        .task { await load() }
        .onReceive(Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()) { _ in syncEdits(final: false) }
        .onDisappear { syncEdits(final: true) }
        .alert(L("改名", "Rename"), isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } }), presenting: renaming) { n in
            TextField(L("新名字", "New name"), text: $newName)
            Button(L("改名", "Rename")) { rename(n) }
            Button(L("取消", "Cancel"), role: .cancel) {}
        }
        .confirmationDialog(deleting.count == 1 ? L("从压缩包里删掉「\(deleting[0].name)」？", "Delete “\(deleting[0].name)” from the archive?")
                            : L("从压缩包里删掉这 \(deleting.count) 项？", "Delete \(deleting.count) items from the archive?"),
                            isPresented: Binding(get: { !deleting.isEmpty }, set: { if !$0 { deleting = [] } })) {
            Button(L("删除", "Delete"), role: .destructive) { delete(deleting) }
            Button(L("取消", "Cancel"), role: .cancel) {}
        } message: { Text(L("直接改原压缩包，删了找不回来（废纸篓里也没有）。", "This changes the archive itself and can't be undone.")) }
        .confirmationDialog(L("这里已经有 \(replacing?.count ?? 0) 个同名的，替换掉？", "Replace \(replacing?.count ?? 0) items with the same name?"),
                            isPresented: Binding(get: { replacing != nil }, set: { if !$0 { replacing = nil } })) {
            Button(L("替换", "Replace"), role: .destructive) { if let r = replacing { add(r.files, force: true) } }
            Button(L("取消", "Cancel"), role: .cancel) {}
        }
    }

    /// 面包屑 + 改包的操作
    var toolbar: some View {
        HStack(spacing: 6) {
            ForEach(Array(crumbs.enumerated()), id: \.offset) { i, c in
                if i > 0 { Text("›").foregroundStyle(Theme.faint) }
                if c.path == cwd && query.isEmpty { Text(c.name).foregroundStyle(Theme.heading).lineLimit(1) }
                else { LinkButton(title: c.name) { query = ""; cwd = c.path; selected = [] }.lineLimit(1) }
            }
            Spacer(minLength: 12)
            Menu {
                Button(L("检查完整性", "Check integrity")) { queue(.test) }
                Divider()
                ForEach(["zip", "7z"].filter { $0 != listing?.type.lowercased() }, id: \.self) { f in
                    Button(L("转成 \(f)", "Convert to \(f)")) { queue(.convert(f)) }
                }
            } label: { Text(L("工具  ⌄", "Tools  ⌄")).foregroundStyle(Theme.link) }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize().disabled(busy != nil)
                .padding(.trailing, 10)
            if let blocker {
                Text(blocker).foregroundStyle(Theme.faint).lineLimit(1).truncationMode(.tail).help(blocker)
            } else {
                LinkButton(title: L("添加文件…", "Add Files…")) {
                    let p = NSOpenPanel()
                    p.allowsMultipleSelection = true; p.canChooseDirectories = true
                    p.message = L("加到压缩包的「\(crumbs.last!.name)」里", "Add to “\(crumbs.last!.name)” in the archive")
                    if p.runModal() == .OK { add(p.urls) }
                }
                .disabled(busy != nil).fixedSize()
            }
        }
        .font(.system(size: 13))
    }

    var passwordPrompt: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(wrongPw ? L("密码不对，再试一次。", "Wrong password, try again.") : L("这个包加了密码，存过的密码都不对。", "This archive is encrypted and no saved password fits."))
                .foregroundStyle(wrongPw ? Theme.error : Theme.secondary)
            HStack(spacing: 12) {
                VStack(spacing: 3) {
                    SecureField(L("输入密码", "Password"), text: $pwInput).textFieldStyle(.plain).font(.system(size: 14)).onSubmit(unlock)
                    Rectangle().fill(Theme.quoteBar).frame(height: 1)
                }
                .frame(width: 220)
                LinkButton(title: L("打开", "Open"), action: unlock).disabled(pwInput.isEmpty)
            }
        }
        .font(.system(size: 14))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    var footer: some View {
        HStack(spacing: 14) {
            if let b = busy ?? dragNote {
                ProgressView().controlSize(.small)
                Text(b).foregroundStyle(Theme.secondary)
            } else if let editError {
                Text(editError).foregroundStyle(Theme.error).lineLimit(2)
            } else if let savedNote {
                Text("✓ " + savedNote).foregroundStyle(Theme.ok).lineLimit(1)
            } else if !watching.isEmpty {
                Text(L("改完保存，会自动写回压缩包", "Save your changes; they're written back automatically")).foregroundStyle(Theme.secondary)
            } else if let listing {
                Text(L("\(listing.entries.filter { !$0.isDir }.count) 个文件，共 \(bytes(listing.totalSize))；双击打开，拖出去就解到那里",
                       "\(listing.entries.filter { !$0.isDir }.count) files, \(bytes(listing.totalSize)); double-click to open, drag out to extract"))
                    .foregroundStyle(Theme.secondary)
            }
            Spacer()
            LinkButton(title: L("关闭", "Close"), color: Theme.secondary) { dismiss() }.keyboardShortcut(.cancelAction)
            if blocker == nil, !checked.isEmpty {
                LinkButton(title: L("删除勾选的", "Delete checked"), color: Theme.error) { deleting = checkedNodes }.disabled(busy != nil)
            }
            LinkButton(title: checked.isEmpty ? L("全部解开", "Extract all") : L("解压勾选的 \(checkedFiles.count) 项", "Extract \(checkedFiles.count) checked")) {
                JobQueue.shared.add(Job(kind: .extract, sources: [arc], selection: checked.isEmpty ? nil : checkedFiles, password: password))
                dismiss()
            }
            .disabled(listing == nil || busy != nil || (!checked.isEmpty && checkedFiles.isEmpty))
        }
        .font(.system(size: 13))
        .padding(.horizontal, 28).frame(height: 44)
    }

    /// 勾了文件夹就连同它里面的全部文件
    var checkedFiles: [String] {
        guard let listing else { return [] }
        let dirs = checked.map { $0 + "/" }
        return listing.entries.filter { e in !e.isDir && (checked.contains(e.path) || dirs.contains { e.path.hasPrefix($0) }) }.map(\.path)
    }
    /// 勾了的（可能在别的文件夹里），删除时用
    var checkedNodes: [Node] {
        let here = Dictionary(nodes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return checked.sorted().map { here[$0] ?? Node(id: $0, name: ($0 as NSString).lastPathComponent, isDir: false, size: 0, encrypted: false) }
    }

    var table: some View {
        Table(of: Node.self, selection: $selected, sortOrder: $sortOrder) {
            TableColumn("") { n in
                Toggle("", isOn: Binding(get: { checked.contains(n.id) },
                                         set: { if $0 { checked.insert(n.id) } else { checked.remove(n.id) } }))
                    .labelsHidden().toggleStyle(.checkbox)
            }
            .width(22)
            TableColumn(L("名称", "Name"), value: \.name, comparator: .localizedStandard) { n in
                HStack(spacing: 7) {
                    Image(systemName: n.isDir ? "folder" : (n.encrypted ? "lock" : "doc"))
                        .foregroundStyle(n.isDir ? Theme.link : Theme.faint).frame(width: 16)
                    Text(n.name).lineLimit(1).truncationMode(query.isEmpty ? .middle : .head)
                }
            }
            TableColumn(L("大小", "Size"), value: \.size) { n in Text(n.isDir && n.size == 0 ? "" : bytes(n.size)).monospacedDigit().foregroundStyle(Theme.secondary) }
                .width(80)
            TableColumn(L("修改日期", "Modified"), value: \.modified) { n in
                Text(n.modified == .distantPast ? "" : n.modified.formatted(date: .numeric, time: .shortened)).monospacedDigit().foregroundStyle(Theme.secondary)
            }
            .width(130)
        } rows: {
            ForEach(sortedNodes) { n in TableRow(n).itemProvider { dragProvider(n) } }
        }
        .tableStyle(.inset(alternatesRowBackgrounds: false))
        .scrollContentBackground(.hidden)
        .font(.system(size: 13))
        .padding(.horizontal, 16)
        .contextMenu(forSelectionType: String.self) { ids in
            let picked = nodes.filter { ids.contains($0.id) }
            if picked.count == 1, let n = picked.first {
                Button(n.isDir ? L("打开", "Open") : (blocker == nil ? L("打开（改完自动写回）", "Open (changes are saved back)") : L("打开", "Open"))) { open(n) }
                if !n.isDir { Button(L("快速预览", "Quick Look")) { quickLook(n.id) } }
            }
            if !picked.isEmpty {
                Button(L("解压这 \(picked.count) 项", "Extract \(picked.count) items")) {
                    let keep = checked; checked = Set(picked.map(\.id))
                    let files = checkedFiles; checked = keep
                    JobQueue.shared.add(Job(kind: .extract, sources: [arc], selection: files, password: password))
                }
            }
            if blocker == nil, busy == nil, !picked.isEmpty {
                Divider()
                if picked.count == 1, let n = picked.first {
                    Button(L("改名…", "Rename…")) { newName = n.name.components(separatedBy: "/").last ?? n.name; renaming = n }
                }
                Button(L("删除…", "Delete…")) { deleting = picked }
            }
        } primaryAction: { ids in if let n = nodes.first(where: { ids.contains($0.id) }) { open(n) } }
        .onKeyPress(.space) {
            if let n = nodes.first(where: { selected.contains($0.id) && !$0.isDir }) { quickLook(n.id) }
            return .handled
        }
        .onKeyPress(.delete) {
            let picked = nodes.filter { selected.contains($0.id) }
            if blocker == nil, busy == nil, !picked.isEmpty { deleting = picked }
            return .handled
        }
    }

    func open(_ n: Node) {
        if n.isDir { query = ""; cwd = n.id; selected = [] } else { openInApp(n.id) }
    }

    func queue(_ kind: Job.Kind) {
        JobQueue.shared.add(Job(kind: kind, sources: [arc], password: password))
        dismiss()
    }

    /// 这些项（文件夹连同里面的全部文件）对应的文件
    func files(of keys: [String]) -> [String] {
        guard let listing else { return [] }
        let dirs = keys.map { $0 + "/" }
        return listing.entries.filter { e in !e.isDir && (keys.contains(e.path) || dirs.contains { e.path.hasPrefix($0) }) }.map(\.path)
    }

    /// 包里的原始路径 → 解出来以后的路径（旧编码 zip 解出来是修好的名字）
    func shownPath(_ id: String) -> String {
        guard let listing, let fixer else { return id }
        let raw = id.split(separator: "/").map(String.init)
        guard let e = listing.entries.first(where: { $0.path == id || $0.path.hasPrefix(id + "/") }) else { return id }
        let d = fixer.display(e, total: listing.entries.count).split(separator: "/").map(String.init)
        return d.count >= raw.count ? d.prefix(raw.count).joined(separator: "/") : id
    }

    /// 拖出去：真放下时才把这一项解到临时目录，交出那个文件（夹）
    func dragProvider(_ n: Node) -> NSItemProvider? {
        guard let listing, busy == nil else { return nil }
        let arc = arc, pw = password, sel = files(of: [n.id]), shown = shownPath(n.id), raw = n.id
        let p = NSItemProvider()
        p.suggestedName = (shown as NSString).lastPathComponent
        p.registerDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier, visibility: .all) { done in
            let name = (shown as NSString).lastPathComponent
            ui { dragNote = L("正在解出「\(name)」…", "Extracting “\(name)”…") }
            DispatchQueue.global(qos: .userInitiated).async {
                defer { ui { dragNote = nil } }
                let dir = FileManager.default.temporaryDirectory.appendingPathComponent("unpack-drag-\(UUID().uuidString.prefix(8))")
                let r = Engine.raw(arc, into: dir, password: pw, listing: listing, selection: sel, runner: Runner()) { p in
                    ui { dragNote = L("正在解出「\(name)」… \(Int(p.fraction * 100))%", "Extracting “\(name)”… \(Int(p.fraction * 100))%") }
                }
                let u = [shown, raw].map { dir.appendingPathComponent($0) }.first { FileManager.default.fileExists(atPath: $0.path) }
                if let u, r.code == 0 { done(u.dataRepresentation, nil) }
                else { done(nil, NSError(domain: "Unpack", code: 1, userInfo: [NSLocalizedDescriptionKey: SevenZip.classify(r).text])) }
            }
            return nil
        }
        return p
    }

    /// 双击文件：解到临时目录用默认程序打开；能改的包就盯着它，保存了就写回去
    func openInApp(_ path: String) {
        guard let listing, let e = listing.entries.first(where: { $0.path == path }), !e.isDir else { return }
        let editable = blocker == nil, dirInArc = (path as NSString).deletingLastPathComponent
        Task {
            guard let u = await extractOne(e, listing: listing) else { return }
            if editable { watching.append(Watch(file: u, dir: dirInArc, stamp: Self.stamp(u))) }
            NSWorkspace.shared.open(u)
        }
    }

    /// 有文件改过：等它停了一会儿（别的程序写完）再写回；关窗口时不等，直接写
    func syncEdits(final: Bool) {
        guard busy == nil, let listing else { return }
        for i in watching.indices {
            let now = Self.stamp(watching[i].file)
            guard now > watching[i].stamp, final || Date().timeIntervalSince(now) > 1 else { continue }
            watching[i].stamp = now
            let w = watching[i], arc = arc, name = w.file.lastPathComponent
            if final {   // 窗口没了：后台写完就算
                let pw = password
                Task.detached { _ = Editor.add([w.file], into: w.dir, arc: arc, listing: listing, password: pw, runner: Runner()) }
            } else {
                edit(L("正在把「\(name)」写回压缩包…", "Saving “\(name)” into the archive…"), done: L("已把「\(name)」的修改写回压缩包", "Saved “\(name)” into the archive")) { l, pw in
                    Editor.add([w.file], into: w.dir, arc: arc, listing: l, password: pw, runner: Runner())
                }
            }
            return   // 一次写一个
        }
    }

    func load(_ given: String? = nil) async {
        let arc = arc, g = given ?? password ?? target.password
        let (r, f) = await Task.detached { (Engine.unlock(arc, given: g), NameFixer(arc)) }.value
        fixer = f
        switch r {
        case .success(let (l, pw)):
            listing = l; password = pw; needPw = false; error = nil
            blocker = Editor.blocker(arc, listing: l, fixer: f)
            // 原来所在的文件夹被删掉、改名了：退回最外层
            if !cwd.isEmpty, !l.entries.contains(where: { $0.path == cwd || $0.path.hasPrefix(cwd + "/") }) { cwd = "" }
            checked = checked.filter { k in l.entries.contains { $0.path == k || $0.path.hasPrefix(k + "/") } }
        case .failure(let e) where e.isPassword:
            needPw = true; wrongPw = given != nil
        case .failure(let e):
            error = e.text
        }
    }

    func unlock() {
        guard !pwInput.isEmpty else { return }
        let p = pwInput
        pwInput = ""
        Task {
            await load(p)
            if !needPw, Pref.on(Pref.rememberPw) { Passwords.remember(p) }
        }
    }

    /// 在后台改包，改完重新读一遍内容
    func edit(_ label: String, done: String? = nil, _ op: @escaping (Listing, String?) -> Swift.Result<Void, ZError>) {
        guard let listing, busy == nil else { return }
        busy = label; editError = nil; savedNote = nil
        let pw = password
        Task {
            let r = await Task.detached { op(listing, pw) }.value
            switch r {
            case .failure(let e): editError = e.text
            case .success: savedNote = done
            }
            await load()
            busy = nil
        }
    }

    func add(_ urls: [URL], force: Bool = false) {
        let here = Set(nodes.map { ($0.id as NSString).lastPathComponent })
        let clash = query.isEmpty ? urls.filter { here.contains($0.lastPathComponent) }.count : 0
        if clash > 0, !force { replacing = (urls, clash); return }
        let arc = arc, dir = query.isEmpty ? cwd : ""
        edit(L("正在加进压缩包…", "Adding…")) { l, pw in Editor.add(urls, into: dir, arc: arc, listing: l, password: pw, runner: Runner()) }
    }

    func delete(_ ns: [Node]) {
        let arc = arc, paths = ns.map(\.id)
        edit(L("正在删除…", "Deleting…")) { l, pw in Editor.delete(paths, arc: arc, listing: l, password: pw, runner: Runner()) }
        checked.subtract(paths); selected = []
    }

    func rename(_ n: Node) {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !name.contains("/"), name != (n.id as NSString).lastPathComponent else { return }
        let parent = (n.id as NSString).deletingLastPathComponent
        let dest = parent.isEmpty ? name : parent + "/" + name
        if listing?.entries.contains(where: { $0.path == dest || $0.path.hasPrefix(dest + "/") }) == true {
            editError = L("这里已经有叫「\(name)」的了", "“\(name)” already exists here"); return
        }
        let arc = arc
        edit(L("正在改名…", "Renaming…")) { l, pw in Editor.rename(n.id, to: name, arc: arc, listing: l, password: pw, runner: Runner()) }
        checked.remove(n.id); selected = []
    }

    /// 空格键：把这一项单独解到临时目录，用系统的快速预览打开（RAR 7-Zip 解不了，换 unar）
    func quickLook(_ path: String) {
        guard let listing, let e = listing.entries.first(where: { $0.path == path }), !e.isDir else { return }
        Task { if let u = await extractOne(e, listing: listing) { preview = u } }
    }

    /// 把一个文件单独解到临时目录（名字和包里一样），返回解出来的文件
    func extractOne(_ e: Entry, listing: Listing) async -> URL? {
        let arc = arc, pw = password ?? "", good = ((fixer?.display(e, total: listing.entries.count) ?? e.path) as NSString).lastPathComponent
        return await Task.detached { () -> URL? in
            let fm = FileManager.default
            let dir = fm.temporaryDirectory.appendingPathComponent("unpack-preview-\(e.id)-\(UUID().uuidString.prefix(6))")
            _ = SevenZip.run(["e", "-y", "-spd", "-sccUTF-8", "-p" + pw, "-o" + dir.path, arc.path, e.path])
            func files() -> [URL] {
                guard let en = fm.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
                return en.compactMap { $0 as? URL }.filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
            }
            if files().isEmpty {
                _ = SevenZip.run(["-o", dir.path, "-f", "-D", "-nr", "-q", "-p", pw, arc.path, e.path], exe: SevenZip.unar)
            }
            guard var u = files().first else { return nil }
            if good != u.lastPathComponent {
                let g = u.deletingLastPathComponent().appendingPathComponent(good)
                if (try? fm.moveItem(at: u, to: g)) != nil { u = g }
            }
            return u
        }.value
    }
}
