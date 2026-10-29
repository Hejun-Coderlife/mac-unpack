// 查看内容：搜索、勾选只解几个、双击（或回车）单独解出一个文件用默认程序预览
using static Unpack.I18n;

namespace Unpack;

class BrowserForm : Form
{
    readonly Job job;
    readonly ListView list = new()
    {
        View = View.Details, CheckBoxes = true, FullRowSelect = true, BorderStyle = BorderStyle.None, HeaderStyle = ColumnHeaderStyle.Nonclickable,
        Dock = DockStyle.Fill, BackColor = Theme.Bg, ForeColor = Theme.Text, Font = Theme.F(10),
    };
    readonly TextBox search = new() { BorderStyle = BorderStyle.None, Width = 170, Font = Theme.F(10), PlaceholderText = L("搜索", "Search") };
    readonly Label info = Theme.Lbl("", Theme.Secondary, 9.5f);
    readonly Label message = Theme.Lbl(L("正在读取…", "Reading…"), Theme.Faint, 11);
    LinkLabel extractLink;
    Listing listing;
    string password;
    readonly HashSet<int> check = new();
    bool filling;

    public BrowserForm(Job job)
    {
        this.job = job;
        Text = Path.GetFileName(job.Sources[0]);
        try { Icon = Icon.ExtractAssociatedIcon(Environment.ProcessPath ?? Application.ExecutablePath); } catch { }
        StartPosition = FormStartPosition.CenterParent; ShowInTaskbar = false; MinimizeBox = false;
        BackColor = Theme.Bg; Font = Theme.F(10); AutoScaleMode = AutoScaleMode.Dpi;
        ClientSize = new Size(680, 520); MinimumSize = new Size(480, 360);
        KeyPreview = true;
        KeyDown += (_, e) => { if (e.KeyCode == Keys.Escape) Close(); };

        // 顶部：标题 + 格式 + 搜索框（只有一条下划线）
        var top = new Panel { Dock = DockStyle.Top, Height = 64, BackColor = Theme.Bg, Padding = new Padding(28, 0, 28, 0) };
        var title = Theme.Lbl(Text, Theme.Heading, 15, true);
        title.AutoEllipsis = true; title.AutoSize = false; title.SetBounds(28, 20, 380, 32);
        var type = Theme.Lbl("", Theme.Faint, 9);
        type.Location = new Point(412, 30);
        var sbox = new Panel { Width = 190, Height = 26, Anchor = AnchorStyles.Top | AnchorStyles.Right, BackColor = Theme.Bg };
        sbox.Controls.Add(search);
        search.Location = new Point(0, 4);
        sbox.Paint += (_, e) => { using var p = new Pen(Theme.QuoteBar); e.Graphics.DrawLine(p, 0, sbox.Height - 1, sbox.Width, sbox.Height - 1); };
        sbox.Location = new Point(ClientSize.Width - 28 - 190, 24);
        top.Controls.AddRange(new Control[] { title, type, sbox });
        top.Paint += (_, e) => { using var p = new Pen(Theme.Rule); e.Graphics.DrawLine(p, 28, top.Height - 1, top.Width - 28, top.Height - 1); };
        search.TextChanged += (_, _) => Fill();

        // 底部：统计 + 关闭 + 解压勾选的
        var bottom = new Panel { Dock = DockStyle.Bottom, Height = 44, BackColor = Theme.Bg };
        bottom.Paint += (_, e) => { using var p = new Pen(Theme.Rule); e.Graphics.DrawLine(p, 0, 0, bottom.Width, 0); };
        info.Location = new Point(28, 14);
        var right = Theme.Row();
        right.FlowDirection = FlowDirection.RightToLeft;
        right.Dock = DockStyle.Right;
        right.Padding = new Padding(0, 13, 24, 0);
        extractLink = Theme.Link(L("勾选后可只解这几项", "Check items to extract"), ExtractChecked);
        extractLink.Enabled = false;
        right.Controls.Add(extractLink);
        right.Controls.Add(Theme.Link(L("关闭", "Close"), Close, Theme.Secondary, 10, new Padding(0, 0, 14, 0)));
        bottom.Controls.Add(info);
        bottom.Controls.Add(right);

        var mid = new Panel { Dock = DockStyle.Fill, Padding = new Padding(16, 6, 16, 0), BackColor = Theme.Bg };
        list.Columns.Add(L("名称", "Name"), 480);
        list.Columns.Add(L("大小", "Size"), 110, HorizontalAlignment.Right);
        list.Visible = false;
        message.AutoSize = false; message.Dock = DockStyle.Fill; message.TextAlign = ContentAlignment.MiddleCenter;
        mid.Controls.Add(list);
        mid.Controls.Add(message);
        mid.Resize += (_, _) => list.Columns[0].Width = Math.Max(200, mid.ClientSize.Width - 32 - 130);

        Controls.Add(mid);
        Controls.Add(bottom);
        Controls.Add(top);

        list.ItemChecked += (_, e) =>
        {
            if (filling) return;
            var id = (int)e.Item.Tag!;
            if (e.Item.Checked) check.Add(id); else check.Remove(id);
            UpdateExtract();
        };
        list.ItemActivate += (_, _) => { if (list.SelectedItems.Count > 0) Preview((int)list.SelectedItems[0].Tag!); };
        Shown += async (_, _) =>
        {
            var arc = job.Sources[0]; var given = job.Password; var cp = job.CodePage ?? NameFixer.CodePage(arc);
            job.CodePage = cp;
            var r = await Task.Run(() => Engine.Unlock(arc, given, cp));
            if (IsDisposed) return;
            if (!r.Ok)
            {
                message.Text = r.Error.IsPassword ? L("文件名也加密了，先在列表里输入密码。", "Filenames are encrypted — enter the password first.") : r.Error.Text;
                return;
            }
            (listing, password) = r.Value;
            type.Text = listing.Type;
            int files = listing.Entries.Count(e => !e.IsDir);
            info.Text = L($"{files} 个文件，解开共 {Bytes(listing.TotalSize)}；双击预览", $"{files} files, {Bytes(listing.TotalSize)}; double-click to preview");
            message.Visible = false; list.Visible = true;
            Fill();
        };
    }

    void Fill()
    {
        if (listing == null) return;
        filling = true;
        list.BeginUpdate();
        list.Items.Clear();
        var q = search.Text.Trim();
        foreach (var e in listing.Entries)
        {
            if (q.Length > 0 && e.Path.IndexOf(q, StringComparison.OrdinalIgnoreCase) < 0) continue;
            var it = new ListViewItem((e.IsDir ? "📁 " : e.Encrypted ? "🔒 " : "") + e.Path) { Tag = e.Id, Checked = check.Contains(e.Id) };
            if (e.IsDir) it.ForeColor = Theme.LinkColor;
            it.SubItems.Add(e.IsDir ? "" : Bytes(e.Size));
            it.SubItems[1].ForeColor = Theme.Secondary;
            list.Items.Add(it);
        }
        list.EndUpdate();
        filling = false;
    }

    /// 勾了文件夹就连同它里面的全部文件
    List<string> CheckedFiles()
    {
        if (listing == null) return new List<string>();
        var dirs = listing.Entries.Where(e => check.Contains(e.Id) && e.IsDir).Select(e => e.Path.TrimEnd('\\', '/') + "\\").ToList();
        bool InDir(string p) => dirs.Any(d => p.StartsWith(d, StringComparison.OrdinalIgnoreCase) || p.Replace('/', '\\').StartsWith(d, StringComparison.OrdinalIgnoreCase));
        return listing.Entries.Where(e => !e.IsDir && (check.Contains(e.Id) || InDir(e.Path))).Select(e => e.Path).ToList();
    }

    void UpdateExtract()
    {
        int n = CheckedFiles().Count;
        extractLink.Text = n == 0 ? L("勾选后可只解这几项", "Check items to extract") : L($"解压勾选的 {n} 项", $"Extract {n} checked");
        extractLink.Enabled = n > 0;
    }

    void ExtractChecked()
    {
        var files = CheckedFiles();
        if (files.Count == 0) return;
        JobQueue.Shared.Add(new Job(JobKind.Extract, job.Sources, files, password));
        Close();
    }

    /// 把这一项单独解到临时目录，用默认程序打开
    void Preview(int id)
    {
        var e = listing?.Entries.FirstOrDefault(x => x.Id == id);
        if (e == null || e.IsDir) return;
        var arc = job.Sources[0]; var pw = password ?? ""; var cp = job.CodePage;
        Task.Run(() =>
        {
            var dir = Path.Combine(Path.GetTempPath(), $"unpack-preview-{id}-{Guid.NewGuid():N}"[..40]);
            SevenZip.Run(new[] { "e", "-y", "-spd", "-sccUTF-8", "-p" + pw }.Concat(SevenZip.Cp(cp)).Concat(new[] { "-o" + dir, arc, e.Path }));
            var f = Directory.Exists(dir) ? Directory.EnumerateFiles(dir, "*", SearchOption.AllDirectories).FirstOrDefault() : null;
            if (f != null) Shell.Open(f);
        });
    }
}
