// 解压（Unpack）Windows 版入口：只开一个窗口（再双击压缩包会交给已经开着的窗口）、自测模式、资源管理器右键菜单
// 自测（不弹窗口）：set UNPACK_TEST=a.zip;b.7z  [UNPACK_DEST=目录] [UNPACK_PW=密码] [UNPACK_SAVE=先存进密码本的密码] [UNPACK_LOG=结果文件]
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

        ApplicationConfiguration.Initialize();
        var form = new MainForm();
        Ui.Context = SynchronizationContext.Current ?? new WindowsFormsSynchronizationContext();
        if (first) Listen(form);
        if (args.Length > 0)
        {
            JobQueue.Shared.OpenedByShell = true;
            form.Shown += (_, _) => JobQueue.Shared.Add(args);
        }
        Application.Run(form);
        JobQueue.Shared.CancelAll();
        return 0;
    }

    /// 已经开着一个了：把要处理的文件交给它，自己退出
    static bool Forward(string[] args)
    {
        try
        {
            using var c = new NamedPipeClientStream(".", PipeName, PipeDirection.Out);
            c.Connect(1500);
            var data = Encoding.UTF8.GetBytes(string.Join("\n", args.Select(Path.GetFullPath)));
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
                        if (paths.Length > 0) { JobQueue.Shared.OpenedByShell = true; JobQueue.Shared.Add(paths); }
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
                var c = Engine.Compress(new List<string> { u }, new Runner(), null);
                Say($"COMPRESS {Path.GetFileName(u)} → " + (c.Ok ? c.Value : "FAIL " + c.Error.Text));
                if (!c.Ok) failed++;
                continue;
            }
            var arc = Archive.FirstVolume(u);
            var cp = NameFixer.CodePage(arc);
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

/// 资源管理器右键菜单「用解压处理」：只写当前用户的注册表（HKCU），不要管理员权限
static class ContextMenu
{
    static readonly string[] Keys = { @"Software\Classes\*\shell\Unpack", @"Software\Classes\Directory\shell\Unpack" };

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
        }
        catch { }
    }
}
