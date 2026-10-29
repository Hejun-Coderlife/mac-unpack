// 任务和任务队列：一个任务 = 一个压缩包，或者一批要压缩的文件；一次只跑一个（7-Zip 自己会用满多核）
using System.Diagnostics;

namespace Unpack;

enum JobKind { Extract, Compress }
enum JobState { Waiting, Working, NeedPassword, Done, Failed }

class Job
{
    public readonly Guid Id = Guid.NewGuid();
    public readonly JobKind Kind;
    public readonly List<string> Sources;
    public readonly List<string> Selection;   // 只解其中几项（从「查看内容」里勾的）
    public readonly CompressOptions Options;  // 压缩任务用
    public JobState State = JobState.Waiting;
    public double Fraction;
    public string Detail = "";
    public string ResultPath;
    public bool WrongPassword;
    public string Password;
    public Listing Listing;
    public int? CodePage;
    Runner runner = new();

    public event Action Changed;          // 状态变了（界面要重排）
    public event Action ProgressChanged;  // 只是进度和文字变了

    public Job(JobKind kind, List<string> sources, List<string> selection = null, string password = null, CompressOptions options = null)
    {
        Kind = kind; Sources = sources; Selection = selection; Password = password; Options = options ?? CompressOptions.FromPrefs();
    }

    /// 标题后面的灰字：→ zip、→ 7z · 加密 · 分卷
    public string CompressTag => "→ " + Options.Format
        + (string.IsNullOrEmpty(Options.Password) ? "" : I18n.L(" · 加密", " · encrypted"))
        + (Options.SplitMB > 0 ? I18n.L(" · 分卷", " · split") : "");

    public string Title => Kind == JobKind.Extract
        ? Path.GetFileName(Sources[0]) + (Selection != null ? I18n.L($"（选中 {Selection.Count} 项）", $" ({Selection.Count} selected)") : "")
        : Sources.Count == 1 ? Path.GetFileName(Sources[0].TrimEnd('\\', '/')) : I18n.L($"{Sources.Count} 个项目", $"{Sources.Count} items");

    public int VolumeCount => Kind == JobKind.Extract ? Archive.Volumes(Sources[0]).Count : 0;

    public void Cancel() => runner.Cancel();

    public void RaiseChanged() => Ui.Post(() => Changed?.Invoke());

    void Report(Engine.Progress p) => Ui.Post(() => { Fraction = p.Fraction; Detail = p.Text; ProgressChanged?.Invoke(); });

    /// 在后台线程跑完整个任务（由队列调用）
    public void Execute()
    {
        runner = new Runner();
        var r = runner;
        if (Kind == JobKind.Compress)
        {
            Ui.Post(() => { Detail = I18n.L("准备压缩…", "Preparing…"); ProgressChanged?.Invoke(); });
            Finish(Engine.Compress(Sources, Options, r, Report));
            return;
        }
        var arc = Sources[0];
        Ui.Post(() => { Detail = I18n.L("读取内容…", "Reading…"); ProgressChanged?.Invoke(); });
        var typed = Password;
        CodePage = NameFixer.CodePage(arc);
        var u = Engine.Unlock(arc, typed, CodePage);
        if (!u.Ok && u.Error.IsPassword)
        {
            Ui.Post(() =>
            {
                State = JobState.NeedPassword;
                WrongPassword = typed != null;
                Password = null;
                Detail = "";
                Changed?.Invoke();
            });
            return;
        }
        if (!u.Ok) { Finish(Result<string>.Fail(u.Error)); return; }
        var (listing, pw) = u.Value;
        Listing = listing;
        Password = pw;
        if (typed != null && typed == pw && Prefs.Current.RememberPw) Passwords.Remember(typed);
        Finish(Engine.Extract(arc, pw, listing, Selection, CodePage, r, Report));
    }

    void Finish(Result<string> res)
    {
        Ui.Post(() =>
        {
            if (res.Ok)
            {
                State = JobState.Done;
                ResultPath = res.Value;
                Fraction = 1;
                var dir = Path.GetFileName(Path.GetDirectoryName(res.Value)) ?? "";
                Detail = I18n.L($"已放到「{dir}」里：{Path.GetFileName(res.Value)}", $"Saved to “{dir}”: {Path.GetFileName(res.Value)}");
                if (Kind == JobKind.Extract && Selection == null && Prefs.Current.TrashAfter)
                    foreach (var v in Archive.Volumes(Sources[0])) Shell.Recycle(v);
                if (Prefs.Current.Reveal) Shell.Reveal(res.Value);
            }
            else
            {
                State = JobState.Failed;
                Detail = res.Error.Text;
            }
            Changed?.Invoke();
        });
    }
}

class JobQueue
{
    public static readonly JobQueue Shared = new();
    public readonly List<Job> Jobs = new();
    public bool OpenedByShell;
    public bool Browsing;   // 「查看内容」窗口开着：解完别自动退出
    public event Action ListChanged;
    public event Action AllDone;

    public void Add(IEnumerable<string> paths)
    {
        var loose = new List<string>();
        foreach (var raw in paths)
        {
            var p = raw.Trim().Trim('"');
            if (p.Length == 0) continue;
            if (Archive.IsArchive(p))
            {
                var first = Archive.FirstVolume(p);
                // 一套分卷一起拖进来时只算一个任务
                if (Jobs.Any(j => j.Kind == JobKind.Extract && j.Selection == null && string.Equals(j.Sources[0], first, StringComparison.OrdinalIgnoreCase)
                                  && j.State != JobState.Done && j.State != JobState.Failed)) continue;
                Jobs.Add(new Job(JobKind.Extract, new List<string> { first }));
            }
            else if (File.Exists(p) || Directory.Exists(p)) loose.Add(p);
        }
        if (loose.Count > 0) Jobs.Add(new Job(JobKind.Compress, loose));
        ListChanged?.Invoke();
        Pump();
    }

    public void Add(Job job) { Jobs.Add(job); ListChanged?.Invoke(); Pump(); }

    public void Retry(Job job, string password = null)
    {
        job.Password = password;
        job.WrongPassword = false;
        job.State = JobState.Waiting;
        job.Fraction = 0;
        job.RaiseChanged();
        Pump();
    }

    public void Remove(Job job) { job.Cancel(); Jobs.Remove(job); ListChanged?.Invoke(); Pump(); }
    public void ClearFinished() { Jobs.RemoveAll(j => j.State == JobState.Done); ListChanged?.Invoke(); }
    public int Busy => Jobs.Count(j => j.State is JobState.Working or JobState.Waiting);

    public void Pump()
    {
        if (Jobs.Any(j => j.State == JobState.Working)) return;
        var next = Jobs.FirstOrDefault(j => j.State == JobState.Waiting);
        if (next == null)
        {
            // 双击压缩包打开、而且全部顺利解完：自动退出（设置里打开才这样）
            if (OpenedByShell && !Browsing && Prefs.Current.QuitAfter && Jobs.Count > 0 && Jobs.All(j => j.State == JobState.Done)) AllDone?.Invoke();
            return;
        }
        next.State = JobState.Working;
        next.Fraction = 0;
        next.RaiseChanged();
        Task.Run(() =>
        {
            try { next.Execute(); }
            catch (Exception e) { Ui.Post(() => { next.State = JobState.Failed; next.Detail = e.Message; next.RaiseChanged(); }); }
            Ui.Post(Pump);
        });
    }

    public void CancelAll() { foreach (var j in Jobs) j.Cancel(); }
}

/// 把活儿丢回界面线程
static class Ui
{
    public static SynchronizationContext Context;
    public static void Post(Action a)
    {
        if (Context != null) Context.Post(_ => a(), null); else a();
    }
}

static class Shell
{
    /// 在资源管理器里选中
    public static void Reveal(string path)
    {
        try { Process.Start(new ProcessStartInfo("explorer.exe", $"/select,\"{path}\"")); } catch { }
    }

    public static void Open(string path)
    {
        try { Process.Start(new ProcessStartInfo(path) { UseShellExecute = true }); } catch { }
    }

    /// 移到回收站
    public static void Recycle(string path)
    {
        try
        {
            if (File.Exists(path))
                Microsoft.VisualBasic.FileIO.FileSystem.DeleteFile(path, Microsoft.VisualBasic.FileIO.UIOption.OnlyErrorDialogs, Microsoft.VisualBasic.FileIO.RecycleOption.SendToRecycleBin);
        }
        catch { }
    }
}
