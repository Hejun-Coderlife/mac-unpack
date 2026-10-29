// 界面：仿 Typora（GitHub 主题）——白纸页面、大标题+细线、正文排版、蓝色文字链接代替按钮、底部细状态栏
using System.Drawing.Drawing2D;
using static Unpack.I18n;

namespace Unpack;

static class Theme
{
    public static readonly Color Bg = Color.White;
    public static readonly Color Text = Hex(0x333333);
    public static readonly Color Heading = Hex(0x222222);
    public static readonly Color Secondary = Hex(0x777777);
    public static readonly Color Faint = Hex(0xAAAAAA);
    public static readonly Color Rule = Hex(0xEEEEEE);
    public static readonly Color QuoteBar = Hex(0xDFE2E5);
    public static readonly Color LinkColor = Hex(0x4183C4);
    public static readonly Color Error = Hex(0xC7254E);
    public static readonly Color Ok = Hex(0x4E9A5B);
    public static readonly Color Bar = Hex(0xF8F8F8);
    static Color Hex(int v) => Color.FromArgb(v >> 16 & 0xFF, v >> 8 & 0xFF, v & 0xFF);

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
        g.Clear(Color.FromArgb(250, 250, 250));
        using (var pen = new Pen(Color.FromArgb(128, Theme.LinkColor), 2))
        using (var path = Rounded(new RectangleF(14, 14, Width - 28, Height - 28), 10)) g.DrawPath(pen, path);
        var t1 = L("松手即可", "Release to unpack");
        var t2 = L("压缩包会被解开，文件夹会被压成 zip", "Archives are extracted, folders are zipped");
        var f1 = Theme.F(20, true); var f2 = Theme.F(11);
        var s1 = g.MeasureString(t1, f1); var s2 = g.MeasureString(t2, f2);
        float y = (Height - s1.Height - s2.Height - 8) / 2;
        using var b1 = new SolidBrush(Theme.Heading); using var b2 = new SolidBrush(Theme.Secondary);
        g.DrawString(t1, f1, b1, (Width - s1.Width) / 2, y);
        g.DrawString(t2, f2, b2, (Width - s2.Width) / 2, y + s1.Height + 8);
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
    LinkLabel destLink, clearLink;
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
            if (e.Data!.GetData(DataFormats.FileDrop) is string[] files) { Activate(); JobQueue.Shared.Add(files); }
        };

        page.Resize += (_, _) => Relayout();
        JobQueue.Shared.ListChanged += Rebuild;
        JobQueue.Shared.AllDone += () => { var t = new System.Windows.Forms.Timer { Interval = 1200 }; t.Tick += (_, _) => Close(); t.Start(); };
        KeyDown += (_, e) => { if (e.Control && e.KeyCode == Keys.O) { PickFiles(); e.Handled = true; } };
        FormClosing += (_, _) => JobQueue.Shared.CancelAll();
        Rebuild();
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
        var d = Prefs.Current.Dest;
        destLink.Text = L("解压到：", "Extract to: ") + (string.IsNullOrEmpty(d) ? L("压缩包旁边", "next to the archive") : Path.GetFileName(d.TrimEnd('\\'))) + "  ⌄";
    }

    void BuildStatusBar()
    {
        statusBar.Paint += (_, e) => { using var p = new Pen(Theme.Rule); e.Graphics.DrawLine(p, 0, 0, statusBar.Width, 0); };
        var menu = new ContextMenuStrip { Font = Theme.F(9.5f), ShowImageMargin = false };
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
        statusBar.Controls.Add(right);
    }

    void Browse(Job j)
    {
        using var b = new BrowserForm(j);
        b.ShowDialog(this);
    }
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
        if (job.Kind == JobKind.Compress) head.Controls.Add(Theme.Lbl("→ zip", Theme.Faint, 10, false, new Padding(8, 3, 0, 0)));
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
        Box(L("双击压缩包打开时，解完自动退出", "Quit after extracting files opened from Explorer"), p.QuitAfter, v => p.QuitAfter = v);
        Box(L("资源管理器右键菜单加「用解压处理」", "Add “Open with Unpack” to the Explorer context menu"), ContextMenu.Installed, ContextMenu.Set);
        col.Controls.Add(Theme.RuleLine(new Padding(0, 8, 0, 8)));
        Box(L("输对的密码记进密码本（用 Windows 账户加密保存）", "Save correct passwords (encrypted with your Windows account)"), p.RememberPw, v => p.RememberPw = v);
        int saved = Passwords.All().Count;
        var row = Theme.Row(new Padding(0, 6, 0, 0));
        var count = Theme.Lbl(L($"密码本里有 {saved} 个密码", $"{saved} saved passwords"), Theme.Secondary, 10, false, new Padding(0, 0, 12, 0));
        row.Controls.Add(count);
        LinkLabel clear = null;
        clear = Theme.Link(L("清空", "Clear"), () => { Passwords.Save(new List<string>()); count.Text = L("密码本里有 0 个密码", "0 saved passwords"); clear.Enabled = false; });
        clear.Enabled = saved > 0;
        row.Controls.Add(clear);
        col.Controls.Add(row);
        foreach (Control c in col.Controls) if (c is Panel { Height: 1 } r) r.Width = 380;
        Controls.Add(col);
    }
}
