// 解压（Unpack）Windows 版入口：只开一个窗口（再双击压缩包会交给已经开着的窗口）、自测模式、资源管理器右键菜单
// 自测（不弹窗口）：set UNPACK_TEST=a.zip;b.7z  [UNPACK_DEST=目录] [UNPACK_PW=密码] [UNPACK_SAVE=先存进密码本的密码] [UNPACK_LOG=结果文件]
//   压缩选项（对文件夹/普通文件）：UNPACK_FORMAT=7z UNPACK_LEVEL=9 UNPACK_PW=密码 UNPACK_SPLIT=分卷MB
//   改包：UNPACK_EDIT="add<Tab>包里文件夹<Tab>本机文件;rename<Tab>旧路径<Tab>新名字;delete<Tab>路径"，改完列出内容
using System.IO.Pipes;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32;

namespace Unpack;

static class Program
{
    static readonly string PipeName = "Unpack-" + Environment.UserName;

    [STAThread]
    static int Main(string[] args)
    {
        var test = Environment.GetEnvironmentVariable("UNPACK_TEST");
        if (test != null) return SelfTest(test);

        using var mutex = new Mutex(true, "Local\\Unpack.SingleInstance", out bool first);
        if (!first && Forward(args)) return 0;

        // 开过右键菜单的：每次打开刷新一遍（指向现在这个 解压.exe，老用户也补上新加的「查看内容」）
        if (first && ContextMenu.Installed) ContextMenu.Set(true);
        ApplicationConfiguration.Initialize();
        var form = new MainForm();
        Ui.Context = SynchronizationContext.Current ?? new WindowsFormsSynchronizationContext();
        if (first) Listen(form);
        if (args.Length > 0)
        {
            JobQueue.Shared.OpenedByShell = true;
            form.Shown += (_, _) => form.BeginInvoke(() => Handle(form, args));
        }
        Application.Run(form);
        JobQueue.Shared.CancelAll();
        Updater.InstallOnExit();
        return 0;
    }

    public const string BrowseFlag = "--browse";   // 右键「用解压查看内容」：先看内容，不解开

    /// 双击 / 右键 / 拖到图标上交进来的文件：要么先看内容，要么直接解（压）
    static void Handle(MainForm form, string[] args)
    {
        bool browse = args.Length > 0 && args[0] == BrowseFlag;
        var paths = args.Where(a => a != BrowseFlag).ToArray();
        // 设置里选了「双击先看内容」：只打开一个压缩包时先看，一次打开好几个还是直接解
        if (!browse && Prefs.Current.BrowseOnOpen && paths.Length == 1 && Archive.IsArchive(paths[0])) browse = true;
        if (browse && paths.FirstOrDefault(Archive.IsArchive) is { } a) form.Browse(Archive.FirstVolume(a));
        else if (paths.Length > 0) JobQueue.Shared.Add(paths);
    }

    /// 已经开着一个了：把要处理的文件交给它，自己退出
    static bool Forward(string[] args)
    {
        try
        {
            using var c = new NamedPipeClientStream(".", PipeName, PipeDirection.Out);
            c.Connect(1500);
            var data = Encoding.UTF8.GetBytes(string.Join("\n", args.Select(a => a == BrowseFlag ? a : Path.GetFullPath(a))));
            c.Write(data, 0, data.Length);
            return true;
        }
        catch { return false; }
    }

    static void Listen(MainForm form)
    {
        var t = new Thread(() =>
        {
            while (true)
            {
                try
                {
                    using var s = new NamedPipeServerStream(PipeName, PipeDirection.In, 1);
                    s.WaitForConnection();
                    using var ms = new MemoryStream();
                    s.CopyTo(ms);
                    var paths = Encoding.UTF8.GetString(ms.ToArray()).Split('\n', StringSplitOptions.RemoveEmptyEntries);
                    Ui.Post(() =>
                    {
                        form.BringToFrontForce();
                        if (paths.Length > 0) { JobQueue.Shared.OpenedByShell = true; Handle(form, paths); }
                    });
                }
                catch { Thread.Sleep(500); }
            }
        }) { IsBackground = true };
        t.Start();
    }

    [DllImport("kernel32.dll")] static extern bool AttachConsole(int pid);

    /// 自测：不开窗口，直接解，把结果打到标准输出（和 UNPACK_LOG 文件），有失败就返回 1
    static int SelfTest(string list)
    {
        AttachConsole(-1);
        Prefs.Volatile = true;
        Engine.TestDest = Environment.GetEnvironmentVariable("UNPACK_DEST");
        var log = new StringBuilder();
        void Say(string s) { Console.WriteLine(s); log.AppendLine(s); }
        if (Environment.GetEnvironmentVariable("UNPACK_SAVE") is { } save) Passwords.Remember(save);   // 先往密码本里存一个，测自动试密码
        int failed = 0;
        foreach (var raw in list.Split(';', '|'))
        {
            var u = raw.Trim();
            if (u.Length == 0) continue;
            if (!Archive.IsArchive(u))
            {
                var o = CompressOptions.FromPrefs();
                if (Environment.GetEnvironmentVariable("UNPACK_FORMAT") is { } fm) o.Format = fm;
                if (int.TryParse(Environment.GetEnvironmentVariable("UNPACK_LEVEL"), out var lv)) o.Level = lv;
                if (Environment.GetEnvironmentVariable("UNPACK_PW") is { } cpw) o.Password = cpw;
                if (int.TryParse(Environment.GetEnvironmentVariable("UNPACK_SPLIT"), out var sp)) o.SplitMB = sp;
                var c = Engine.Compress(new List<string> { u }, o, new Runner(), null);
                Say($"COMPRESS {Path.GetFileName(u)} → " + (c.Ok ? c.Value : "FAIL " + c.Error.Text));
                if (!c.Ok) failed++;
                continue;
            }
            var arc = Archive.FirstVolume(u);
            var cp = NameFixer.CodePage(arc);
            if (Environment.GetEnvironmentVariable("UNPACK_EDIT") is { } ops)
            {
                foreach (var op in ops.Split(';'))
                {
                    var ul = Engine.Unlock(arc, Environment.GetEnvironmentVariable("UNPACK_PW"), cp);
                    if (!ul.Ok) { Say("FAIL unlock: " + ul.Error.Text); failed++; break; }
                    var (el, epw) = ul.Value;
                    if (Editor.Blocker(arc, el, cp) is { } why) { Say("BLOCKED " + why); break; }
                    var f = op.Split('\t');
                    var er = f[0] switch
                    {
                        "add" => Editor.Add(f.Skip(2).ToList(), f[1], arc, el, epw, cp, new Runner()),
                        "rename" => Editor.Rename(f[1], f[2], arc, el, epw, cp, new Runner()),
                        _ => Editor.Delete(f.Skip(1).ToList(), arc, el, epw, cp, new Runner()),
                    };
                    Say($"EDIT {f[0]}: " + (er.Ok ? "ok" : er.Error.Text));
                    if (!er.Ok) failed++;
                }
                var now = Engine.Unlock(arc, Environment.GetEnvironmentVariable("UNPACK_PW"), cp);
                if (now.Ok)
                {
                    Say($"NOW enc={now.Value.Item1.AnyEncrypted} hdr={now.Value.Item1.HeaderEncrypted}");
                    foreach (var e in now.Value.Item1.Entries) Say($"    {e.Path} | {e.Method}");
                }
                continue;
            }
            var r = Engine.Unlock(arc, Environment.GetEnvironmentVariable("UNPACK_PW"), cp);
            if (!r.Ok) { Say($"FAIL {Path.GetFileName(u)}: {r.Error.Text}"); failed++; continue; }
            var (l, pw) = r.Value;
            Say($"LIST {Path.GetFileName(arc)} type={l.Type} n={l.Entries.Count} pw={pw ?? "-"} enc={NameFixer.Charset(cp)}");
            foreach (var e in l.Entries.Take(5)) Say("    " + e.Path);
            var x = Engine.Extract(arc, pw, l, null, cp, new Runner(), null);
            if (x.Ok) Say("OK → " + x.Value);
            else { Say("FAIL extract: " + x.Error.Text); failed++; }
        }
        if (Environment.GetEnvironmentVariable("UNPACK_LOG") is { } lf) File.WriteAllText(lf, log.ToString(), new UTF8Encoding(false));
        return failed == 0 ? 0 : 1;
    }
}

/// 资源管理器右键菜单「用解压处理」（所有文件和文件夹）+「用解压查看内容」（只在压缩包上）：只写当前用户的注册表（HKCU），不要管理员权限
static class ContextMenu
{
    static readonly string[] Keys = { @"Software\Classes\*\shell\Unpack", @"Software\Classes\Directory\shell\Unpack" };
    // SystemFileAssociations：不管这个格式默认用哪个程序打开，右键菜单里都有这一项
    public static readonly string[] BrowseExts = { ".zip", ".7z", ".rar", ".tar", ".gz", ".tgz", ".bz2", ".tbz2", ".xz", ".txz", ".zst", ".tzst",
        ".001", ".iso", ".cab", ".wim", ".lzh", ".arj" };
    static IEnumerable<string> BrowseKeys => BrowseExts.Select(e => $@"Software\Classes\SystemFileAssociations\{e}\shell\UnpackBrowse");

    public static bool Installed
    {
        get { using var k = Registry.CurrentUser.OpenSubKey(Keys[0]); return k != null; }
    }

    public static void Set(bool on)
    {
        try
        {
            var exe = Environment.ProcessPath ?? Application.ExecutablePath;
            foreach (var key in Keys)
            {
                if (!on) { Registry.CurrentUser.DeleteSubKeyTree(key, false); continue; }
                using var k = Registry.CurrentUser.CreateSubKey(key);
                k.SetValue("", I18n.L("用「解压」处理", "Open with Unpack"));
                k.SetValue("Icon", $"\"{exe}\",0");
                k.SetValue("MultiSelectModel", "Player");   // 选中多个文件时一次交给同一个程序
                using var cmd = k.CreateSubKey("command");
                cmd.SetValue("", $"\"{exe}\" \"%1\"");
            }
            foreach (var key in BrowseKeys)
            {
                if (!on) { Registry.CurrentUser.DeleteSubKeyTree(key, false); continue; }
                using var k = Registry.CurrentUser.CreateSubKey(key);
                k.SetValue("", I18n.L("用「解压」查看内容", "Browse with Unpack"));
                k.SetValue("Icon", $"\"{exe}\",0");
                using var cmd = k.CreateSubKey("command");
                cmd.SetValue("", $"\"{exe}\" {Program.BrowseFlag} \"%1\"");
            }
        }
        catch { }
    }
}
