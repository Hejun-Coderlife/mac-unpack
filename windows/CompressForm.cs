// 新建压缩包：名字、格式（zip / 7z）、压缩程度、密码、分卷——按住 Alt 拖进来或 Ctrl+N 时弹出
using static Unpack.I18n;

namespace Unpack;

class CompressForm : Form
{
    readonly List<string> srcs;
    readonly CompressOptions o = CompressOptions.FromPrefs();
    readonly TextBox name = new() { BorderStyle = BorderStyle.FixedSingle, Width = 260, Font = Theme.F(10.5f) };
    readonly Label ext = Theme.Lbl("", Theme.Faint, 10, false, new Padding(4, 4, 0, 0));
    readonly RadioButton zip = new() { Text = "zip", AutoSize = true, Margin = new Padding(0, 0, 14, 0) };
    readonly RadioButton sevenZ = new() { Text = "7z", AutoSize = true };
    readonly Label formatHint = Theme.Lbl("", Theme.Faint, 9, false, new Padding(0, 2, 0, 0));
    readonly ComboBox level = new() { DropDownStyle = ComboBoxStyle.DropDownList, Width = 180 };
    readonly TextBox pw = new() { UseSystemPasswordChar = true, BorderStyle = BorderStyle.FixedSingle, Width = 260, Font = Theme.F(10.5f), PlaceholderText = L("不设就留空", "Leave empty for none") };
    readonly TextBox again = new() { UseSystemPasswordChar = true, BorderStyle = BorderStyle.FixedSingle, Width = 260, Font = Theme.F(10.5f), PlaceholderText = L("再输一次", "Repeat"), Margin = new Padding(0, 8, 0, 0) };
    readonly Label mismatch = Theme.Lbl(L("两次输的不一样", "Passwords don't match"), Theme.Error, 9, false, new Padding(0, 4, 0, 0));
    readonly CheckBox encryptNames = new() { Text = L("文件名也加密（不输密码看不到里面有什么）", "Encrypt file names too"), AutoSize = true, Checked = true, Margin = new Padding(0, 6, 0, 0) };
    readonly Label pwHint = Theme.Lbl(L("AES-256 加密。Windows 自带的解压打不开，要用 7-Zip、WinRAR 或「解压」", "AES-256. Windows' built-in tool can't open it; use 7-Zip, WinRAR or Unpack"), Theme.Faint, 9, false, new Padding(0, 6, 0, 0));
    readonly CheckBox remember = new() { Text = L("记进密码本，自己以后解开不用再输", "Save to my password book"), AutoSize = true, Margin = new Padding(0, 6, 0, 0) };
    readonly FlowLayoutPanel pwExtra = Theme.Column();
    readonly ComboBox split = new() { DropDownStyle = ComboBoxStyle.DropDownList, Width = 220 };
    readonly Label splitHint = Theme.Lbl("", Theme.Faint, 9, false, new Padding(0, 2, 0, 0));
    LinkLabel go;

    public CompressForm(List<string> srcs)
    {
        this.srcs = srcs;
        Text = L("新建压缩包", "New Archive");
        try { Icon = Icon.ExtractAssociatedIcon(Environment.ProcessPath ?? Application.ExecutablePath); } catch { }
        FormBorderStyle = FormBorderStyle.FixedDialog; MaximizeBox = false; MinimizeBox = false; ShowInTaskbar = false;
        StartPosition = FormStartPosition.CenterParent;
        BackColor = Theme.Bg; Font = Theme.F(10); ForeColor = Theme.Text; AutoScaleMode = AutoScaleMode.Dpi;
        AutoSize = true; AutoSizeMode = AutoSizeMode.GrowAndShrink;
        KeyPreview = true;
        KeyDown += (_, e) => { if (e.KeyCode == Keys.Escape) Close(); else if (e.KeyCode == Keys.Enter && go.Enabled) { e.SuppressKeyPress = true; Go(); } };

        var col = Theme.Column();
        col.Padding = new Padding(28, 20, 28, 14);
        var head = Theme.Row(new Padding(0, 0, 0, 10));
        head.Controls.Add(Theme.Lbl(Text, Theme.Heading, 15, true));
        var what = Theme.Lbl(srcs.Count == 1 ? Path.GetFileName(srcs[0].TrimEnd('\\', '/')) : L($"{srcs.Count} 个项目", $"{srcs.Count} items"), Theme.Secondary, 10, false, new Padding(10, 8, 0, 0));
        what.AutoEllipsis = true; what.MaximumSize = new Size(260, 0);
        var size = Theme.Lbl("", Theme.Faint, 10, false, new Padding(8, 8, 0, 0));
        head.Controls.Add(what); head.Controls.Add(size);
        col.Controls.Add(head);
        var rule = Theme.RuleLine(new Padding(0, 0, 0, 14)); rule.Width = 520;
        col.Controls.Add(rule);

        var grid = new TableLayoutPanel { ColumnCount = 2, AutoSize = true, AutoSizeMode = AutoSizeMode.GrowAndShrink, Margin = Padding.Empty };
        grid.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 80));
        grid.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        void Row(string label, Control c)
        {
            var l = Theme.Lbl(label, Theme.Secondary, 10, false, new Padding(0, 4, 12, 14));
            l.Anchor = AnchorStyles.Top | AnchorStyles.Right;
            c.Margin = new Padding(0, 0, 0, 14);
            grid.Controls.Add(l); grid.Controls.Add(c);
        }

        name.PlaceholderText = CompressOptions.DefaultName(srcs);
        var nameRow = Theme.Row(); nameRow.Controls.Add(name); nameRow.Controls.Add(ext);
        Row(L("名字", "Name"), nameRow);

        var fmt = Theme.Column();
        var radios = Theme.Row(); radios.Controls.Add(zip); radios.Controls.Add(sevenZ);
        fmt.Controls.Add(radios); fmt.Controls.Add(formatHint);
        Row(L("格式", "Format"), fmt);
        (o.Format == "7z" ? sevenZ : zip).Checked = true;
        zip.CheckedChanged += (_, _) => Sync();

        foreach (var (_, t) in CompressOptions.Levels) level.Items.Add(t);
        level.SelectedIndex = Math.Max(0, Array.FindIndex(CompressOptions.Levels, x => x.Item1 == o.Level));
        Row(L("压缩", "Level"), level);

        var pwCol = Theme.Column();
        pwCol.Controls.Add(pw);
        pwExtra.Controls.AddRange(new Control[] { again, mismatch, encryptNames, pwHint, remember });
        pwCol.Controls.Add(pwExtra);
        remember.Checked = Prefs.Current.RememberPw;
        pw.TextChanged += (_, _) => Sync();
        again.TextChanged += (_, _) => Sync();
        Row(L("密码", "Password"), pwCol);

        foreach (var (_, t) in CompressOptions.Splits) split.Items.Add(t);
        split.SelectedIndex = 0;
        split.SelectedIndexChanged += (_, _) => Sync();
        var splitCol = Theme.Column(); splitCol.Controls.Add(split); splitCol.Controls.Add(splitHint);
        Row(L("分卷", "Split"), splitCol);
        col.Controls.Add(grid);

        var rule2 = Theme.RuleLine(new Padding(0, 6, 0, 10)); rule2.Width = 520;
        col.Controls.Add(rule2);
        var buttons = Theme.Row();
        buttons.FlowDirection = FlowDirection.RightToLeft;
        buttons.Width = 520; buttons.AutoSize = false; buttons.Height = 24;
        go = Theme.Link(L("压缩", "Compress"), Go);
        buttons.Controls.Add(go);
        buttons.Controls.Add(Theme.Link(L("取消", "Cancel"), Close, Theme.Secondary, 10, new Padding(0, 0, 14, 0)));
        col.Controls.Add(buttons);
        foreach (var l in new[] { formatHint, pwHint, splitHint }) l.MaximumSize = new Size(400, 0);
        Controls.Add(col);
        Sync();

        Shown += async (_, _) => { long n = await Task.Run(() => srcs.Sum(Fs.SizeOf)); if (!IsDisposed) size.Text = Bytes(n); name.Focus(); };
    }

    string Format => sevenZ.Checked ? "7z" : "zip";

    void Sync()
    {
        ext.Text = "." + Format;
        formatHint.Text = Format == "zip" ? L("Windows、Mac 双击就能打开", "Opens anywhere with a double-click")
            : L("一般比 zip 小一些，对方要装解压软件（7-Zip、WinRAR、「解压」）", "Usually smaller; needs an app like 7-Zip to open");
        bool hasPw = pw.Text.Length > 0;
        pwExtra.Visible = hasPw;
        encryptNames.Visible = Format == "7z";
        pwHint.Visible = Format == "zip";
        bool bad = hasPw && again.Text != pw.Text;
        mismatch.Visible = bad && again.Text.Length > 0;
        go.Enabled = !bad;
        int mb = CompressOptions.Splits[Math.Max(0, split.SelectedIndex)].Item1;
        splitHint.Text = mb > 0 ? L($"出来的是 名字.{Format}.001、.002…，对方要全部收齐放一起再解", "Produces .001, .002…; all parts are needed to extract") : "";
        splitHint.Visible = mb > 0;
    }

    void Go()
    {
        o.Name = string.Join("-", name.Text.Trim().Split(Path.GetInvalidFileNameChars()));
        o.Format = Format;
        o.Level = CompressOptions.Levels[Math.Max(0, level.SelectedIndex)].Item1;
        o.Password = pw.Text;
        o.EncryptNames = encryptNames.Checked;
        o.SplitMB = CompressOptions.Splits[Math.Max(0, split.SelectedIndex)].Item1;
        if (o.Password.Length > 0 && remember.Checked) Passwords.Remember(o.Password);
        JobQueue.Shared.Add(new Job(JobKind.Compress, srcs, options: o));
        Close();
    }
}
