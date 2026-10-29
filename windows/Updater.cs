// 自动更新：每次打开问一下 GitHub 最新发布版；有新版就在后台把安装包下好，关掉解压时静默装上，下次打开就是新版
// 状态栏会提示「已下好，关掉后自动装上 · 现在装」，点了立刻装、装完重新打开（设置、密码本都在 %APPDATA%，不受影响）；
// 不是装出来的（v1.0 的 zip 版）换不了自己，只提示，点了打开下载页
using System.Diagnostics;
using System.Text.Json;

namespace Unpack;

static class Updater
{
    const string Api = "https://api.github.com/repos/Hejun-Coderlife/mac-unpack/releases/latest";
    public const string Page = "https://github.com/Hejun-Coderlife/mac-unpack/releases/latest";
    const string AssetName = "Unpack-Setup.exe";
    public static readonly Version Current = typeof(Updater).Assembly.GetName().Version ?? new Version(0, 0);

    public enum State { Idle, Available, Downloading, Ready, Working, Failed }
    public static State Now = State.Idle;
    public static event Action Changed;

    /// 装在安装版的位置（旁边有卸载程序）才能自己换新
    static bool Installed => File.Exists(Path.Combine(AppContext.BaseDirectory, "unins000.exe"));

    /// "1.10" 比 "1.9" 新：按点分开逐段比数字（Version 类会把 1.1 和 1.1.0.0 当成不一样）
    public static bool Newer(string a, Version b)
    {
        var x = a.Split('.').Select(s => int.TryParse(s, out var n) ? n : 0).ToArray();
        int[] y = { b.Major, Math.Max(0, b.Minor), Math.Max(0, b.Build), Math.Max(0, b.Revision) };
        for (int i = 0; i < Math.Max(x.Length, y.Length); i++)
        {
            int p = i < x.Length ? x[i] : 0, q = i < y.Length ? y[i] : 0;
            if (p != q) return p > q;
        }
        return false;
    }

    static HttpClient Client()
    {
        var h = new HttpClient { Timeout = TimeSpan.FromMinutes(5) };
        h.DefaultRequestHeaders.UserAgent.ParseAdd($"Unpack/{Current}");   // GitHub 接口要求带 User-Agent
        return h;
    }

    static void Set(State s) { Now = s; Changed?.Invoke(); }

    static string UpdateDir => Path.Combine(Path.GetTempPath(), "Unpack-update");

    /// 下好的安装包还在、而且确实比现在新
    static bool HasReady(out string file)
    {
        var p = Prefs.Current;
        file = p.ReadySetup;
        return !string.IsNullOrEmpty(file) && File.Exists(file) && Newer(p.LatestVersion, Current);
    }

    /// 上次查到的新版还没装：直接提示（自动更新开着就接着下），不用再联网
    static void ShowPending()
    {
        var v = Prefs.Current.LatestVersion;
        if (Now != State.Idle || string.IsNullOrEmpty(v) || !Newer(v, Current)) return;
        if (HasReady(out _)) Set(State.Ready);
        else if (Installed && Prefs.Current.AutoUpdate) Download();
        else Set(State.Available);
    }

    /// 后台把新版安装包下到临时目录；下完检查一下确实是个程序（开头是 MZ），免得装一个半截文件
    static async void Download()
    {
        var p = Prefs.Current;
        if (string.IsNullOrEmpty(p.LatestAsset)) { Set(State.Available); return; }
        Set(State.Downloading);
        try
        {
            Directory.CreateDirectory(UpdateDir);
            var file = Path.Combine(UpdateDir, $"Unpack-Setup-{p.LatestVersion}.exe");
            byte[] data;
            using (var http = Client()) data = await http.GetByteArrayAsync(p.LatestAsset);
            if (data.Length < 100_000 || data[0] != 'M' || data[1] != 'Z') throw new InvalidDataException();
            await File.WriteAllBytesAsync(file, data);
            p.ReadySetup = file; p.Save();
            Set(State.Ready);
        }
        catch { Set(State.Available); }   // 没下成：退回「有新版本 · 更新」，点了再试
    }

    /// 程序退出时调：有下好的新版就静默装上（不重新打开），下次打开就是新版
    public static void InstallOnExit()
    {
        if (!Installed || !Prefs.Current.AutoUpdate || !HasReady(out var file)) return;
        try { Process.Start(new ProcessStartInfo(file, "/VERYSILENT /SUPPRESSMSGBOXES /NORESTART") { UseShellExecute = true }); }
        catch { }
    }

    public static async void Check()
    {
        var p = Prefs.Current;
        if (!p.AutoUpdate) return;
        ShowPending();
        try
        {
            using var http = Client();
            http.DefaultRequestHeaders.Accept.ParseAdd("application/vnd.github+json");
            var j = JsonDocument.Parse(await http.GetStringAsync(Api)).RootElement;
            var tag = (j.GetProperty("tag_name").GetString() ?? "").TrimStart('v', 'V');
            var asset = j.GetProperty("assets").EnumerateArray()
                .Where(a => a.GetProperty("name").GetString() == AssetName)
                .Select(a => a.GetProperty("browser_download_url").GetString()).FirstOrDefault();
            if (asset == null) return;   // 新版的安装包还没传上去：下次再看
            if (tag != p.LatestVersion) p.ReadySetup = "";   // 又出了更新的版本：之前下的作废
            p.LastUpdateCheck = DateTime.UtcNow; p.LatestVersion = tag; p.LatestAsset = asset; p.Save();
            ShowPending();
        }
        catch { }
    }

    public static async void Install()
    {
        var p = Prefs.Current;
        if (!Installed || string.IsNullOrEmpty(p.LatestAsset)) { OpenPage(); return; }
        Set(State.Working);
        try
        {
            if (!HasReady(out var file))
            {
                file = Path.Combine(Path.GetTempPath(), $"Unpack-Setup-{p.LatestVersion}.exe");
                using (var http = Client()) await File.WriteAllBytesAsync(file, await http.GetByteArrayAsync(p.LatestAsset));
            }
            p.ReadySetup = ""; p.Save();   // 马上要装了：退出时别再装一遍
            Process.Start(new ProcessStartInfo(file, "/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /RELAUNCH=1") { UseShellExecute = true });
            Application.Exit();
        }
        catch { Set(State.Failed); }
    }

    public static void OpenPage()
    {
        try { Process.Start(new ProcessStartInfo(Page) { UseShellExecute = true }); } catch { }
    }
}
