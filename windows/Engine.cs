// 解压的引擎部分（不含界面）：调 7-Zip、找密码、修乱码、找分卷、解到临时文件夹再放到最终位置、压缩成 zip
// 和 Mac 版 Unpack.swift 一一对应；Windows 上 7-Zip 官方版自带 RAR 解码，-mcp= 也有效，所以不需要 unar / bsdtar
using System.Diagnostics;
using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace Unpack;

static class I18n
{
    // 界面语言跟随系统：系统界面语言是中文就显示中文，否则英文
    public static readonly bool IsZh = CultureInfo.CurrentUICulture.Name.StartsWith("zh", StringComparison.OrdinalIgnoreCase);
    public static string L(string zh, string en) => IsZh ? zh : en;
    public static string AppName => L("解压", "Unpack");

    public static string Bytes(long n)
    {
        string[] u = { "B", "KB", "MB", "GB", "TB" };
        double v = n; int i = 0;
        while (v >= 1000 && i < u.Length - 1) { v /= 1000; i++; }
        return i == 0 ? $"{n} B" : $"{v:0.#} {u[i]}";
    }

    public static string Duration(double s)
    {
        int n = (int)Math.Ceiling(s);
        if (n < 60) return L($"{n} 秒", $"{n}s");
        return L($"{n / 60} 分 {n % 60} 秒", $"{n / 60}m {n % 60}s");
    }
}

// ---- 设置：存在 %APPDATA%\Unpack\settings.json ----
class Prefs
{
    public string Dest { get; set; } = "";          // 解压到哪：空 = 压缩包旁边
    public bool TrashAfter { get; set; } = false;   // 解完把压缩包（连同分卷）移到回收站
    public bool CleanJunk { get; set; } = true;     // 删掉 __MACOSX、.DS_Store、Thumbs.db 这类垃圾
    public bool Reveal { get; set; } = true;        // 解完在资源管理器里选中
    public bool NestedTar { get; set; } = true;     // .tar.gz 这类一次解到底
    public bool QuitAfter { get; set; } = true;     // 双击压缩包打开时，全部解完自动退出
    public bool RememberPw { get; set; } = true;    // 输对的密码记进密码本

    public static readonly string Dir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "Unpack");
    static readonly string FilePath = Path.Combine(Dir, "settings.json");
    public static Prefs Current = Load();
    public static bool Volatile;   // 自测时不写盘

    static Prefs Load()
    {
        try { return JsonSerializer.Deserialize<Prefs>(File.ReadAllText(FilePath)) ?? new Prefs(); }
        catch { return new Prefs(); }
    }

    public void Save()
    {
        if (Volatile) return;
        try { Directory.CreateDirectory(Dir); File.WriteAllText(FilePath, JsonSerializer.Serialize(this, new JsonSerializerOptions { WriteIndented = true })); }
        catch { }
    }
}

// ---- 密码本：输对过的密码用 DPAPI（只有当前 Windows 用户能解开）加密存起来，遇到加密包先挨个自动试 ----
static class Passwords
{
    static readonly string FilePath = Path.Combine(Prefs.Dir, "passwords.dat");
    static readonly byte[] Entropy = Encoding.UTF8.GetBytes("com.hejun.unpack");

    public static List<string> All()
    {
        try
        {
            var plain = ProtectedData.Unprotect(File.ReadAllBytes(FilePath), Entropy, DataProtectionScope.CurrentUser);
            return JsonSerializer.Deserialize<List<string>>(plain) ?? new List<string>();
        }
        catch { return new List<string>(); }
    }

    public static void Save(List<string> list)
    {
        try
        {
            if (list.Count == 0) { File.Delete(FilePath); return; }
            Directory.CreateDirectory(Prefs.Dir);
            var data = ProtectedData.Protect(JsonSerializer.SerializeToUtf8Bytes(list), Entropy, DataProtectionScope.CurrentUser);
            File.WriteAllBytes(FilePath, data);
        }
        catch { }
    }

    public static void Remember(string p)
    {
        if (string.IsNullOrEmpty(p)) return;
        var list = All();
        list.Remove(p);
        list.Insert(0, p);   // 最近用过的排前面，下次先试
        Save(list.Take(100).ToList());
    }
}

// ---- 压缩包里的一项 ----
record Entry(int Id, string Path, long Size, bool IsDir, bool Encrypted);

class Listing
{
    public string Type = "";
    public List<Entry> Entries = new();
    public bool AnyEncrypted => Entries.Any(e => e.Encrypted);
    public long TotalSize => Entries.Sum(e => e.Size);
}

enum ZKind { NeedPassword, WrongPassword, MissingVolume, NotArchive, DiskFull, Cancelled, Failed }

class ZError
{
    public ZKind Kind; public string Message;
    public ZError(ZKind k, string m = null) { Kind = k; Message = m; }
    public bool IsPassword => Kind is ZKind.NeedPassword or ZKind.WrongPassword;
    public string Text => Kind switch
    {
        ZKind.NeedPassword => I18n.L("需要密码", "Password required"),
        ZKind.WrongPassword => I18n.L("密码不对", "Wrong password"),
        ZKind.MissingVolume => I18n.L("缺分卷：把所有分卷放进同一个文件夹再试", "A volume is missing — put all parts in the same folder"),
        ZKind.NotArchive => I18n.L("不是压缩包，或者文件已损坏", "Not an archive, or the file is damaged"),
        ZKind.Cancelled => I18n.L("已取消", "Cancelled"),
        _ => Message ?? "",
    };
}

class Result<T>
{
    public T Value; public ZError Error;
    public bool Ok => Error == null;
    public static Result<T> Success(T v) => new() { Value = v };
    public static Result<T> Fail(ZError e) => new() { Error = e };
}

// ---- 调 7-Zip ----
class Runner
{
    readonly object gate = new();
    Process process;
    public bool Cancelled { get; private set; }

    public void Cancel()
    {
        Process p;
        lock (gate) { Cancelled = true; p = process; }
        try { if (p != null && !p.HasExited) p.Kill(true); } catch { }
    }

    public bool Attach(Process p)
    {
        lock (gate) { process = p; return !Cancelled; }
    }
}

static class SevenZip
{
    // 7z.exe 和 7z.dll 放在解压.exe 旁边；没有就用装好的 7-Zip
    public static string Bin
    {
        get
        {
            var local = Path.Combine(AppContext.BaseDirectory, "7z.exe");
            if (File.Exists(local)) return local;
            var pf = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "7-Zip", "7z.exe");
            return File.Exists(pf) ? pf : local;
        }
    }

    public class Res { public int Code; public string Out = ""; public string Err = ""; public string All => Out + "\n" + Err; }

    /// 跑一次 7z.exe；onOut 收到标准输出的每一块（进度百分比在里面，用退格刷新，没有换行）
    public static Res Run(IEnumerable<string> args, Runner runner = null, Action<string> onOut = null)
    {
        var psi = new ProcessStartInfo(Bin)
        {
            UseShellExecute = false, CreateNoWindow = true,
            RedirectStandardOutput = true, RedirectStandardError = true, RedirectStandardInput = true,
            StandardOutputEncoding = Encoding.UTF8, StandardErrorEncoding = Encoding.UTF8,
        };
        foreach (var a in args) psi.ArgumentList.Add(a);
        var p = new Process { StartInfo = psi };
        if (runner != null && !runner.Attach(p)) return new Res { Code = 255 };
        try { p.Start(); }
        catch (Exception e) { return new Res { Code = -1, Err = e.Message }; }
        p.StandardInput.Close();   // 万一 7-Zip 想问问题，直接读到空，不会卡住
        var outSb = new StringBuilder();
        var errTask = p.StandardError.ReadToEndAsync();
        var buf = new char[4096];
        int n;
        while ((n = p.StandardOutput.Read(buf, 0, buf.Length)) > 0)
        {
            var s = new string(buf, 0, n);
            outSb.Append(s);
            onOut?.Invoke(s);
        }
        p.WaitForExit();
        return new Res { Code = p.ExitCode, Out = outSb.ToString().Replace("\r\n", "\n"), Err = errTask.Result.Replace("\r\n", "\n") };
    }

    /// 把 7-Zip 的报错翻译成人话
    public static ZError Classify(Res r, Runner runner = null)
    {
        if (runner?.Cancelled == true) return new ZError(ZKind.Cancelled);
        var s = r.All;
        if (s.Contains("Wrong password") || s.Contains("Incorrect passphrase") || s.Contains("This archive requires a password") || s.Contains("Passphrase required"))
            return new ZError(ZKind.WrongPassword);
        if (s.Contains("Missing volume") || (s.Contains("There are some data after the end") && s.Contains("volume")))
            return new ZError(ZKind.MissingVolume);
        if (s.Contains("Unexpected end of archive"))
            return new ZError(ZKind.Failed, I18n.L("压缩包不完整（没下载完，或缺分卷）", "The archive is incomplete (unfinished download or missing volume)"));
        if (s.Contains("Cannot open the file as archive") || s.Contains("Can not open the file as archive"))
            return new ZError(ZKind.NotArchive);
        if (s.Contains("There is not enough space on the disk") || s.Contains("not enough space"))
            return new ZError(ZKind.DiskFull, I18n.L("磁盘空间不够", "Not enough disk space"));
        if (s.Contains("CRC Failed") || s.Contains("Data Error"))
            return new ZError(ZKind.Failed, I18n.L("数据校验失败，压缩包可能已损坏", "Checksum failed — the archive may be damaged"));
        var line = s.Split('\n').FirstOrDefault(l => l.StartsWith("ERROR"));
        return new ZError(ZKind.Failed, line ?? I18n.L($"解压失败（错误码 {r.Code}）", $"Failed (code {r.Code})"));
    }

    /// 文件名编码参数：旧编码的 zip 告诉 7-Zip 用哪个代码页
    public static IEnumerable<string> Cp(int? codePage) => codePage is int c ? new[] { "-mcp=" + c } : Array.Empty<string>();

    public static Result<Listing> List(string arc, string password, int? codePage)
    {
        var r = Run(new[] { "l", "-slt", "-sccUTF-8", "-p" + password }.Concat(Cp(codePage)).Append(arc));
        if (r.Code != 0 || r.All.Contains("Wrong password")) return Result<Listing>.Fail(Classify(r));
        return Result<Listing>.Success(Parse(r.Out));
    }

    /// 用最小的一个加密文件验证密码（不用把整个包解一遍）
    public static bool Test(string arc, string password, Entry probe, int? codePage)
    {
        var r = Run(new[] { "t", "-spd", "-sccUTF-8", "-p" + password }.Concat(Cp(codePage)).Append(arc).Append(probe.Path));
        return r.Code == 0 && !r.All.Contains("Wrong password");
    }

    /// 解析 `7z l -slt`：头部是压缩包本身的属性，"----------" 之后每个空行分隔一项
    public static Listing Parse(string output)
    {
        var listing = new Listing();
        var parts = output.Split("\n----------\n");
        foreach (var line in parts[0].Split('\n'))
            if (line.StartsWith("Type = ")) listing.Type = line[7..];
        if (parts.Length < 2) return listing;
        foreach (var block in string.Join("\n", parts.Skip(1)).Split("\n\n"))
        {
            var f = new Dictionary<string, string>();
            foreach (var line in block.Split('\n'))
            {
                int i = line.IndexOf(" = ", StringComparison.Ordinal);
                if (i > 0) f[line[..i]] = line[(i + 3)..];
            }
            if (!f.TryGetValue("Path", out var path) || path.Length == 0) continue;
            f.TryGetValue("Size", out var size);
            f.TryGetValue("Attributes", out var attr);
            listing.Entries.Add(new Entry(listing.Entries.Count, path, long.TryParse(size, out var sz) ? sz : 0,
                f.GetValueOrDefault("Folder") == "+" || (attr ?? "").StartsWith("D"), f.GetValueOrDefault("Encrypted") == "+"));
        }
        return listing;
    }
}

// ---- 乱码修复 ----
// 别的电脑上做的 zip 可能用 GBK（日文 Shift-JIS、繁体 Big5）存文件名、又不打 UTF-8 标记；7-Zip 默认按本机的 OEM 代码页解，
// 在英文/日文 Windows 上中文名就乱了。所以先从 zip 中央目录读出原始字节判断真正的编码，再用 -mcp= 告诉 7-Zip。
static class NameFixer
{
    static NameFixer() { Encoding.RegisterProvider(CodePagesEncodingProvider.Instance); }

    static Encoding Strict(int cp) => Encoding.GetEncoding(cp, EncoderFallback.ExceptionFallback, DecoderFallback.ExceptionFallback);

    /// 该给 7-Zip 传的代码页；不是 zip、或者文件名都是 ASCII / 已打 UTF-8 标记就返回 null
    public static int? CodePage(string arc)
    {
        var legacy = RawNames(arc).Where(r => !r.Utf8Flag && r.Bytes.Any(b => b > 127)).Select(r => r.Bytes).ToList();
        return Detect(legacy);
    }

    /// 按顺序读出 zip 中央目录里每一项的原始文件名字节，以及有没有打 UTF-8 标记
    public static List<(byte[] Bytes, bool Utf8Flag)> RawNames(string arc)
    {
        var names = new List<(byte[], bool)>();
        try
        {
            using var fs = File.OpenRead(arc);
            long size = fs.Length;
            if (size <= 22) return names;
            int tailLen = (int)Math.Min(size, 65_557);
            fs.Seek(size - tailLen, SeekOrigin.Begin);
            var tail = ReadExactly(fs, tailLen);
            static int U16(byte[] b, int i) => b[i] | b[i + 1] << 8;
            static ulong U32(byte[] b, int i) => (ulong)(uint)U16(b, i) | (ulong)(uint)U16(b, i + 2) << 16;
            static ulong U64(byte[] b, int i) => U32(b, i) | U32(b, i + 4) << 32;
            int eocd = -1;
            for (int i = tail.Length - 22; i >= 0; i--)
                if (tail[i] == 0x50 && tail[i + 1] == 0x4b && tail[i + 2] == 5 && tail[i + 3] == 6) { eocd = i; break; }
            if (eocd < 0) return names;
            ulong cdSize = U32(tail, eocd + 12), cdOff = U32(tail, eocd + 16);
            if (cdOff == 0xFFFF_FFFF && eocd >= 20 && tail[eocd - 20] == 0x50 && tail[eocd - 19] == 0x4b && tail[eocd - 18] == 6 && tail[eocd - 17] == 7)
            {
                // zip64：真正的目录位置记在 zip64 结尾记录里
                fs.Seek((long)U64(tail, eocd - 20 + 8), SeekOrigin.Begin);
                var z = ReadExactly(fs, 56);
                if (z.Length != 56) return names;
                cdSize = U64(z, 40); cdOff = U64(z, 48);
            }
            if (cdSize >= 64 << 20 || cdOff + cdSize > (ulong)size) return names;
            fs.Seek((long)cdOff, SeekOrigin.Begin);
            var cd = ReadExactly(fs, (int)cdSize);
            int p = 0;
            while (p + 46 <= cd.Length && cd[p] == 0x50 && cd[p + 1] == 0x4b && cd[p + 2] == 1 && cd[p + 3] == 2)
            {
                int flags = U16(cd, p + 8), n = U16(cd, p + 28), x = U16(cd, p + 30), c = U16(cd, p + 32);
                if (p + 46 + n > cd.Length) break;
                names.Add((cd[(p + 46)..(p + 46 + n)], (flags & 0x800) != 0));
                p += 46 + n + x + c;
            }
        }
        catch { }
        return names;
    }

    static byte[] ReadExactly(Stream s, int n)
    {
        var b = new byte[n];
        int got = 0, r;
        while (got < n && (r = s.Read(b, got, n - got)) > 0) got += r;
        return got == n ? b : b[..got];
    }

    /// 猜编码：UTF-8 → 简体 GBK（国标常用汉字区占多数）→ 日文 Shift-JIS → 繁体 Big5 → GBK 兜底
    public static int? Detect(List<byte[]> names)
    {
        if (names.Count == 0) return null;
        bool All(int cp)
        {
            var e = cp == 65001 ? new UTF8Encoding(false, true) : Strict(cp);
            foreach (var d in names) { try { e.GetString(d); } catch { return false; } }
            return true;
        }
        if (All(65001)) return 65001;   // 没打标记的 UTF-8（Mac 访达做的 zip），也明确告诉 7-Zip
        int pairs = 0, common = 0;
        foreach (var b in names)
        {
            int i = 0;
            while (i < b.Length)
            {
                if (b[i] > 127 && i + 1 < b.Length)
                {
                    pairs++;
                    if (b[i] >= 0xB0 && b[i] <= 0xF7 && b[i + 1] >= 0xA1) common++;
                    i += 2;
                }
                else i++;
            }
        }
        if (pairs > 0 && (double)common / pairs > 0.6 && All(936)) return 936;
        if (All(932)) return 932;
        if (All(950)) return 950;
        return All(936) ? 936 : null;
    }

    public static string Charset(int? cp) => cp switch { 936 => "GBK", 932 => "Shift-JIS", 950 => "Big5", 65001 => "UTF-8", _ => "-" };
}

// ---- 认压缩包、找分卷 ----
static class Archive
{
    public static readonly HashSet<string> Exts = new(StringComparer.OrdinalIgnoreCase)
    {
        "zip", "7z", "rar", "tar", "gz", "tgz", "bz2", "tbz", "tbz2", "xz", "txz", "zst", "tzst",
        "lz", "lzma", "tlz", "z", "taz", "cab", "iso", "arj", "lzh", "lha", "wim", "cpio",
        "rpm", "deb", "xar", "squashfs", "001", "zipx", "jar", "apk", "ipa", "vhd", "vhdx", "vmdk",
    };
    // 名字里的分卷写法：xxx.part3.rar / xxx.7z.002 / xxx.z01 / xxx.r00
    static readonly Regex PartRar = new(@"^(.*)\.part(\d+)\.rar$", RegexOptions.IgnoreCase);
    static readonly Regex Numbered = new(@"^(.*\.[a-z0-9]+)\.(\d{3})$", RegexOptions.IgnoreCase);
    static readonly Regex Zxx = new(@"^(.*)\.z(\d{2})$", RegexOptions.IgnoreCase);
    static readonly Regex Rxx = new(@"^(.*)\.r(\d{2})$", RegexOptions.IgnoreCase);

    static string[] Groups(Regex re, string s)
    {
        var m = re.Match(s);
        return m.Success ? m.Groups.Cast<Group>().Skip(1).Select(g => g.Value).ToArray() : null;
    }

    static string Ext(string name) => Path.GetExtension(name).TrimStart('.');

    public static bool IsArchive(string path)
    {
        if (!File.Exists(path)) return false;
        var n = Path.GetFileName(path);
        return Exts.Contains(Ext(n)) || new[] { Numbered, Zxx, Rxx }.Any(re => Groups(re, n) != null);
    }

    /// 不管拖进来的是第几卷，都换成第一卷（7-Zip 要从第一卷开始读）
    public static string FirstVolume(string path)
    {
        var dir = Path.GetDirectoryName(path) ?? "";
        var n = Path.GetFileName(path);
        var cands = new List<string>();
        if (Groups(PartRar, n) is { } g1) cands.Add(g1[0] + ".part" + new string('0', g1[1].Length - 1) + "1.rar");
        if (Groups(Numbered, n) is { } g2) cands.Add(g2[0] + ".001");
        if (Groups(Zxx, n) is { } g3) cands.Add(g3[0] + ".zip");
        if (Groups(Rxx, n) is { } g4) cands.Add(g4[0] + ".rar");
        foreach (var c in cands)
            if (File.Exists(Path.Combine(dir, c))) return Path.Combine(dir, c);
        return path;
    }

    /// 同一套分卷的全部文件（解完移到回收站时一起移）
    public static List<string> Volumes(string first)
    {
        var dir = Path.GetDirectoryName(first) ?? "";
        var n = Path.GetFileName(first);
        var files = Directory.Exists(dir) ? Directory.GetFiles(dir).Select(Path.GetFileName).ToArray() : Array.Empty<string>();
        var set = new HashSet<string>(StringComparer.OrdinalIgnoreCase) { n };
        if (Groups(PartRar, n) is { } g1) set.UnionWith(files.Where(f => Groups(PartRar, f)?[0] == g1[0]));
        if (Groups(Numbered, n) is { } g2) set.UnionWith(files.Where(f => Groups(Numbered, f)?[0] == g2[0]));
        if (n.EndsWith(".zip", StringComparison.OrdinalIgnoreCase)) { var b = n[..^4]; set.UnionWith(files.Where(f => Groups(Zxx, f)?[0] == b)); }
        if (n.EndsWith(".rar", StringComparison.OrdinalIgnoreCase) && Groups(PartRar, n) == null) { var b = n[..^4]; set.UnionWith(files.Where(f => Groups(Rxx, f)?[0] == b)); }
        return set.OrderBy(x => x, StringComparer.OrdinalIgnoreCase).Select(f => Path.Combine(dir, f)).ToList();
    }

    /// 压缩包去掉各种后缀后的名字，用来起文件夹名：照片.part1.rar → 照片，代码.tar.gz → 代码
    public static string BaseName(string path)
    {
        var n = Path.GetFileName(path);
        if (Groups(PartRar, n) is { } g1) return g1[0];
        if (Groups(Numbered, n) is { } g2) n = g2[0];
        for (int i = 0; i < 2; i++)
        {
            var e = Ext(n);
            if (e.Length == 0 || !(Exts.Contains(e) || e.Equals("tar", StringComparison.OrdinalIgnoreCase))) break;
            n = Path.GetFileNameWithoutExtension(n);
        }
        return n.Length == 0 ? I18n.L("解压", "Extracted") : n;
    }
}

static class Fs
{
    /// 同名已存在就加编号：资料 → 资料 2 → 资料 3
    public static string Unique(string path)
    {
        if (!File.Exists(path) && !Directory.Exists(path)) return path;
        var dir = Path.GetDirectoryName(path) ?? "";
        var name = Path.GetFileName(path);
        bool isDir = Directory.Exists(path);
        var ext = isDir ? "" : Path.GetExtension(name);
        var b = isDir ? name : Path.GetFileNameWithoutExtension(name);
        for (int i = 2; ; i++)
        {
            var c = Path.Combine(dir, $"{b} {i}{ext}");
            if (!File.Exists(c) && !Directory.Exists(c)) return c;
        }
    }

    public static long SizeOf(string path)
    {
        try
        {
            if (File.Exists(path)) return new FileInfo(path).Length;
            if (Directory.Exists(path))
                return new DirectoryInfo(path).EnumerateFiles("*", SearchOption.AllDirectories).Sum(f => { try { return f.Length; } catch { return 0L; } });
        }
        catch { }
        return 0;
    }

    public static void Move(string from, string to)
    {
        if (Directory.Exists(from)) Directory.Move(from, to); else File.Move(from, to);
    }

    // 从网上下载的压缩包带「网络标记」（Zone.Identifier），解出来的文件也带上（和系统自带的解压一样），陌生程序第一次打开时系统照常检查
    public static void CopyZone(string arc, string root)
    {
        string zone;
        try { zone = File.ReadAllText(arc + ":Zone.Identifier"); } catch { return; }
        IEnumerable<string> all = Directory.Exists(root) ? Directory.EnumerateFiles(root, "*", SearchOption.AllDirectories) : new[] { root };
        foreach (var f in all) { try { File.WriteAllText(f + ":Zone.Identifier", zone); } catch { } }
    }
}

// ---- 解压/压缩：找密码、解到隐藏的临时文件夹、去垃圾、拆 tar、放到最终位置 ----
static class Engine
{
    public record Progress(double Fraction, string Text);

    public static string TestDest;   // 自测时临时指定，不写进设置

    /// 读出内容，并找到能用的密码：先用给定的，没给就从密码本里挨个试
    public static Result<(Listing, string)> Unlock(string arc, string given, int? cp)
    {
        List<string> saved = null;
        List<string> Book() => saved ??= Passwords.All();
        var l = SevenZip.List(arc, given ?? "", cp);
        if (!l.Ok)
        {
            if (l.Error.Kind != ZKind.WrongPassword) return Result<(Listing, string)>.Fail(l.Error);
            // 文件名也加密了（7z/rar 的「加密文件名」）
            if (given != null) return Result<(Listing, string)>.Fail(new ZError(ZKind.WrongPassword));
            foreach (var c in Book())
            {
                var t = SevenZip.List(arc, c, cp);
                if (t.Ok) return Result<(Listing, string)>.Success((t.Value, c));
            }
            return Result<(Listing, string)>.Fail(new ZError(ZKind.NeedPassword));
        }
        var probe = l.Value.Entries.Where(e => e.Encrypted && !e.IsDir).OrderBy(e => e.Size).FirstOrDefault();
        if (probe == null) return Result<(Listing, string)>.Success((l.Value, given));
        if (given != null)
            return SevenZip.Test(arc, given, probe, cp) ? Result<(Listing, string)>.Success((l.Value, given)) : Result<(Listing, string)>.Fail(new ZError(ZKind.WrongPassword));
        foreach (var c in Book())
            if (SevenZip.Test(arc, c, probe, cp)) return Result<(Listing, string)>.Success((l.Value, c));
        return Result<(Listing, string)>.Fail(new ZError(ZKind.NeedPassword));
    }

    static bool Writable(string dir)
    {
        try
        {
            if (!Directory.Exists(dir)) return false;
            var t = Path.Combine(dir, ".unpack-" + Guid.NewGuid().ToString("N")[..6]);
            File.WriteAllText(t, ""); File.Delete(t);
            return true;
        }
        catch { return false; }
    }

    public static string Downloads => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "Downloads");

    public static string DestDir(string src)
    {
        var d = TestDest ?? Prefs.Current.Dest;
        if (!string.IsNullOrEmpty(d) && Writable(d)) return d;
        var beside = Path.GetDirectoryName(Path.GetFullPath(src)) ?? Downloads;
        // 压缩包在只读的地方（光盘、别人共享的盘），就放到「下载」
        return Writable(beside) ? beside : Downloads;
    }

    public static Result<string> Extract(string arc, string password, Listing listing, List<string> selection, int? cp, Runner runner, Action<Progress> progress)
    {
        var parent = DestDir(arc);
        long need = selection == null ? listing.TotalSize : listing.Entries.Where(e => selection.Contains(e.Path)).Sum(e => e.Size);
        try
        {
            long free = new DriveInfo(Path.GetPathRoot(Path.GetFullPath(parent))!).AvailableFreeSpace;
            if (free > 0 && need > free)
                return Result<string>.Fail(new ZError(ZKind.DiskFull, I18n.L($"磁盘空间不够：解开要 {I18n.Bytes(need)}，只剩 {I18n.Bytes(free)}", $"Not enough space: needs {I18n.Bytes(need)}, {I18n.Bytes(free)} free")));
        }
        catch { }
        var tmp = Path.Combine(parent, ".解压中-" + Guid.NewGuid().ToString("N")[..8]);
        try
        {
            try { Directory.CreateDirectory(tmp); File.SetAttributes(tmp, FileAttributes.Directory | FileAttributes.Hidden); }
            catch { return Result<string>.Fail(new ZError(ZKind.Failed, I18n.L($"没法在「{Path.GetFileName(parent)}」里写文件", $"Can't write to “{Path.GetFileName(parent)}”"))); }

            var args = new List<string> { "x", "-y", "-bsp1", "-bso0", "-bse2", "-sccUTF-8", "-p" + (password ?? ""), "-o" + tmp };
            args.AddRange(SevenZip.Cp(cp));
            args.Add(arc);
            string listFile = null;
            if (selection != null)
            {
                listFile = Path.Combine(Path.GetTempPath(), $"unpack-{Guid.NewGuid():N}.txt");
                File.WriteAllText(listFile, string.Join("\n", selection), new UTF8Encoding(false));
                args.AddRange(new[] { "-spd", "-scsUTF-8", "@" + listFile });
            }
            var label = I18n.L("解压", "Extracting") + (cp is int c && c != 65001 ? I18n.L($"（按 {NameFixer.Charset(cp)} 修正文件名）", $" (names as {NameFixer.Charset(cp)})") : "");
            var r = Run7z(args, need, label, runner, progress);
            if (listFile != null) try { File.Delete(listFile); } catch { }
            if (r.Code != 0) return Result<string>.Fail(SevenZip.Classify(r, runner));

            if (Prefs.Current.CleanJunk) RemoveJunk(tmp);
            var root = tmp;
            // .tar.gz / .tgz：第一层只解出一个 .tar，接着把 tar 也解开
            var items = Visible(root);
            if (Prefs.Current.NestedTar && items.Count == 1 && items[0].EndsWith(".tar", StringComparison.OrdinalIgnoreCase) && File.Exists(items[0]))
            {
                var inner = Path.Combine(tmp, ".tar-" + Guid.NewGuid().ToString("N")[..6]);
                Directory.CreateDirectory(inner);
                var r2 = Run7z(new[] { "x", "-y", "-bsp1", "-bso0", "-bse2", "-sccUTF-8", "-o" + inner, items[0] }, Fs.SizeOf(items[0]),
                    I18n.L("解开 tar", "Unpacking tar"), runner, progress);
                if (r2.Code != 0) return Result<string>.Fail(SevenZip.Classify(r2, runner));
                File.Delete(items[0]);
                if (Prefs.Current.CleanJunk) RemoveJunk(inner);
                root = inner;
                items = Visible(root);
            }
            if (items.Count == 0) return Result<string>.Fail(new ZError(ZKind.Failed, I18n.L("压缩包是空的", "The archive is empty")));
            Fs.CopyZone(arc, root);

            // 放到最终位置：只有一个顶层文件夹/文件就直接放出来，零散的多个就装进以压缩包命名的文件夹
            string final;
            if (items.Count == 1)
            {
                final = Fs.Unique(Path.Combine(parent, Path.GetFileName(items[0])));
                Fs.Move(items[0], final);
            }
            else
            {
                final = Fs.Unique(Path.Combine(parent, Archive.BaseName(arc)));
                Directory.CreateDirectory(final);
                foreach (var u in items) Fs.Move(u, Path.Combine(final, Path.GetFileName(u)));
            }
            return Result<string>.Success(final);
        }
        catch (Exception e)
        {
            return Result<string>.Fail(new ZError(ZKind.Failed, e.Message));
        }
        finally
        {
            try { if (Directory.Exists(tmp)) Directory.Delete(tmp, true); } catch { }
        }
    }

    public static Result<string> Compress(List<string> srcs, Runner runner, Action<Progress> progress)
    {
        var parent = DestDir(srcs[0]);
        var name = srcs.Count == 1 ? Path.GetFileName(srcs[0].TrimEnd('\\', '/')) : I18n.L("归档", "Archive");
        var output = Fs.Unique(Path.Combine(parent, name + ".zip"));
        long total = srcs.Sum(Fs.SizeOf);
        // -mcu=on：文件名一律存 UTF-8 并打标记，到哪台电脑上都不乱码；不带 Mac 的 .DS_Store 和 ._ 资源文件
        var args = new List<string> { "a", "-tzip", "-mcu=on", "-mx=5", "-bsp1", "-bso0", "-bse2", "-sccUTF-8",
            "-xr!.DS_Store", "-xr!__MACOSX", "-xr!._*", "-xr!Thumbs.db", output };
        args.AddRange(srcs);
        var r = Run7z(args, total, I18n.L("压缩", "Compressing"), runner, progress);
        if (r.Code != 0) { try { File.Delete(output); } catch { } return Result<string>.Fail(SevenZip.Classify(r, runner)); }
        return Result<string>.Success(output);
    }

    static readonly Regex Pct = new(@"(\d+)%");

    /// 跑 7z 并把输出里的百分比换算成进度、速度、剩余时间
    static SevenZip.Res Run7z(IEnumerable<string> args, long total, string label, Runner runner, Action<Progress> progress)
    {
        var sw = Stopwatch.StartNew();
        int last = -1;
        return SevenZip.Run(args, runner, chunk =>
        {
            var ms = Pct.Matches(chunk);
            if (ms.Count == 0) return;
            int pct = int.Parse(ms[^1].Groups[1].Value);
            if (pct == last) return;
            last = pct;
            double t = sw.Elapsed.TotalSeconds;
            var text = $"{label} {pct}%";
            if (pct >= 2 && t > 0.8 && total > 0)
            {
                double speed = total * pct / 100.0 / t, left = t * (100 - pct) / pct;
                text += $" · {I18n.Bytes((long)speed)}/s · " + I18n.L("还剩 ", "") + I18n.Duration(left) + I18n.L("", " left");
            }
            progress?.Invoke(new Progress(pct / 100.0, text));
        });
    }

    static readonly HashSet<string> Junk = new(StringComparer.OrdinalIgnoreCase) { "__MACOSX", ".DS_Store", "Thumbs.db", "desktop.ini", "ehthumbs.db" };

    public static void RemoveJunk(string root)
    {
        try
        {
            foreach (var d in Directory.GetDirectories(root, "__MACOSX", SearchOption.AllDirectories)) { try { Directory.Delete(d, true); } catch { } }
            foreach (var f in Directory.EnumerateFiles(root, "*", SearchOption.AllDirectories).ToList())
            {
                var n = Path.GetFileName(f);
                if (Junk.Contains(n) || n.StartsWith("._")) { try { File.SetAttributes(f, FileAttributes.Normal); File.Delete(f); } catch { } }
            }
        }
        catch { }
    }

    public static List<string> Visible(string dir) =>
        Directory.EnumerateFileSystemEntries(dir)
            .Where(p => !Path.GetFileName(p).StartsWith(".tar-"))   // 拆 tar 用的临时夹不算
            .OrderBy(p => p, StringComparer.OrdinalIgnoreCase).ToList();
}
