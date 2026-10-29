// 查看内容：像文件夹一样一层层点进去；搜索、勾选只解几个、拖出去就解到那里；双击（或回车）单独解出一个文件用默认程序打开
// zip / 7z / tar 还能直接改：拖文件进来就加到当前文件夹、右键改名（F2）、删除（Delete）；双击打开的文件改完保存，自动写回压缩包
using static Unpack.I18n;

namespace Unpack;

class BrowserForm : Form
{
    readonly string arc;
    string password;
    int? cp;
    readonly ListView list = new()
    {
        View = View.Details, CheckBoxes = true, FullRowSelect = true, BorderStyle = BorderStyle.None, HeaderStyle = ColumnHeaderStyle.Nonclickable,
        Dock = DockStyle.Fill, BackColor = Theme.Bg, ForeColor = Theme.Text, Font = Theme.F(10), AllowDrop = true,
    };
    readonly TextBox search = new() { BorderStyle = BorderStyle.None, Width = 170, Font = Theme.F(10), PlaceholderText = L("搜索", "Search") };
    readonly Label info = Theme.Lbl("", Theme.Secondary, 9.5f);
    readonly Label message = Theme.Lbl(L("正在读取…", "Reading…"), Theme.Faint, 11);
    readonly Label type = Theme.Lbl("", Theme.Faint, 9);
    readonly FlowLayoutPanel crumbs = Theme.Row();
    readonly FlowLayoutPanel tools = Theme.Row();
    readonly FlowLayoutPanel pwPanel = Theme.Column();
    readonly ContextMenuStrip menu = Theme.Menu();
    LinkLabel extractLink, deleteLink;
    Listing listing;
    string blocker;                         // 不能改的原因；null = 能改
    string cwd = "";                        // 现在在包里哪个文件夹（7-Zip 的原始路径），"" = 最外层
    string busy;                            // 正在改包
    readonly HashSet<string> check = new(StringComparer.OrdinalIgnoreCase);
    bool filling;
    // 双击打开、正在别的程序里改的文件：盯着它的修改时间，变了就写回压缩包
    record Watch(string File, string Dir) { public DateTime Stamp; }
    readonly List<Watch> watching = new();
    readonly System.Windows.Forms.Timer watchTimer = new() { Interval = 1500 };

    /// 列表里的一行：真实的文件/文件夹，或者只是从路径里看出来的文件夹（包里没单独记它）
    record Node(string Id, string Name, bool IsDir, long Size, bool Encrypted, DateTime? Modified = null);   // 文件夹的 Modified = 里面最新的
    int sortCol;            // 按哪列排：0 名称 / 1 大小 / 2 修改日期
    bool sortDesc;
    readonly Dictionary<string, string[]> dragged = new();   // 拖出去解好的（松手太早时，再拖一次直接用）

    public BrowserForm(string arc, string password = null)
    {
        this.arc = arc; this.password = password;
        Text = Path.GetFileName(arc);
        try { Icon = Icon.ExtractAssociatedIcon(Environment.ProcessPath ?? Application.ExecutablePath); } catch { }
        StartPosition = FormStartPosition.CenterParent; ShowInTaskbar = false; MinimizeBox = false;
        BackColor = Theme.Bg; Font = Theme.F(10); AutoScaleMode = AutoScaleMode.Dpi;
        ClientSize = new Size(740, 560); MinimumSize = new Size(520, 380);
        KeyPreview = true;
        KeyDown += OnKey;

        // 顶部：标题 + 格式 + 搜索框（只有一条下划线）
        var top = new Panel { Dock = DockStyle.Top, Height = 64, BackColor = Theme.Bg, Padding = new Padding(28, 0, 28, 0) };
        var title = Theme.Lbl(Text, Theme.Heading, 15, true);
        title.AutoEllipsis = true; title.MaximumSize = new Size(440, 0); title.Location = new Point(28, 20);
        title.SizeChanged += (_, _) => type.Location = new Point(title.Right + 10, 30);   // 「zip」紧跟在标题后面
        type.Location = new Point(28 + Math.Min(440, title.PreferredWidth) + 10, 30);
        var sbox = new Panel { Width = 190, Height = 26, Anchor = AnchorStyles.Top | AnchorStyles.Right, BackColor = Theme.Bg };
        sbox.Controls.Add(search);
        search.Location = new Point(0, 4);
        sbox.Paint += (_, e) => { using var p = new Pen(Theme.QuoteBar); e.Graphics.DrawLine(p, 0, sbox.Height - 1, sbox.Width, sbox.Height - 1); };
        sbox.Location = new Point(ClientSize.Width - 28 - 190, 24);
        top.Controls.AddRange(new Control[] { title, type, sbox });
        top.Paint += (_, e) => { using var p = new Pen(Theme.Rule); e.Graphics.DrawLine(p, 28, top.Height - 1, top.Width - 28, top.Height - 1); };
        search.TextChanged += (_, _) => Fill();

        // 面包屑（包名 › 文件夹 › 子文件夹）+ 右边「添加文件…」
        var bar = new Panel { Dock = DockStyle.Top, Height = 34, BackColor = Theme.Bg };
        crumbs.Location = new Point(28, 9);
        tools.FlowDirection = FlowDirection.RightToLeft;
        tools.Dock = DockStyle.Right;
        tools.Padding = new Padding(0, 9, 28, 0);
        bar.Controls.Add(crumbs);
        bar.Controls.Add(tools);

        // 底部：统计/进度/报错 + 关闭 + 删除勾选的 + 解压
        var bottom = new Panel { Dock = DockStyle.Bottom, Height = 44, BackColor = Theme.Bg };
        bottom.Paint += (_, e) => { using var p = new Pen(Theme.Rule); e.Graphics.DrawLine(p, 0, 0, bottom.Width, 0); };
        info.Location = new Point(28, 14);
        info.AutoEllipsis = true;
        var right = Theme.Row();
        right.FlowDirection = FlowDirection.RightToLeft;
        right.Dock = DockStyle.Right;
        right.Padding = new Padding(0, 13, 24, 0);
        extractLink = Theme.Link(L("全部解开", "Extract all"), ExtractChecked);
        extractLink.Enabled = false;
        deleteLink = Theme.Link(L("删除勾选的", "Delete checked"), () => AskDelete(CheckedNodes()), Theme.Error, 10, new Padding(0, 0, 14, 0));
        deleteLink.Visible = false;
        right.Controls.Add(extractLink);
        right.Controls.Add(deleteLink);
        right.Controls.Add(Theme.Link(L("关闭", "Close"), Close, Theme.Secondary, 10, new Padding(0, 0, 14, 0)));
        bottom.Controls.Add(info);
        bottom.Controls.Add(right);
        bottom.Resize += (_, _) => info.MaximumSize = new Size(Math.Max(120, bottom.Width - right.Width - 40), 0);

        var mid = new Panel { Dock = DockStyle.Fill, Padding = new Padding(16, 0, 16, 0), BackColor = Theme.Bg };
        list.Columns.Add(L("名称", "Name"), 480);
        list.Columns.Add(L("大小", "Size"), 90, HorizontalAlignment.Right);
        list.Columns.Add(L("修改日期", "Modified"), 140);
        list.HeaderStyle = ColumnHeaderStyle.Clickable;
        // 列头自己画：深色时跟着变深，点过的列标个 ▲▼（行还是系统画，勾选框照常）
        list.OwnerDraw = true;
        list.DrawItem += (_, e) => e.DrawDefault = true;
        list.DrawSubItem += (_, e) => e.DrawDefault = true;
        list.DrawColumnHeader += (_, e) =>
        {
            using var bg = new SolidBrush(Theme.Bg);
            e.Graphics.FillRectangle(bg, e.Bounds);
            using var line = new Pen(Theme.Rule);
            e.Graphics.DrawLine(line, e.Bounds.Left, e.Bounds.Bottom - 1, e.Bounds.Right, e.Bounds.Bottom - 1);
            var text = e.Header!.Text + (e.ColumnIndex == sortCol ? (sortDesc ? "  ▼" : "  ▲") : "");
            var flags = TextFormatFlags.VerticalCenter | TextFormatFlags.EndEllipsis | (e.Header.TextAlign == HorizontalAlignment.Right ? TextFormatFlags.Right : TextFormatFlags.Left);
            var r = new Rectangle(e.Bounds.X + 6, e.Bounds.Y, e.Bounds.Width - 12, e.Bounds.Height);
            TextRenderer.DrawText(e.Graphics, text, Theme.F(9.5f), r, Theme.Secondary, flags);
        };
        list.ColumnClick += (_, e) => { if (sortCol == e.Column) sortDesc = !sortDesc; else { sortCol = e.Column; sortDesc = false; } Fill(); };
        list.Visible = false;
        list.ContextMenuStrip = menu;
        message.AutoSize = false; message.Dock = DockStyle.Fill; message.TextAlign = ContentAlignment.MiddleCenter;
        BuildPasswordPanel();
        mid.Controls.Add(list);
        mid.Controls.Add(message);
        mid.Controls.Add(pwPanel);
        mid.Resize += (_, _) =>
        {
            list.Columns[0].Width = Math.Max(200, mid.ClientSize.Width - 32 - 250);
            pwPanel.Location = new Point(Math.Max(0, (mid.ClientSize.Width - pwPanel.Width) / 2), Math.Max(0, (mid.ClientSize.Height - pwPanel.Height) / 2));
        };

        Controls.Add(mid);
        Controls.Add(bottom);
        Controls.Add(bar);
        Controls.Add(top);
        Theme.Apply(this);

        list.ItemChecked += (_, e) =>
        {
            if (filling) return;
            var id = ((Node)e.Item.Tag!).Id;
            if (e.Item.Checked) check.Add(id); else check.Remove(id);
            UpdateActions();
        };
        list.ItemActivate += (_, _) => { if (Selected().FirstOrDefault() is { } n) Open(n); };
        list.ItemDrag += (_, _) => DragOut();
        watchTimer.Tick += (_, _) => SyncEdits(false);
        list.DragEnter += (_, e) => e.Effect = blocker == null && busy == null && e.Data!.GetDataPresent(DataFormats.FileDrop) ? DragDropEffects.Copy : DragDropEffects.None;
        list.DragDrop += (_, e) => { if (e.Data!.GetData(DataFormats.FileDrop) is string[] files) Add(files.ToList()); };
        menu.Opening += (_, e) => { BuildMenu(); e.Cancel = menu.Items.Count == 0; };
        Shown += async (_, _) => { JobQueue.Shared.Browsing = true; await Reload(); };
        FormClosed += (_, _) => { JobQueue.Shared.Browsing = false; watchTimer.Stop(); SyncEdits(true); };
    }

    void BuildPasswordPanel()
    {
        pwPanel.Visible = false;
        pwPanel.Anchor = AnchorStyles.None;
        var hint = Theme.Lbl("", Theme.Secondary, 10.5f, false, new Padding(0, 0, 0, 10));
        hint.Name = "hint";
        var row = Theme.Row();
        var box = new TextBox { UseSystemPasswordChar = true, Width = 220, BorderStyle = BorderStyle.FixedSingle, Font = Theme.F(10.5f), PlaceholderText = L("输入密码", "Password"), Margin = new Padding(0, 0, 12, 0) };
        async void Go()
        {
            if (box.Text.Length == 0) return;
            var p = box.Text; box.Text = "";
            await Reload(p);
            if (!pwPanel.Visible && Prefs.Current.RememberPw) Passwords.Remember(p);
        }
        box.KeyDown += (_, e) => { if (e.KeyCode == Keys.Enter) { e.SuppressKeyPress = true; Go(); } };
        row.Controls.Add(box);
        row.Controls.Add(Theme.Link(L("打开", "Open"), Go, null, 10, new Padding(0, 4, 0, 0)));
        pwPanel.Controls.Add(hint);
        pwPanel.Controls.Add(row);
    }

    async Task Reload(string given = null)
    {
        var g = given ?? password;
        var r = await Task.Run(() => { cp ??= NameFixer.CodePage(arc); return Engine.Unlock(arc, g, cp); });
        if (IsDisposed) return;
        if (!r.Ok)
        {
            list.Visible = false;
            if (r.Error.IsPassword)
            {
                message.Visible = false;
                var hint = (Label)pwPanel.Controls["hint"]!;
                hint.Text = given != null ? L("密码不对，再试一次。", "Wrong password, try again.") : L("这个包加了密码，存过的密码都不对。", "This archive is encrypted and no saved password fits.");
                hint.ForeColor = given != null ? Theme.Error : Theme.Secondary;
                pwPanel.Visible = true;
                pwPanel.Parent!.PerformLayout();
                pwPanel.Location = new Point(Math.Max(0, (pwPanel.Parent.ClientSize.Width - pwPanel.Width) / 2), Math.Max(0, (pwPanel.Parent.ClientSize.Height - pwPanel.Height) / 2));
                pwPanel.Controls[1].Controls[0].Focus();
            }
            else message.Text = r.Error.Text;
            return;
        }
        (listing, password) = r.Value;
        dragged.Clear();   // 包改过了：之前解出来准备拖的作废
        blocker = Editor.Blocker(arc, listing, cp);
        // 原来所在的文件夹被删掉、改名了：退回最外层
        if (cwd.Length > 0 && !listing.Entries.Any(e => Same(e.Path, cwd) || Under(e.Path, cwd))) cwd = "";
        check.RemoveWhere(k => !listing.Entries.Any(e => Same(e.Path, k) || Under(e.Path, k)));
        type.Text = listing.Type;
        pwPanel.Visible = false; message.Visible = false; list.Visible = true;
        BuildTools();
        Fill();
        ShowInfo();
        list.Focus();
    }

    static string[] Parts(string p) => p.Split(new[] { '\\', '/' }, StringSplitOptions.RemoveEmptyEntries);
    static bool Same(string a, string b) => string.Equals(a.TrimEnd('\\', '/'), b.TrimEnd('\\', '/'), StringComparison.OrdinalIgnoreCase);
    static bool Under(string path, string dir)
    {
        dir = dir.TrimEnd('\\', '/');
        return path.Length > dir.Length + 1 && path.StartsWith(dir, StringComparison.OrdinalIgnoreCase) && (path[dir.Length] == '\\' || path[dir.Length] == '/');
    }
    /// 路径的前 n 段（保留原来的分隔符），用来当「从路径里看出来的文件夹」的 Id
    static string Prefix(string path, int n)
    {
        int seen = 0;
        for (int i = 0; i < path.Length; i++)
            if ((path[i] == '\\' || path[i] == '/') && i > 0 && path[i - 1] != '\\' && path[i - 1] != '/' && ++seen == n) return path[..i];
        return path;
    }
    static string LastPart(string p) => Parts(p).LastOrDefault() ?? p;

    List<Node> Nodes()
    {
        if (listing == null) return new List<Node>();
        var q = search.Text.Trim();
        if (q.Length > 0)   // 搜索：整个包里找，显示完整路径
            return listing.Entries.Where(e => e.Path.IndexOf(q, StringComparison.OrdinalIgnoreCase) >= 0)
                .Select(e => new Node(e.Path, e.Path, e.IsDir, e.IsDir ? 0 : e.Size, e.Encrypted, e.Modified)).ToList();
        int depth = cwd.Length == 0 ? 0 : Parts(cwd).Length;
        var dirs = new Dictionary<string, (string Name, long Size, DateTime? Date)>(StringComparer.OrdinalIgnoreCase);
        var files = new List<Node>();
        foreach (var e in listing.Entries)
        {
            if (cwd.Length > 0 && !Under(e.Path, cwd)) continue;
            var parts = Parts(e.Path);
            if (parts.Length <= depth) continue;
            if (parts.Length == depth + 1 && !e.IsDir) { files.Add(new Node(e.Path, parts[depth], false, e.Size, e.Encrypted, e.Modified)); continue; }
            var key = Prefix(e.Path, depth + 1);
            var v = dirs.TryGetValue(key, out var d) ? d : (parts[depth], 0L, (DateTime?)null);
            if (!e.IsDir) v.Item2 += e.Size;
            if (e.Modified > (v.Item3 ?? DateTime.MinValue)) v.Item3 = e.Modified;
            dirs[key] = v;
        }
        return dirs.Select(kv => new Node(kv.Key, kv.Value.Name, true, kv.Value.Size, false, kv.Value.Date)).Concat(files).ToList();
    }

    /// 按点的列头排序，文件夹总在前面
    IEnumerable<Node> Sorted(List<Node> ns)
    {
        var cmp = StringComparer.CurrentCultureIgnoreCase;
        IOrderedEnumerable<Node> o = ns.OrderBy(n => !n.IsDir);
        o = sortCol switch
        {
            1 => sortDesc ? o.ThenByDescending(n => n.Size) : o.ThenBy(n => n.Size),
            2 => sortDesc ? o.ThenByDescending(n => n.Modified) : o.ThenBy(n => n.Modified),
            _ => sortDesc ? o.ThenByDescending(n => n.Name, cmp) : o.ThenBy(n => n.Name, cmp),
        };
        return o;
    }

    void Fill()
    {
        if (listing == null) return;
        filling = true;
        list.BeginUpdate();
        list.Items.Clear();
        foreach (var n in Sorted(Nodes()))
        {
            var it = new ListViewItem((n.IsDir ? "📁 " : n.Encrypted ? "🔒 " : "") + n.Name) { Tag = n, Checked = check.Contains(n.Id) };
            if (n.IsDir) it.ForeColor = Theme.LinkColor;
            it.SubItems.Add(n.IsDir && n.Size == 0 ? "" : Bytes(n.Size));
            it.SubItems[1].ForeColor = Theme.Secondary;
            it.SubItems.Add(n.Modified?.ToString("g") ?? "");
            it.SubItems[2].ForeColor = Theme.Secondary;
            list.Items.Add(it);
        }
        list.EndUpdate();
        filling = false;
        BuildCrumbs();
        UpdateActions();
    }

    void BuildCrumbs()
    {
        crumbs.SuspendLayout();
        crumbs.Controls.Clear();
        bool searching = search.Text.Trim().Length > 0;
        var parts = cwd.Length == 0 ? Array.Empty<string>() : Parts(cwd);
        void Crumb(string name, string path, bool last)
        {
            if (last && !searching) crumbs.Controls.Add(Theme.Lbl(name, Theme.Heading, 10));
            else crumbs.Controls.Add(Theme.Link(name, () => Go(path)));
        }
        Crumb(Path.GetFileName(arc), "", parts.Length == 0);
        for (int i = 0; i < parts.Length; i++)
        {
            crumbs.Controls.Add(Theme.Lbl("›", Theme.Faint, 10, false, new Padding(6, 0, 6, 0)));
            Crumb(parts[i], Prefix(cwd, i + 1), i == parts.Length - 1);
        }
        crumbs.ResumeLayout();
    }

    void BuildTools()
    {
        tools.Controls.Clear();
        // 「工具 ⌄」：检查完整性、转成 zip / 7z
        var tm = Theme.Menu();
        tm.Items.Add(L("检查完整性", "Check integrity"), null, (_, _) => Queue(JobKind.Test));
        tm.Items.Add(new ToolStripSeparator());
        foreach (var f in new[] { "zip", "7z" }.Where(f => !f.Equals(listing?.Type, StringComparison.OrdinalIgnoreCase)))
            tm.Items.Add(L($"转成 {f}", $"Convert to {f}"), null, (_, _) => Queue(JobKind.Convert, f));
        LinkLabel toolsLink = null;
        toolsLink = Theme.Link(L("工具  ⌄", "Tools  ⌄"), () => tm.Show(toolsLink, new Point(0, toolsLink.Height)), null, 10, new Padding(14, 0, 0, 0));
        if (blocker != null)
        {
            var why = Theme.Lbl(blocker, Theme.Faint, 9.5f);
            why.AutoEllipsis = true; why.MaximumSize = new Size(360, 0);
            tools.Controls.Add(toolsLink); tools.Controls.Add(why);
            return;
        }
        tools.Controls.Add(toolsLink);
        tools.Controls.Add(Theme.Link(L("添加文件夹…", "Add Folder…"), () =>
        {
            using var f = new FolderBrowserDialog { ShowNewFolderButton = false };
            if (f.ShowDialog(this) == DialogResult.OK) Add(new List<string> { f.SelectedPath });
        }));
        tools.Controls.Add(Theme.Link(L("添加文件…", "Add Files…"), () =>
        {
            using var d = new OpenFileDialog { Multiselect = true, Title = L($"加到压缩包的「{CurrentName}」里", $"Add to “{CurrentName}” in the archive") };
            if (d.ShowDialog(this) == DialogResult.OK) Add(d.FileNames.ToList());
        }, null, 10, new Padding(0, 0, 14, 0)));
    }

    string CurrentName => cwd.Length == 0 ? Path.GetFileName(arc) : LastPart(cwd);

    void Go(string path) { search.Text = ""; cwd = path; Fill(); }

    void Open(Node n)
    {
        if (n.IsDir) Go(n.Id); else Preview(n.Id);
    }

    List<Node> Selected() => list.SelectedItems.Cast<ListViewItem>().Select(i => (Node)i.Tag!).ToList();

    /// 勾了的（可能在别的文件夹里），删除时用
    List<Node> CheckedNodes() => check.OrderBy(k => k).Select(k => new Node(k, LastPart(k), true, 0, false)).ToList();

    /// 这些项（勾了文件夹就连同它里面的全部文件）对应的文件
    List<string> FilesOf(IEnumerable<string> keys)
    {
        if (listing == null) return new List<string>();
        var ks = keys.ToList();
        return listing.Entries.Where(e => !e.IsDir && ks.Any(k => Same(e.Path, k) || Under(e.Path, k))).Select(e => e.Path).ToList();
    }

    void UpdateActions()
    {
        if (busy != null)
        {
            info.Text = busy; info.ForeColor = Theme.Secondary;
            extractLink.Enabled = false; deleteLink.Enabled = false;
            return;
        }
        int n = check.Count == 0 ? 0 : FilesOf(check).Count;
        extractLink.Text = check.Count == 0 ? L("全部解开", "Extract all") : L($"解压勾选的 {n} 项", $"Extract {n} checked");
        extractLink.Enabled = listing != null && (check.Count == 0 || n > 0);
        deleteLink.Visible = blocker == null && check.Count > 0;
        deleteLink.Enabled = true;
    }

    void ShowInfo()
    {
        if (listing == null) return;
        int files = listing.Entries.Count(e => !e.IsDir);
        info.ForeColor = Theme.Secondary;
        info.Text = watching.Count > 0 ? L("改完保存，会自动写回压缩包", "Save your changes; they're written back automatically")
            : L($"{files} 个文件，共 {Bytes(listing.TotalSize)}；双击打开，拖出去就解到那里", $"{files} files, {Bytes(listing.TotalSize)}; double-click to open, drag out to extract");
    }

    void Queue(JobKind kind, string to = null)
    {
        JobQueue.Shared.Add(new Job(kind, new List<string> { arc }, null, password) { ConvertTo = to });
        Close();
    }

    /// 拖出去：把选中的几项解到临时目录（保持包里的层级），交给资源管理器当普通文件拖
    bool draggingOut;

    /// 拖出去：把选中的几项解到临时目录（保持包里的层级），交给资源管理器当普通文件拖。
    /// 大文件解得久：边解边在底部显示进度、窗口不卡；解完鼠标还按着就接着拖，已经松手了就提示再拖一次（解好的留着，第二次马上出去）
    async void DragOut()
    {
        var sel = Selected();
        if (sel.Count == 0 || listing == null || busy != null || draggingOut) return;
        var key = string.Join("|", sel.Select(n => n.Id).OrderBy(x => x));
        if (!dragged.TryGetValue(key, out var paths) || !paths.All(p => File.Exists(p) || Directory.Exists(p)))
        {
            draggingOut = true;
            var dir = Path.Combine(Path.GetTempPath(), "unpack-drag-" + Guid.NewGuid().ToString("N")[..8]);
            var files = FilesOf(sel.Select(n => n.Id)); var l = listing; var pw = password; var c = cp;
            info.ForeColor = Theme.Secondary; info.Text = L("正在解出来…", "Extracting…");
            var r = await Task.Run(() => Engine.Extract(arc, pw, l, files, c, new Runner(),
                p => Ui.Post(() => { if (!IsDisposed) info.Text = L($"正在解出来… {(int)(p.Fraction * 100)}%", $"Extracting… {(int)(p.Fraction * 100)}%"); }), dir, false));
            draggingOut = false;
            if (IsDisposed) return;
            if (!r.Ok) { info.Text = r.Error.Text; info.ForeColor = Theme.Error; return; }
            // Extract 会把只有一个顶层项的直接放出来：按包里的路径找回每一项
            paths = sel.Select(n => new[] { Path.Combine(dir, n.Id.Replace('/', '\\')), Path.Combine(dir, LastPart(n.Id)) }
                    .FirstOrDefault(p => File.Exists(p) || Directory.Exists(p))).Where(p => p != null).Distinct().ToArray();
            if (paths.Length == 0) paths = Engine.Visible(dir).ToArray();
            dragged[key] = paths;
            ShowInfo();
            if ((MouseButtons & MouseButtons.Left) == 0)
            {
                info.Text = L("解好了，再拖一次就出去了", "Ready — drag again to drop it"); info.ForeColor = Theme.Ok;
                return;
            }
        }
        if (paths.Length > 0) list.DoDragDrop(new DataObject(DataFormats.FileDrop, paths), DragDropEffects.Copy | DragDropEffects.Move);
    }

    void ExtractChecked()
    {
        JobQueue.Shared.Add(new Job(JobKind.Extract, new List<string> { arc }, check.Count == 0 ? null : FilesOf(check), password));
        Close();
    }

    void BuildMenu()
    {
        menu.Items.Clear();
        var sel = Selected();
        if (sel.Count == 0) return;
        if (sel.Count == 1) menu.Items.Add(sel[0].IsDir ? L("打开", "Open") : blocker == null ? L("打开（改完自动写回）", "Open (changes are saved back)") : L("打开", "Open"), null, (_, _) => Open(sel[0]));
        menu.Items.Add(L($"解压这 {sel.Count} 项", $"Extract {sel.Count} items"), null, (_, _) =>
            JobQueue.Shared.Add(new Job(JobKind.Extract, new List<string> { arc }, FilesOf(sel.Select(s => s.Id)), password)));
        if (blocker != null || busy != null) return;
        menu.Items.Add(new ToolStripSeparator());
        if (sel.Count == 1) menu.Items.Add(L("改名…\tF2", "Rename…\tF2"), null, (_, _) => AskRename(sel[0]));
        menu.Items.Add(L("删除…\tDelete", "Delete…\tDelete"), null, (_, _) => AskDelete(sel));
    }

    void OnKey(object sender, KeyEventArgs e)
    {
        if (e.KeyCode == Keys.Escape) { Close(); return; }
        if (search.Focused || listing == null) return;
        var sel = Selected();
        if (e.KeyCode == Keys.Delete && sel.Count > 0 && blocker == null && busy == null) { AskDelete(sel); e.Handled = true; }
        else if (e.KeyCode == Keys.F2 && sel.Count == 1 && blocker == null && busy == null) { AskRename(sel[0]); e.Handled = true; }
        else if (e.KeyCode == Keys.Back && cwd.Length > 0) { var p = Parts(cwd); Go(p.Length > 1 ? Prefix(cwd, p.Length - 1) : ""); e.Handled = true; }
    }

    /// 在后台改包，改完重新读一遍内容；done：成功后底部显示的话
    async void Edit(string label, Func<Listing, string, Result<bool>> op, string done = null)
    {
        if (listing == null || busy != null) return;
        busy = label; UpdateActions();
        var l = listing; var pw = password;
        var r = await Task.Run(() => op(l, pw));
        if (IsDisposed) return;
        busy = null;
        await Reload();
        if (!r.Ok) { info.Text = r.Error.Text; info.ForeColor = Theme.Error; }
        else if (done != null) { info.Text = "✓ " + done; info.ForeColor = Theme.Ok; }
        else ShowInfo();
        UpdateActions();
    }

    static DateTime Stamp(string f) { try { return File.GetLastWriteTimeUtc(f); } catch { return DateTime.MinValue; } }

    /// 有文件改过：等它停了一会儿（别的程序写完）再写回；关窗口时不等，直接写
    void SyncEdits(bool final)
    {
        if (busy != null || listing == null) return;
        foreach (var w in watching)
        {
            var now = Stamp(w.File);
            if (now <= w.Stamp || (!final && (DateTime.UtcNow - now).TotalSeconds < 1)) continue;
            w.Stamp = now;
            var name = Path.GetFileName(w.File); var c = cp;
            if (final) { var l = listing; var pw = password; Task.Run(() => Editor.Add(new List<string> { w.File }, w.Dir, arc, l, pw, c, new Runner())).Wait(); continue; }
            Edit(L($"正在把「{name}」写回压缩包…", $"Saving “{name}” into the archive…"),
                (l, pw) => Editor.Add(new List<string> { w.File }, w.Dir, arc, l, pw, c, new Runner()),
                L($"已把「{name}」的修改写回压缩包", $"Saved “{name}” into the archive"));
            return;   // 一次写一个
        }
    }

    void Add(List<string> files)
    {
        if (blocker != null || busy != null || files.Count == 0) return;
        bool searching = search.Text.Trim().Length > 0;
        var here = new HashSet<string>(Nodes().Select(n => LastPart(n.Id)), StringComparer.OrdinalIgnoreCase);
        int clash = searching ? 0 : files.Count(f => here.Contains(Path.GetFileName(f.TrimEnd('\\', '/'))));
        if (clash > 0 && MessageBox.Show(this, L($"这里已经有 {clash} 个同名的，替换掉？", $"Replace {clash} items with the same name?"), AppName,
                MessageBoxButtons.OKCancel, MessageBoxIcon.Question) != DialogResult.OK) return;
        var dir = searching ? "" : cwd; var c = cp;
        Edit(L("正在加进压缩包…", "Adding…"), (l, pw) => Editor.Add(files, dir, arc, l, pw, c, new Runner()));
    }

    void AskDelete(List<Node> nodes)
    {
        if (nodes.Count == 0 || blocker != null || busy != null) return;
        var q = nodes.Count == 1 ? L($"从压缩包里删掉「{nodes[0].Name}」？", $"Delete “{nodes[0].Name}” from the archive?")
            : L($"从压缩包里删掉这 {nodes.Count} 项？", $"Delete {nodes.Count} items from the archive?");
        q += "\n\n" + L("直接改原压缩包，删了找不回来（回收站里也没有）。", "This changes the archive itself and can't be undone.");
        if (MessageBox.Show(this, q, AppName, MessageBoxButtons.OKCancel, MessageBoxIcon.Warning, MessageBoxDefaultButton.Button2) != DialogResult.OK) return;
        var paths = nodes.Select(n => n.Id).ToList(); var c = cp;
        foreach (var p in paths) check.Remove(p);
        Edit(L("正在删除…", "Deleting…"), (l, pw) => Editor.Delete(paths, arc, l, pw, c, new Runner()));
    }

    void AskRename(Node n)
    {
        var old = LastPart(n.Id);
        var name = Prompt.Ask(this, L("改名", "Rename"), old)?.Trim();
        if (string.IsNullOrEmpty(name) || name == old) return;
        if (name.IndexOfAny(new[] { '\\', '/' }) >= 0 || name.IndexOfAny(Path.GetInvalidFileNameChars()) >= 0)
        {
            info.Text = L("名字里不能有 \\ / : * ? \" < > |", "Names can't contain \\ / : * ? \" < > |"); info.ForeColor = Theme.Error; return;
        }
        int i = n.Id.TrimEnd('\\', '/').LastIndexOfAny(new[] { '\\', '/' });
        var dest = i < 0 ? name : n.Id[..(i + 1)] + name;
        if (!string.Equals(old, name, StringComparison.OrdinalIgnoreCase) && listing.Entries.Any(e => Same(e.Path, dest) || Under(e.Path, dest)))
        {
            info.Text = L($"这里已经有叫「{name}」的了", $"“{name}” already exists here"); info.ForeColor = Theme.Error; return;
        }
        var c = cp;
        check.Remove(n.Id);
        Edit(L("正在改名…", "Renaming…"), (l, pw) => Editor.Rename(n.Id, name, arc, l, pw, c, new Runner()));
    }

    /// 把这一项单独解到临时目录，用默认程序打开；能改的包就盯着它，保存了就写回去
    async void Preview(string path)
    {
        var e = listing?.Entries.FirstOrDefault(x => x.Path == path);
        if (e == null || e.IsDir) return;
        var pw = password ?? ""; var c = cp; bool editable = blocker == null;
        int i = path.TrimEnd('\\', '/').LastIndexOfAny(new[] { '\\', '/' });
        var dirInArc = i < 0 ? "" : path[..i];
        var f = await Task.Run(() =>
        {
            var dir = Path.Combine(Path.GetTempPath(), $"unpack-preview-{e.Id}-{Guid.NewGuid():N}"[..40]);
            SevenZip.Run(new[] { "e", "-y", "-spd", "-sccUTF-8", "-p" + pw }.Concat(SevenZip.Cp(c)).Concat(new[] { "-o" + dir, arc, e.Path }));
            return Directory.Exists(dir) ? Directory.EnumerateFiles(dir, "*", SearchOption.AllDirectories).FirstOrDefault() : null;
        });
        if (f == null || IsDisposed) return;
        if (editable)
        {
            watching.Add(new Watch(f, dirInArc) { Stamp = Stamp(f) });
            watchTimer.Start();
            ShowInfo();
        }
        Shell.Open(f);
    }
}

/// 一行输入框的小对话框（改名用）
static class Prompt
{
    public static string Ask(IWin32Window owner, string title, string initial)
    {
        using var f = new Form
        {
            Text = title, FormBorderStyle = FormBorderStyle.FixedDialog, MaximizeBox = false, MinimizeBox = false, ShowInTaskbar = false,
            StartPosition = FormStartPosition.CenterParent, BackColor = Theme.Bg, Font = Theme.F(10), AutoScaleMode = AutoScaleMode.Dpi,
            ClientSize = new Size(380, 120),
        };
        var box = new TextBox { Text = initial, BorderStyle = BorderStyle.FixedSingle, Font = Theme.F(10.5f), Bounds = new Rectangle(20, 22, 340, 28) };
        var ok = new Button { Text = L("改名", "Rename"), DialogResult = DialogResult.OK, Bounds = new Rectangle(180, 70, 85, 30) };
        var cancel = new Button { Text = L("取消", "Cancel"), DialogResult = DialogResult.Cancel, Bounds = new Rectangle(275, 70, 85, 30) };
        f.Controls.AddRange(new Control[] { box, ok, cancel });
        Theme.Apply(f);
        f.AcceptButton = ok; f.CancelButton = cancel;
        // 默认只选中名字、不选扩展名，和资源管理器改名一样
        f.Shown += (_, _) => { box.Focus(); int dot = initial.LastIndexOf('.'); box.Select(0, dot > 0 ? dot : initial.Length); };
        return f.ShowDialog(owner) == DialogResult.OK ? box.Text : null;
    }
}
