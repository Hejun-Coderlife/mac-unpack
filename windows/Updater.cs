// 自动更新：每次打开问一下 GitHub 最新发布版；有新版就在状态栏提示，不会自己悄悄更新
// 安装版：用户点「更新」才下载新的安装包，静默装好后重新打开（设置、密码本都在 %APPDATA%，不受影响）；
// 不是装出来的（v1.0 的 zip 版）换不了自己，点了就打开下载页
using System.Diagnostics;
using System.Text.Json;

namespace Unpack;

static class Updater
{
    const string Api = "https://api.github.com/repos/Hejun-Coderlife/mac-unpack/releases/latest";
    public const string Page = "https://github.com/Hejun-Coderlife/mac-unpack/releases/latest";
    const string AssetName = "Unpack-Setup.exe";
    public static readonly Version Current = typeof(Updater).Assembly.GetName().Version ?? new Version(0, 0);

    public enum State { Idle, Available, Working, Failed }
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

    /// 上次查到的新版还没装：直接提示，不用再联网
    static void ShowPending()
    {
        var v = Prefs.Current.LatestVersion;
        if (Now == State.Idle && !string.IsNullOrEmpty(v) && Newer(v, Current)) Set(State.Available);
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
            var file = Path.Combine(Path.GetTempPath(), $"Unpack-Setup-{p.LatestVersion}.exe");
            using (var http = Client()) await File.WriteAllBytesAsync(file, await http.GetByteArrayAsync(p.LatestAsset));
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
