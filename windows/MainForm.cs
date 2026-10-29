// 界面：仿 Typora（GitHub 主题）——白纸页面、大标题+细线、正文排版、蓝色文字链接代替按钮、底部细状态栏
using System.Diagnostics;
using System.Drawing.Drawing2D;
using static Unpack.I18n;

namespace Unpack;

static class Theme
{
    // 深色跟随 Windows「设置 → 个性化 → 颜色 → 应用模式」，打开时读一次；深色用 Typora Night 的配色（和 Mac 版深色一样）
    public static readonly bool Dark = ReadDark();
    public static readonly Color Bg = Pick(0xFFFFFF, 0x363B40);
    public static readonly Color Text = Pick(0x333333, 0xB8BFC6);
    public static readonly Color Heading = Pick(0x222222, 0xE6E6E6);
    public static readonly Color Secondary = Pick(0x777777, 0x8B939B);
    public static readonly Color Faint = Pick(0xAAAAAA, 0x666D74);
    public static readonly Color Rule = Pick(0xEEEEEE, 0x474D54);
    public static readonly Color QuoteBar = Pick(0xDFE2E5, 0x575E66);
    public static readonly Color LinkColor = Pick(0x4183C4, 0x7FB2E8);
    public static readonly Color Error = Pick(0xC7254E, 0xE8899A);
    public static readonly Color Ok = Pick(0x4E9A5B, 0x8CC796);
    public static readonly Color Bar = Pick(0xF8F8F8, 0x2E3236);
    public static readonly Color Field = Pick(0xFFFFFF, 0x2E3236);   // 输入框、下拉框的底色
    public static readonly Color Overlay = Pick(0xFAFAFA, 0x30353A);
    static Color Hex(int v) => Color.FromArgb(v >> 16 & 0xFF, v >> 8 & 0xFF, v & 0xFF);
    static Color Pick(int light, int dark) => Hex(Dark ? dark : light);

    static bool ReadDark()
    {
        try
        {
            using var k = Microsoft.Win32.Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize");
            return k?.GetValue("AppsUseLightTheme") is int v && v == 0;
        }
        catch { return false; }
    }

    [System.Runtime.InteropServices.DllImport("dwmapi.dll")] static extern int DwmSetWindowAttribute(IntPtr h, int attr, ref int v, int size);
    [System.Runtime.InteropServices.DllImport("uxtheme.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)] static extern int SetWindowTheme(IntPtr h, string app, string id);

    /// 深色时：标题栏变深、输入框/下拉框/列表/按钮跟着换色（以后加进来的控件也换）
    static readonly System.Runtime.CompilerServices.ConditionalWeakTable<Control, object> applied = new();

    public static void Apply(Control root)
    {
        if (!Dark || applied.TryGetValue(root, out _)) return;   // 同一个控件只挂一次（任务行会反复加进列表）
        applied.Add(root, null);
        if (root is Form f)
        {
            void Bar() { int on = 1; DwmSetWindowAttribute(f.Handle, 20, ref on, 4); }
            if (f.IsHandleCreated) Bar(); else f.HandleCreated += (_, _) => Bar();
        }
        switch (root)
        {
            case TextBox t: t.BackColor = Field; t.ForeColor = Text; break;
            case ComboBox c: c.BackColor = Field; c.ForeColor = Text; c.FlatStyle = FlatStyle.Flat; break;
            case Button b: b.BackColor = Field; b.ForeColor = Text; b.FlatStyle = FlatStyle.Flat; b.FlatAppearance.BorderColor = QuoteBar; break;
            case CheckBox or RadioButton: root.ForeColor = Text; break;
            case ListView l:
                if (l.IsHandleCreated) SetWindowTheme(l.Handle, "DarkMode_Explorer", null); else l.HandleCreated += (_, _) => SetWindowTheme(l.Handle, "DarkMode_Explorer", null);
                break;
            case ScrollableControl { AutoScroll: true } sc:
                if (sc.IsHandleCreated) SetWindowTheme(sc.Handle, "DarkMode_Explorer", null); else sc.HandleCreated += (_, _) => SetWindowTheme(sc.Handle, "DarkMode_Explorer", null);
                break;
        }
        foreach (Control ch in root.Controls) Apply(ch);
        root.ControlAdded += (_, e) => Apply(e.Control!);
    }

    /// 右键菜单 / 下拉菜单
    public static ContextMenuStrip Menu()
    {
        var m = new ContextMenuStrip { Font = F(9.5f), ShowImageMargin = false };
        if (Dark) { m.BackColor = Bar; m.ForeColor = Text; m.Renderer = new ToolStripProfessionalRenderer(new DarkMenuColors()); }
        return m;
    }

    class DarkMenuColors : ProfessionalColorTable
    {
        public override Color ToolStripDropDownBackground => Bar;
        public override Color MenuItemSelected => QuoteBar;
        public override Color MenuItemSelectedGradientBegin => QuoteBar;
        public override Color MenuItemSelectedGradientEnd => QuoteBar;
        public override Color MenuItemBorder => QuoteBar;
        public override Color MenuBorder => Rule;
        public override Color SeparatorDark => Rule;
        public override Color SeparatorLight => Rule;
        public override Color ImageMarginGradientBegin => Bar;
        public override Color ImageMarginGradientMiddle => Bar;
        public override Color ImageMarginGradientEnd => Bar;
    }

    static readonly string Family = IsZh ? "Microsoft YaHei UI" : "Segoe UI";
    static readonly Dictionary<(float, bool), Font> fonts = new();
    public static Font F(float size, bool bold = false)
    {
        if (!fonts.TryGetValue((size, bold), out var f)) fonts[(size, bold)] = f = new Font(Family, size, bold ? FontStyle.Bold : FontStyle.Regular);
        return f;
    }

    public static Label Lbl(string text, Color color, float size = 10, bool bold = false, Padding? margin = null) => new()
    {
        Text = text, ForeColor = color, Font = F(size, bold), AutoSize = true, Margin = margin ?? Padding.Empty, BackColor = Color.Transparent,
        UseMnemonic = false,
    };

    /// 蓝色文字链接（悬停加下划线、手形）
    public static LinkLabel Link(string text, Action click, Color? color = null, float size = 10, Padding? margin = null)
    {
        var c = color ?? Theme.LinkColor;
        var l = new LinkLabel
        {
            Text = text, Font = F(size), AutoSize = true, Margin = margin ?? Padding.Empty, BackColor = Color.Transparent,
            LinkColor = c, ActiveLinkColor = c, VisitedLinkColor = c, DisabledLinkColor = Faint, LinkBehavior = LinkBehavior.HoverUnderline,
            UseMnemonic = false,
        };
        l.LinkClicked += (_, _) => click();
        return l;
    }

    public static Label Dot() => Lbl("·", Faint, 10, false, new Padding(4, 0, 4, 0));

    public static FlowLayoutPanel Row(Padding? margin = null) => new()
    {
        FlowDirection = FlowDirection.LeftToRight, WrapContents = false, AutoSize = true, AutoSizeMode = AutoSizeMode.GrowAndShrink,
        Margin = margin ?? Padding.Empty, Padding = Padding.Empty, BackColor = Color.Transparent,
    };

    public static FlowLayoutPanel Column(Padding? margin = null) => new()
    {
        FlowDirection = FlowDirection.TopDown, WrapContents = false, AutoSize = true, AutoSizeMode = AutoSizeMode.GrowAndShrink,
        Margin = margin ?? Padding.Empty, Padding = Padding.Empty, BackColor = Color.Transparent,
    };

    /// 细分割线
    public static Panel RuleLine(Padding? margin = null) => new() { Height = 1, BackColor = Rule, Margin = margin ?? Padding.Empty };
}

/// 2 像素的细进度线
class ThinProgress : Control
{
    double value;
    public double Value { get => value; set { this.value = value; Invalidate(); } }
    public ThinProgress() { Height = 2; SetStyle(ControlStyles.OptimizedDoubleBuffer | ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint, true); }
    protected override void OnPaint(PaintEventArgs e)
    {
        e.Graphics.Clear(Theme.Rule);
        using var b = new SolidBrush(Theme.LinkColor);
        e.Graphics.FillRectangle(b, 0, 0, Math.Max(2, (int)(Width * value)), Height);
    }
}

/// 左边一道竖线的引用块
class Quote : Panel
{
    public readonly Label Label;
    public Quote(string text)
    {
        AutoSize = true; AutoSizeMode = AutoSizeMode.GrowAndShrink;
        Padding = new Padding(18, 2, 0, 2);
        Label = Theme.Lbl(text, Theme.Secondary, 11);
        Controls.Add(Label);
        Label.Location = new Point(18, 2);
    }
    protected override void OnPaint(PaintEventArgs e)
    {
        using var b = new SolidBrush(Theme.QuoteBar);
        e.Graphics.FillRectangle(b, 0, 0, 4, Height);
    }
}

/// 拖进来时盖在窗口上的提示
class DropOverlay : Control
{
    public DropOverlay()
    {
        SetStyle(ControlStyles.OptimizedDoubleBuffer | ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint, true);
        AllowDrop = true; Dock = DockStyle.Fill; Visible = false;
    }
    protected override void OnPaint(PaintEventArgs e)
    {
        var g = e.Graphics;
        g.SmoothingMode = SmoothingMode.AntiAlias;
        g.TextRenderingHint = System.Drawing.Text.TextRenderingHint.ClearTypeGridFit;
        g.Clear(Theme.Overlay);
        using (var pen = new Pen(Color.FromArgb(128, Theme.LinkColor), 2))
        using (var path = Rounded(new RectangleF(14, 14, Width - 28, Height - 28), 10)) g.DrawPath(pen, path);
        var t1 = L("松手即可", "Release to unpack");
        var t2 = L("压缩包会被解开，文件夹会被压成 zip", "Archives are extracted, folders are zipped");
        var t3 = L("按住 Alt 松手：压缩包先看内容、可以改；文件夹先选格式、密码、分卷", "Hold Alt when releasing: browse the archive, or choose format, password and split");
        var f1 = Theme.F(20, true); var f2 = Theme.F(11); var f3 = Theme.F(9);
        var s1 = g.MeasureString(t1, f1); var s2 = g.MeasureString(t2, f2); var s3 = g.MeasureString(t3, f3);
        float y = (Height - s1.Height - s2.Height - s3.Height - 14) / 2;
        using var b1 = new SolidBrush(Theme.Heading); using var b2 = new SolidBrush(Theme.Secondary); using var b3 = new SolidBrush(Theme.Faint);
        g.DrawString(t1, f1, b1, (Width - s1.Width) / 2, y);
        g.DrawString(t2, f2, b2, (Width - s2.Width) / 2, y + s1.Height + 8);
        g.DrawString(t3, f3, b3, (Width - s3.Width) / 2, y + s1.Height + s2.Height + 14);
    }
    static GraphicsPath Rounded(RectangleF r, float rad)
    {
        var p = new GraphicsPath(); float d = rad * 2;
        p.AddArc(r.X, r.Y, d, d, 180, 90); p.AddArc(r.Right - d, r.Y, d, d, 270, 90);
        p.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90); p.AddArc(r.X, r.Bottom - d, d, d, 90, 90);
        p.CloseFigure(); return p;
    }
}

class MainForm : Form
{
    readonly Panel page = new() { Dock = DockStyle.Fill, AutoScroll = true, BackColor = Theme.Bg };
    readonly FlowLayoutPanel content = Theme.Column();
    readonly Panel statusBar = new() { Dock = DockStyle.Bottom, Height = 30, BackColor = Theme.Bar };
    readonly DropOverlay overlay = new();
    readonly Dictionary<Guid, JobRow> rows = new();
    LinkLabel destLink, clearLink, updateLink;
    int W = 600;

    public MainForm()
    {
        Text = AppName;
        try { Icon = Icon.ExtractAssociatedIcon(Environment.ProcessPath ?? Application.ExecutablePath); } catch { }
        BackColor = Theme.Bg; ForeColor = Theme.Text;
        Font = Theme.F(10);
        AutoScaleMode = AutoScaleMode.Dpi;
        ClientSize = new Size(660, 580);
        MinimumSize = new Size(540, 460);
        StartPosition = FormStartPosition.CenterScreen;
        KeyPreview = true;

        page.Controls.Add(content);
        Controls.Add(page);
        BuildStatusBar();
        Controls.Add(statusBar);
        Controls.Add(overlay);
        overlay.BringToFront();

        // 拖进窗口任意位置都行：每个控件（包括后来加的）都接拖放
        EnableDrop(this);
        overlay.DragEnter += (_, e) => e.Effect = e.Data!.GetDataPresent(DataFormats.FileDrop) ? DragDropEffects.Copy : DragDropEffects.None;
        overlay.DragLeave += (_, _) => overlay.Visible = false;
        overlay.DragDrop += (_, e) =>
        {
            overlay.Visible = false;
            if (e.Data!.GetData(DataFormats.FileDrop) is not string[] files) return;
            Activate();
            // 按住 Alt 松手（KeyState 第 32 位）：压缩包先看内容，其他东西先设压缩选项
            if ((e.KeyState & 32) != 0) BeginInvoke(() => OpenWithOptions(files)); else JobQueue.Shared.Add(files);
        };

        page.Resize += (_, _) => Relayout();
        JobQueue.Shared.ListChanged += Rebuild;
        JobQueue.Shared.AllDone += () => { var t = new System.Windows.Forms.Timer { Interval = 1200 }; t.Tick += (_, _) => Close(); t.Start(); };
        KeyDown += (_, e) =>
        {
            if (e.Control && e.Shift && e.KeyCode == Keys.O) { PickBrowse(); e.Handled = true; }
            else if (e.Control && e.KeyCode == Keys.O) { PickFiles(); e.Handled = true; }
            else if (e.Control && e.KeyCode == Keys.N) { PickCompose(); e.Handled = true; }
            else if (e.Control && e.Shift && e.KeyCode == Keys.E) { PickExtractTo(); e.Handled = true; }
        };
        FormClosing += (_, e) =>
        {
            // 盯着「下载」时，点关闭只是收到托盘（右下角），右键托盘图标「退出」才真退出
            if (Prefs.Current.WatchDownloads && !quitting && e.CloseReason == CloseReason.UserClosing) { e.Cancel = true; Hide(); return; }
            JobQueue.Shared.CancelAll();
            tray.Visible = false;
        };
        BuildTray();
        Job.Finished += Notify;
        watchTimer.Tick += (_, _) => WatchTick();
        SyncWatch();
        Updater.Changed += UpdateChrome;
        Shown += (_, _) => Updater.Check();
        Rebuild();
        Theme.Apply(this);
    }

    // ---- 托盘图标：后台盯「下载」时待在这里；也用来弹「解完了」的通知 ----
    readonly NotifyIcon tray = new();
    bool quitting;
    string balloonPath;

    void BuildTray()
    {
        try { tray.Icon = Icon.ExtractAssociatedIcon(Environment.ProcessPath ?? Application.ExecutablePath); } catch { }
        tray.Text = AppName;
        var m = Theme.Menu();
        m.Items.Add(L("打开「解压」", "Open Unpack"), null, (_, _) => ShowFromTray());
        m.Items.Add(new ToolStripSeparator());
        m.Items.Add(L("退出", "Quit"), null, (_, _) => { quitting = true; Close(); });
        tray.ContextMenuStrip = m;
        tray.DoubleClick += (_, _) => ShowFromTray();
        tray.BalloonTipClicked += (_, _) => { if (balloonPath != null) Shell.Reveal(balloonPath); };
        tray.Visible = Prefs.Current.WatchDownloads;
    }

    public void ShowFromTray() { Show(); BringToFrontForce(); }

    /// 开机自动启动时不显示窗口（Application.Run 会让窗口出来，这里拦一次）
    public bool StartHidden;
    protected override void SetVisibleCore(bool value)
    {
        if (StartHidden && value)
        {
            StartHidden = false;
            if (!IsHandleCreated) CreateHandle();
            base.SetVisibleCore(false);
            Updater.Check();
            return;
        }
        base.SetVisibleCore(value);
    }

    /// 窗口不在前面时：解完 / 出错 / 要密码，弹一条通知；点通知在资源管理器里选中结果
    void Notify(Job j)
    {
        if (!Prefs.Current.Notify || (Visible && ContainsFocus)) return;
        var title = j.State switch
        {
            JobState.Done => j.Kind == JobKind.Compress ? L("压缩好了", "Compressed") : j.Kind == JobKind.Test ? L("检查完了", "Check finished") : L("解压好了", "Extracted"),
            JobState.NeedPassword => L("这个包要密码", "Password needed"),
            _ => L("没成功", "Failed"),
        };
        balloonPath = j.ResultPath;
        bool wasVisible = tray.Visible;
        tray.Visible = true;
        tray.ShowBalloonTip(5000, title, j.Title + "\n" + j.Detail, j.State == JobState.Done ? ToolTipIcon.Info : ToolTipIcon.Warning);
        if (!wasVisible && !Prefs.Current.WatchDownloads)
        {
            var t = new System.Windows.Forms.Timer { Interval = 8000 };
            t.Tick += (_, _) => { t.Dispose(); if (!Prefs.Current.WatchDownloads) tray.Visible = false; };
            t.Start();
        }
    }

    // ---- 盯着「下载」：新下好的压缩包（大小停住不变、不是 .crdownload/.part 半截文件）自动解开，原包移到回收站 ----
    readonly System.Windows.Forms.Timer watchTimer = new() { Interval = 3000 };
    HashSet<string> known = new(StringComparer.OrdinalIgnoreCase);
    readonly Dictionary<string, long> growing = new(StringComparer.OrdinalIgnoreCase);
    // 自测：UNPACK_WATCH_DIR=目录 换成盯别的文件夹
    static string WatchDir => Environment.GetEnvironmentVariable("UNPACK_WATCH_DIR") ?? Engine.Downloads;

    static IEnumerable<string> ListWatch() { try { return Directory.EnumerateFiles(WatchDir).ToList(); } catch { return Array.Empty<string>(); } }

    public void SyncWatch()
    {
        tray.Visible = Prefs.Current.WatchDownloads;
        if (!Prefs.Current.WatchDownloads) { watchTimer.Stop(); return; }
        if (watchTimer.Enabled) return;
        known = new HashSet<string>(ListWatch(), StringComparer.OrdinalIgnoreCase);
        growing.Clear();
        watchTimer.Start();
    }

    void WatchTick()
    {
        var now = ListWatch().ToList();
        var ready = new List<string>();
        foreach (var f in now)
        {
            if (known.Contains(f)) continue;
            var ext = Path.GetExtension(f).TrimStart('.').ToLowerInvariant();
            if (Path.GetFileName(f).StartsWith(".") || ext is "crdownload" or "part" or "partial" or "tmp" or "download") continue;
            if (!Archive.IsArchive(f)) { known.Add(f); continue; }
            long size = Fs.SizeOf(f);
            if (growing.TryGetValue(f, out var last) && last == size && size > 0 && CanOpen(f)) { ready.Add(f); known.Add(f); growing.Remove(f); }
            else growing[f] = size;   // 下一轮大小还一样（而且浏览器已经松开文件）才算下完
        }
        known.IntersectWith(now);
        if (ready.Count > 0) JobQueue.Shared.Add(ready, null, true);
    }

    static bool CanOpen(string f) { try { using var _ = File.Open(f, FileMode.Open, FileAccess.Read, FileShare.Read); return true; } catch { return false; } }

    /// Ctrl+Shift+E / 右键「解压到…」：先选位置，再解到那里
    public void PickExtractTo(IEnumerable<string> archives = null)
    {
        var list = archives?.Where(Archive.IsArchive).ToList();
        if (list == null)
        {
            using var d = new OpenFileDialog { Multiselect = true, Title = L("选要解开的压缩包，下一步选解到哪", "Choose archives; next, pick where to extract") };
            if (d.ShowDialog(this) != DialogResult.OK) return;
            list = d.FileNames.ToList();
        }
        if (list.Count == 0) return;
        using var f = new FolderBrowserDialog { ShowNewFolderButton = true, Description = L("解到哪个文件夹？", "Extract to which folder?"), UseDescriptionForTitle = true };
        if (f.ShowDialog(this) == DialogResult.OK) JobQueue.Shared.Add(list, f.SelectedPath);
    }

    void EnableDrop(Control c)
    {
        if (c == overlay) return;
        c.AllowDrop = true;
        c.DragEnter += (_, e) =>
        {
            if (e.Data?.GetDataPresent(DataFormats.FileDrop) != true) return;
            e.Effect = DragDropEffects.Copy;
            overlay.Visible = true; overlay.BringToFront();
        };
        foreach (Control ch in c.Controls) EnableDrop(ch);
        c.ControlAdded += (_, e) => EnableDrop(e.Control!);
    }

    public void BringToFrontForce()
    {
        if (WindowState == FormWindowState.Minimized) WindowState = FormWindowState.Normal;
        TopMost = true; TopMost = false;
        Activate();
    }

    public void PickFiles()
    {
        using var d = new OpenFileDialog
        {
            Multiselect = true, Title = L("选压缩包解开；选普通文件则压成 zip", "Choose archives to extract, or files to zip"),
        };
        if (d.ShowDialog(this) == DialogResult.OK) JobQueue.Shared.Add(d.FileNames);
    }

    /// Ctrl+Shift+O：选一个压缩包，先看里面有什么（可以加、删、改名）
    public void PickBrowse()
    {
        using var d = new OpenFileDialog { Title = L("选一个压缩包：先看里面有什么，可以加、删、改名", "Choose an archive to browse and edit") };
        if (d.ShowDialog(this) == DialogResult.OK) Browse(Archive.FirstVolume(d.FileName));
    }

    /// Ctrl+N：选要压缩的文件，下一步选格式、密码、分卷（要压整个文件夹就把文件夹拖进来时按住 Alt）
    public void PickCompose()
    {
        using var d = new OpenFileDialog { Multiselect = true, Title = L("选要压缩的文件，下一步可选格式、密码、分卷", "Choose files; next you can pick format, password and split") };
        if (d.ShowDialog(this) == DialogResult.OK) Compose(d.FileNames.ToList());
    }

    public void OpenWithOptions(IEnumerable<string> paths)
    {
        var all = paths.Select(p => p.Trim().Trim('"')).Where(p => p.Length > 0).ToList();
        var a = all.FirstOrDefault(Archive.IsArchive);
        if (a != null) { Browse(Archive.FirstVolume(a)); return; }
        var loose = all.Where(p => File.Exists(p) || Directory.Exists(p)).ToList();
        if (loose.Count > 0) Compose(loose);
    }

    public void Browse(string arc, string password = null)
    {
        using var b = new BrowserForm(arc, password);
        b.ShowDialog(this);
    }

    public void Compose(List<string> srcs)
    {
        using var c = new CompressForm(srcs);
        c.ShowDialog(this);
    }

    void Rebuild()
    {
        content.SuspendLayout();
        content.Controls.Clear();
        var q = JobQueue.Shared;
        if (q.Jobs.Count == 0) content.Controls.Add(Intro());
        else
        {
            content.Controls.Add(Theme.Lbl(AppName, Theme.Heading, 22, true, new Padding(0, 0, 0, 10)));
            content.Controls.Add(Theme.RuleLine(new Padding(0, 0, 0, 18)));
            content.Controls.Add(Para(L("继续把压缩包拖进来，或者 选择文件。", "Drop more archives, or choose files."), L("选择文件", "choose files"),
                10.5f, Theme.Secondary, new Padding(0, 0, 0, 6)));
            foreach (var id in rows.Keys.Except(q.Jobs.Select(j => j.Id)).ToList()) { rows[id].Dispose(); rows.Remove(id); }
            foreach (var j in q.Jobs)
            {
                if (!rows.TryGetValue(j.Id, out var r)) rows[j.Id] = r = new JobRow(j, Browse);
                content.Controls.Add(r);
            }
        }
        content.ResumeLayout();
        Relayout();
        UpdateChrome();
    }

    /// 空窗口：和宣传视频结尾那张卡一样——图标 + 名字 + 一句话。格式、密码、乱码这些都是自动的，不用在这里讲
    Control Intro()
    {
        const int iconSize = 84, gap = 22;
        var icon = new PictureBox { Size = new Size(iconSize, iconSize), SizeMode = PictureBoxSizeMode.Zoom, Margin = new Padding(0, 0, gap, 0), BackColor = Color.Transparent };
        try { icon.Image = Icon.ExtractIcon(Environment.ProcessPath ?? Application.ExecutablePath, 0, 256)?.ToBitmap(); } catch { }
        var text = Theme.Column();
        text.Controls.Add(Theme.Lbl(AppName, Theme.Heading, 24, true, new Padding(0, 0, 0, 6)));
        var rule = Theme.RuleLine(new Padding(0, 0, 0, 10)); rule.Width = 200;
        text.Controls.Add(rule);
        text.Controls.Add(Theme.Lbl(L("拖进来，就解开。", "Drop it in. It opens."), Theme.Text, 11, true, new Padding(0, 0, 0, 6)));
        text.Controls.Add(Theme.Lbl(L("zip · 7z · rar · 分卷 · 加密包 · 乱码修复", "zip · 7z · rar · split · encrypted · garbled names"), Theme.Faint, 8.5f));
        var card = Theme.Row();
        card.Controls.Add(icon); card.Controls.Add(text);
        // 图标和右边三行文字上下居中（不算下面的「选择文件」）
        card.Layout += (_, _) => icon.Margin = new Padding(0, Math.Max(0, (text.Height - iconSize) / 2), gap, 0);
        text.Layout += (_, _) => icon.Margin = new Padding(0, Math.Max(0, (text.Height - iconSize) / 2), gap, 0);
        var pick = Theme.Row(new Padding(iconSize + gap, 18, 0, 0));
        pick.Controls.Add(Theme.Link(L("选择文件", "Choose a file"), PickFiles, null, 10));
        pick.Controls.Add(Theme.Lbl("Ctrl+O", Theme.Faint, 10, false, new Padding(14, 0, 0, 0)));
        var box = Theme.Column();
        box.Controls.Add(card); box.Controls.Add(pick);
        box.Tag = "intro";
        return box;
    }

    /// 正文里带一个可点的「选择文件」链接
    LinkLabel Para(string text, string link, float size, Color color, Padding margin)
    {
        var l = Theme.Link(text, PickFiles, null, size, margin);
        l.LinkArea = new LinkArea(Math.Max(0, text.IndexOf(link, StringComparison.Ordinal)), link.Length);
        l.ForeColor = color;
        return l;
    }

    void Relayout()
    {
        if (content.Controls.Count == 1 && content.Controls[0].Tag is "intro")
        {
            // 空窗口：名片卡放在正中间
            content.Padding = Padding.Empty;
            content.Location = new Point(Math.Max(0, (page.ClientSize.Width - content.Width) / 2), Math.Max(0, (page.ClientSize.Height - content.Height) / 2));
            return;
        }
        int avail = page.ClientSize.Width - 88;
        W = Math.Max(300, Math.Min(600, avail));
        content.Location = new Point(Math.Max(44, (page.ClientSize.Width - W) / 2) + page.AutoScrollPosition.X, 46 + page.AutoScrollPosition.Y);
        content.Padding = new Padding(0, 0, 0, 28);
        foreach (Control c in content.Controls)
        {
            switch (c)
            {
                case JobRow r: r.SetWidth(W); break;
                case Label l: l.MaximumSize = new Size(W, 0); break;
                case Quote q: q.Label.MaximumSize = new Size(W - 18, 0); break;
                default: c.Width = W; break;
            }
        }
    }

    public void UpdateChrome()
    {
        int busy = JobQueue.Shared.Busy;
        Text = busy > 0 ? $"{AppName} ({busy})" : AppName;
        clearLink.Visible = JobQueue.Shared.Jobs.Any(j => j.State == JobState.Done);
        updateLink.Visible = Updater.Now is not (Updater.State.Idle or Updater.State.Downloading);
        updateLink.Enabled = Updater.Now != Updater.State.Working;
        updateLink.Text = Updater.Now switch
        {
            Updater.State.Working => L("正在更新…", "Updating…"),
            Updater.State.Ready => L($"新版本 {Prefs.Current.LatestVersion} 已下好，关掉后自动装上 · 现在装", $"Version {Prefs.Current.LatestVersion} installs when you quit · Install now"),
            Updater.State.Failed => L("更新失败，去下载", "Update failed — download"),
            _ => L($"有新版本 {Prefs.Current.LatestVersion} · 更新", $"Update to {Prefs.Current.LatestVersion}"),
        };
        updateLink.LinkColor = updateLink.ActiveLinkColor = Updater.Now == Updater.State.Failed ? Theme.Error : Theme.LinkColor;
        var d = Prefs.Current.Dest;
        destLink.Text = L("解压到：", "Extract to: ") + (string.IsNullOrEmpty(d) ? L("压缩包旁边", "next to the archive") : Path.GetFileName(d.TrimEnd('\\'))) + "  ⌄";
    }

    void BuildStatusBar()
    {
        statusBar.Paint += (_, e) => { using var p = new Pen(Theme.Rule); e.Graphics.DrawLine(p, 0, 0, statusBar.Width, 0); };
        var menu = Theme.Menu();
        void SetDest(string d) { Prefs.Current.Dest = d; Prefs.Current.Save(); UpdateChrome(); }
        menu.Items.Add(L("压缩包所在的文件夹", "Next to the archive"), null, (_, _) => SetDest(""));
        menu.Items.Add(L("下载", "Downloads"), null, (_, _) => SetDest(Engine.Downloads));
        menu.Items.Add(L("桌面", "Desktop"), null, (_, _) => SetDest(Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory)));
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add(L("其他文件夹…", "Other…"), null, (_, _) =>
        {
            using var f = new FolderBrowserDialog { ShowNewFolderButton = true };
            if (f.ShowDialog(this) == DialogResult.OK) SetDest(f.SelectedPath);
        });
        destLink = Theme.Link("", () => { }, Theme.Secondary, 9);
        destLink.LinkBehavior = LinkBehavior.HoverUnderline;
        destLink.LinkClicked += (_, _) => menu.Show(destLink, new Point(0, -menu.PreferredSize.Height));
        destLink.Location = new Point(16, 7);
        statusBar.Controls.Add(destLink);

        var right = Theme.Row();
        right.FlowDirection = FlowDirection.RightToLeft;
        right.Dock = DockStyle.Right;
        right.Padding = new Padding(0, 7, 12, 0);
        right.Controls.Add(Theme.Link(L("设置", "Settings"), () => { using var s = new SettingsForm(); s.ShowDialog(this); UpdateChrome(); }, Theme.Secondary, 9));
        clearLink = Theme.Link(L("清除已完成", "Clear finished"), () => JobQueue.Shared.ClearFinished(), Theme.Secondary, 9, new Padding(0, 0, 14, 0));
        right.Controls.Add(clearLink);
        updateLink = Theme.Link("", () => { if (Updater.Now == Updater.State.Failed) Updater.OpenPage(); else Updater.Install(); }, null, 9, new Padding(0, 0, 14, 0));
        updateLink.Visible = false;
        right.Controls.Add(updateLink);
        statusBar.Controls.Add(right);
    }

    void Browse(Job j) => Browse(j.Sources[0], j.Password);
}

/// 列表里的一行：图标 + 名字 + 状态（进度/密码框/结果/报错）
class JobRow : Panel
{
    readonly Job job;
    readonly Action<Job> browse;
    readonly FlowLayoutPanel body = Theme.Column();
    Label detail;
    ThinProgress bar;
    TextBox pw;
    CheckBox remember;
    Icon icon;
    int width = 600;

    public JobRow(Job job, Action<Job> browse)
    {
        this.job = job; this.browse = browse;
        DoubleBuffered = true;
        Margin = Padding.Empty;
        BackColor = Color.Transparent;
        body.Location = new Point(34, 14);
        body.SizeChanged += (_, _) => Height = body.Height + 28;
        Controls.Add(body);
        try { icon = Icon.ExtractAssociatedIcon(job.Sources[0]); } catch { }
        job.Changed += Refill;
        job.ProgressChanged += () =>
        {
            if (detail != null) detail.Text = job.Detail;
            if (bar != null) bar.Value = job.Fraction;
        };
        Refill();
    }

    protected override void Dispose(bool disposing)
    {
        job.Changed -= Refill;
        icon?.Dispose();
        base.Dispose(disposing);
    }

    public void SetWidth(int w)
    {
        if (w == width && Width == w) return;
        width = w; Width = w;
        Refill();
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        if (icon != null) e.Graphics.DrawIcon(icon, new Rectangle(0, 15, 22, 22));
        using var p = new Pen(Theme.Rule);
        e.Graphics.DrawLine(p, 0, Height - 1, Width, Height - 1);
    }

    void Refill()
    {
        if (IsDisposed) return;
        int inner = width - 34;
        body.SuspendLayout();
        body.Controls.Clear();
        detail = null; bar = null;

        var head = Theme.Row(new Padding(0, 0, 0, 6));
        var title = Theme.Lbl(job.Title, Theme.Heading, 11.5f, true);
        title.AutoEllipsis = true;
        title.MaximumSize = new Size(Math.Max(120, inner - 150), 0);
        title.AutoSize = true;
        head.Controls.Add(title);
        int vols = job.VolumeCount;
        if (vols > 1) head.Controls.Add(Theme.Lbl(L($"{vols} 卷", $"{vols} parts"), Theme.Faint, 10, false, new Padding(8, 3, 0, 0)));
        if (job.Tag != null) head.Controls.Add(Theme.Lbl(job.Tag, Theme.Faint, 10, false, new Padding(8, 3, 0, 0)));
        if (job.State != JobState.Working)
            head.Controls.Add(Theme.Link(L("移除", "Remove"), () => JobQueue.Shared.Remove(job), Theme.Faint, 9, new Padding(12, 4, 0, 0)));
        body.Controls.Add(head);

        switch (job.State)
        {
            case JobState.Waiting:
                body.Controls.Add(Theme.Lbl(L("排队中", "Waiting"), Theme.Secondary, 10));
                break;
            case JobState.Working:
            {
                var r = Theme.Row();
                detail = Theme.Lbl(job.Detail, Theme.Secondary, 10);
                r.Controls.Add(detail);
                r.Controls.Add(Theme.Dot());
                r.Controls.Add(Theme.Link(L("取消", "Cancel"), () => JobQueue.Shared.Remove(job)));
                body.Controls.Add(r);
                bar = new ThinProgress { Width = inner, Margin = new Padding(0, 8, 0, 0), Value = job.Fraction };
                body.Controls.Add(bar);
                break;
            }
            case JobState.NeedPassword:
            {
                body.Controls.Add(Theme.Lbl(job.WrongPassword ? L("密码不对，再试一次。", "Wrong password, try again.")
                    : L("这个包加了密码，存过的密码都不对。", "This archive is encrypted and no saved password fits."),
                    job.WrongPassword ? Theme.Error : Theme.Secondary, 10, false, new Padding(0, 0, 0, 8)));
                var r = Theme.Row();
                pw = new TextBox
                {
                    UseSystemPasswordChar = true, Width = 200, BorderStyle = BorderStyle.FixedSingle, Font = Theme.F(10.5f),
                    PlaceholderText = L("输入密码", "Password"), Margin = new Padding(0, 0, 12, 0),
                };
                pw.KeyDown += (_, e) => { if (e.KeyCode == Keys.Enter) { e.SuppressKeyPress = true; Submit(); } };
                remember = new CheckBox { Text = L("记住", "Remember"), Checked = Prefs.Current.RememberPw, AutoSize = true, ForeColor = Theme.Secondary, Font = Theme.F(10), Margin = new Padding(0, 3, 12, 0) };
                r.Controls.Add(pw);
                r.Controls.Add(remember);
                r.Controls.Add(Theme.Link(L("解开", "Unlock"), Submit, null, 10, new Padding(0, 4, 0, 0)));
                body.Controls.Add(r);
                BeginInvoke(() => { if (!pw.IsDisposed && FindForm()?.ContainsFocus == true) pw.Focus(); });
                break;
            }
            case JobState.Done:
            {
                var r = Theme.Row();
                r.Controls.Add(Theme.Lbl("✓", Theme.Ok, 10, false, new Padding(0, 0, 6, 0)));
                var d = Theme.Lbl(job.Detail, Theme.Secondary, 10);
                d.AutoEllipsis = true; d.MaximumSize = new Size(Math.Max(120, inner - 260), 0);
                r.Controls.Add(d);
                r.Controls.Add(Theme.Dot());
                r.Controls.Add(Theme.Link(L("在资源管理器中显示", "Show in Explorer"), () => { if (job.ResultPath != null) Shell.Reveal(job.ResultPath); }));
                if (job.Kind == JobKind.Extract && job.Selection == null)
                {
                    r.Controls.Add(Theme.Dot());
                    r.Controls.Add(Theme.Link(L("查看内容", "Contents"), () => browse(job)));
                }
                body.Controls.Add(r);
                break;
            }
            case JobState.Failed:
            {
                var m = Theme.Lbl(job.Detail, Theme.Error, 10, false, new Padding(0, 0, 0, 6));
                m.MaximumSize = new Size(inner, 0);
                body.Controls.Add(m);
                var r = Theme.Row();
                r.Controls.Add(Theme.Link(L("重试", "Retry"), () => JobQueue.Shared.Retry(job, job.Password)));
                if (job.Kind == JobKind.Extract && job.Selection == null)
                {
                    r.Controls.Add(Theme.Dot());
                    r.Controls.Add(Theme.Link(L("查看内容", "Contents"), () => browse(job)));
                }
                body.Controls.Add(r);
                break;
            }
        }
        body.ResumeLayout();
        Height = body.Height + 28;
        Invalidate();
        (FindForm() as MainForm)?.UpdateChrome();
    }

    void Submit()
    {
        if (pw == null || pw.Text.Length == 0) return;
        Prefs.Current.RememberPw = remember.Checked; Prefs.Current.Save();
        JobQueue.Shared.Retry(job, pw.Text);
    }
}

class SettingsForm : Form
{
    public SettingsForm()
    {
        Text = L("设置", "Settings");
        FormBorderStyle = FormBorderStyle.FixedDialog; MaximizeBox = false; MinimizeBox = false; ShowInTaskbar = false;
        StartPosition = FormStartPosition.CenterParent;
        BackColor = Theme.Bg; Font = Theme.F(10); AutoScaleMode = AutoScaleMode.Dpi;
        AutoSize = true; AutoSizeMode = AutoSizeMode.GrowAndShrink;
        var p = Prefs.Current;
        var col = Theme.Column();
        col.Padding = new Padding(20, 16, 24, 18);
        col.Controls.Add(Theme.Lbl(L("设置", "Settings"), Theme.Heading, 14, true, new Padding(0, 0, 0, 8)));
        col.Controls.Add(Theme.RuleLine(new Padding(0, 0, 0, 8)));
        CheckBox Box(string t, bool v, Action<bool> set)
        {
            var c = new CheckBox { Text = t, Checked = v, AutoSize = true, ForeColor = Theme.Text, Margin = new Padding(0, 3, 0, 3) };
            c.CheckedChanged += (_, _) => { set(c.Checked); p.Save(); };
            col.Controls.Add(c);
            return c;
        }
        Box(L("去掉 __MACOSX、.DS_Store、Thumbs.db 等垃圾", "Remove __MACOSX, .DS_Store, Thumbs.db"), p.CleanJunk, v => p.CleanJunk = v);
        Box(L(".tar.gz / .tgz 一次解到底", "Unpack .tar.gz in one step"), p.NestedTar, v => p.NestedTar = v);
        Box(L("解完在资源管理器里选中", "Show in Explorer when done"), p.Reveal, v => p.Reveal = v);
        Box(L("解完把压缩包移到回收站（分卷一起）", "Move archive (all parts) to Recycle Bin when done"), p.TrashAfter, v => p.TrashAfter = v);
        Box(L("双击压缩包时先看内容，不直接解开", "Double-click an archive to browse it first"), p.BrowseOnOpen, v => p.BrowseOnOpen = v);
        Box(L("在后台解完时弹通知", "Notify me when done in the background"), p.Notify, v => p.Notify = v);
        Box(L("自动解开「下载」里新下好的压缩包（原包移到回收站）", "Auto-extract new archives in Downloads (then recycle them)"), p.WatchDownloads, v =>
        {
            p.WatchDownloads = v;
            Autostart.Set(v);
            (Application.OpenForms.OfType<MainForm>().FirstOrDefault())?.SyncWatch();
        });
        col.Controls.Add(Theme.Lbl(L("开着这个：开机自动启动，关掉窗口会收到右下角托盘，右键托盘图标可退出", "Starts with Windows; closing the window keeps it in the tray"),
            Theme.Faint, 9, false, new Padding(18, 0, 0, 4)));
        Box(L("双击压缩包打开时，解完自动退出", "Quit after extracting files opened from Explorer"), p.QuitAfter, v => p.QuitAfter = v);
        Box(L("自动更新（有新版就在后台下好，关掉解压时装上）", "Update automatically (downloads in the background, installs when you quit)"), p.AutoUpdate, v => p.AutoUpdate = v);
        Box(L("资源管理器右键菜单加「用解压处理」「用解压查看内容」", "Add “Open with Unpack” and “Browse with Unpack” to the Explorer context menu"), ContextMenu.Installed, ContextMenu.Set);
        if (ClassicMenu.IsWin11)
        {
            // Windows 11 把老程序的右键菜单都收进「显示更多选项」：打开这个就一右键直接看到（整个系统的右键菜单都换回 Win10 样式）
            Box(L("Windows 11 右键直接显示这些菜单（整个系统换回 Win10 样式的右键菜单）", "Show these right away on Windows 11 (switches the whole system to the classic menu)"),
                ClassicMenu.On, v => { ClassicMenu.Set(v); ClassicMenu.RestartExplorer(); });
        }
        col.Controls.Add(Theme.RuleLine(new Padding(0, 8, 0, 8)));
        var fmt = Theme.Row(new Padding(0, 3, 0, 3));
        fmt.Controls.Add(Theme.Lbl(L("拖进来压缩成", "Compress to"), Theme.Text, 10, false, new Padding(0, 4, 8, 0)));
        var format = new ComboBox { DropDownStyle = ComboBoxStyle.DropDownList, Width = 70, Margin = new Padding(0, 0, 8, 0) };
        format.Items.AddRange(new object[] { "zip", "7z" });
        format.SelectedIndex = p.Format == "7z" ? 1 : 0;
        format.SelectedIndexChanged += (_, _) => { p.Format = (string)format.SelectedItem!; p.Save(); };
        var level = new ComboBox { DropDownStyle = ComboBoxStyle.DropDownList, Width = 150 };
        foreach (var (_, t) in CompressOptions.Levels) level.Items.Add(t);
        level.SelectedIndex = Math.Max(0, Array.FindIndex(CompressOptions.Levels, x => x.Item1 == p.Level));
        level.SelectedIndexChanged += (_, _) => { p.Level = CompressOptions.Levels[level.SelectedIndex].Item1; p.Save(); };
        fmt.Controls.Add(format); fmt.Controls.Add(level);
        col.Controls.Add(fmt);
        col.Controls.Add(Theme.Lbl(L("要设密码、分卷：按住 Alt 拖进来，或 Ctrl+N", "For password or split: hold Alt while dropping, or Ctrl+N"), Theme.Faint, 9, false, new Padding(0, 2, 0, 0)));
        col.Controls.Add(Theme.RuleLine(new Padding(0, 8, 0, 8)));
        Box(L("输对的密码记进密码本（用 Windows 账户加密保存）", "Save correct passwords (encrypted with your Windows account)"), p.RememberPw, v => p.RememberPw = v);
        int saved = Passwords.All().Count;
        var row = Theme.Row(new Padding(0, 6, 0, 0));
        var count = Theme.Lbl(L($"密码本里有 {saved} 个密码", $"{saved} saved passwords"), Theme.Secondary, 10, false, new Padding(0, 0, 12, 0));
        row.Controls.Add(count);
        row.Controls.Add(Theme.Link(L("管理…", "Manage…"), () =>
        {
            using var b = new PasswordBookForm(); b.ShowDialog(this);
            int n = Passwords.All().Count;
            count.Text = L($"密码本里有 {n} 个密码", $"{n} saved passwords");
        }, null, 10, new Padding(0, 0, 12, 0)));
        LinkLabel clear = null;
        clear = Theme.Link(L("清空", "Clear"), () => { Passwords.Save(new List<string>()); count.Text = L("密码本里有 0 个密码", "0 saved passwords"); clear.Enabled = false; });
        clear.Enabled = saved > 0;
        row.Controls.Add(clear);
        col.Controls.Add(row);

        col.Controls.Add(Theme.RuleLine(new Padding(0, 10, 0, 8)));
        var lang = Theme.Row(new Padding(0, 3, 0, 3));
        lang.Controls.Add(Theme.Lbl(L("界面语言", "Language"), Theme.Text, 10, false, new Padding(0, 4, 8, 0)));
        var langBox = new ComboBox { DropDownStyle = ComboBoxStyle.DropDownList, Width = 110 };
        string[] codes = { "auto", "zh", "en" };
        langBox.Items.AddRange(new object[] { L("跟随系统", "System"), "中文", "English" });
        langBox.SelectedIndex = Math.Max(0, Array.IndexOf(codes, p.Language));
        var startLang = p.Language;
        var relaunch = Theme.Link(L("重新打开生效", "Relaunch to apply"), () =>
        {
            Process.Start(new ProcessStartInfo(Environment.ProcessPath ?? Application.ExecutablePath) { UseShellExecute = true });
            Application.Exit();
        }, null, 10, new Padding(10, 4, 0, 0));
        relaunch.Visible = false;
        langBox.SelectedIndexChanged += (_, _) => { p.Language = codes[langBox.SelectedIndex]; p.Save(); relaunch.Visible = p.Language != startLang; };
        lang.Controls.Add(langBox); lang.Controls.Add(relaunch);
        col.Controls.Add(lang);
        var ver = Theme.Row(new Padding(0, 8, 0, 0));
        ver.Controls.Add(Theme.Lbl($"{AppName} {Updater.CurrentText}", Theme.Secondary, 10));
        ver.Controls.Add(Theme.Dot());
        var note = Theme.Lbl("", Theme.Faint, 10, false, new Padding(8, 0, 0, 0));
        ver.Controls.Add(Theme.Link(L("检查更新", "Check for updates"), () =>
        {
            note.Text = L("正在检查…", "Checking…");
            Updater.Check(true, t => { if (!note.IsDisposed) note.Text = t; });
        }));
        ver.Controls.Add(note);
        col.Controls.Add(ver);
        foreach (Control c in col.Controls) if (c is Panel { Height: 1 } r) r.Width = 380;
        Controls.Add(col);
        Theme.Apply(this);
    }
}

/// 密码本：一个个看、一个个删
class PasswordBookForm : Form
{
    readonly FlowLayoutPanel rows = Theme.Column();
    readonly HashSet<int> shown = new();
    List<string> list = Passwords.All();

    public PasswordBookForm()
    {
        Text = L("密码本", "Password Book");
        FormBorderStyle = FormBorderStyle.FixedDialog; MaximizeBox = false; MinimizeBox = false; ShowInTaskbar = false;
        StartPosition = FormStartPosition.CenterParent;
        BackColor = Theme.Bg; Font = Theme.F(10); AutoScaleMode = AutoScaleMode.Dpi;
        ClientSize = new Size(440, 400);
        var head = Theme.Lbl(L("遇到加密包时从上往下挨个试；最近用过的排在前面", "Tried in order on encrypted archives; most recent first"), Theme.Faint, 9);
        head.Location = new Point(20, 16);
        var box = new Panel { Location = new Point(20, 44), Size = new Size(400, 300), AutoScroll = true, BackColor = Theme.Bg };
        rows.Location = Point.Empty;
        box.Controls.Add(rows);
        var done = Theme.Link(L("完成", "Done"), Close);
        done.Location = new Point(380, 360);
        Controls.AddRange(new Control[] { head, box, done });
        Fill();
        Theme.Apply(this);
    }

    void Fill()
    {
        rows.SuspendLayout();
        rows.Controls.Clear();
        for (int i = 0; i < list.Count; i++)
        {
            int k = i;
            var r = new Panel { Size = new Size(380, 34), BackColor = Theme.Bg, Margin = Padding.Empty };
            r.Paint += (_, e) => { using var pen = new Pen(Theme.Rule); e.Graphics.DrawLine(pen, 0, r.Height - 1, r.Width, r.Height - 1); };
            var t = Theme.Lbl(shown.Contains(k) ? list[k] : new string('•', Math.Clamp(list[k].Length, 6, 16)), Theme.Text, 10);
            t.Font = new Font("Consolas", 10); t.AutoEllipsis = true; t.AutoSize = false; t.SetBounds(0, 8, 250, 20);
            var show = Theme.Link(shown.Contains(k) ? L("隐藏", "Hide") : L("显示", "Show"), () => { if (!shown.Remove(k)) shown.Add(k); Fill(); }, Theme.Secondary, 9.5f);
            show.Location = new Point(262, 9);
            var del = Theme.Link(L("删除", "Delete"), () => { list.RemoveAt(k); shown.Clear(); Passwords.Save(list); Fill(); }, Theme.Error, 9.5f);
            del.Location = new Point(320, 9);
            r.Controls.AddRange(new Control[] { t, show, del });
            rows.Controls.Add(r);
        }
        if (list.Count == 0) rows.Controls.Add(Theme.Lbl(L("密码本是空的", "No saved passwords"), Theme.Faint, 10, false, new Padding(0, 8, 0, 0)));
        rows.ResumeLayout();
    }
}
