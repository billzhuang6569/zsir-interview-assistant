using System.Drawing.Drawing2D;

namespace ZSirCapture;

internal sealed class SettingsForm : Form
{
    readonly MainForm owner;
    readonly RecordingOptions options;
    readonly ToolTip tips = new();
    readonly Panel scroll = new() { Dock = DockStyle.Fill, AutoScroll = true };
    readonly TableLayoutPanel content = Theme.Column(), mainPage = Theme.Column(), advancedPage = Theme.Column();
    readonly FlowLayoutPanel displays = new() { AutoSize = true, AutoSizeMode = AutoSizeMode.GrowAndShrink,
        Dock = DockStyle.Top, WrapContents = true, Margin = new Padding(0, 8, 0, 8) };
    readonly Label heading = Theme.Label("录制设置"), estimate = Theme.Label("", true),
        savePath = Theme.Label("", true), advancedPath = Theme.Label("", true);
    readonly ComboBox audio = Theme.Combo("播放设备"), outputSize = Theme.Combo("输出尺寸"), quality = Theme.Combo("画质");
    readonly CheckBox stealth, captureAudio;
    readonly Button back, done, advanced;
    readonly Theme.Card desktop = new(), advancedCard = new();
    bool recovering, fitting, loading;
    float layoutScale = 1;
    internal bool IsAdvanced { get; private set; }

    internal SettingsForm(MainForm owner, RecordingOptions options)
    {
        SuspendLayout();
        this.owner = owner; this.options = options;
        Text = "录制设置"; Icon = owner.Icon;
        Theme.Window(this); DoubleBuffered = true;
        StartPosition = FormStartPosition.CenterParent;
        FormBorderStyle = FormBorderStyle.Sizable; MinimizeBox = false; MaximizeBox = false; ShowInTaskbar = false;
        ClientSize = new(680, 760);
        content.Padding = new Padding(24);
        heading.Font = Theme.Font(20, FontStyle.Bold);
        back = Theme.IconButton("\uE72B", "返回录制设置", tips);
        back.Visible = false; back.Click += (_, _) => ShowAdvanced(false);
        heading.Dock = DockStyle.Fill;
        var header = Theme.Row(1, back, heading);
        header.Margin = new Padding(0, 0, 0, 12); Theme.Add(content, header);
        var cardTitle = Theme.Label("桌面画面"); cardTitle.Font = Theme.Font(12, FontStyle.Bold);
        Theme.Add(desktop, cardTitle); Theme.Add(desktop, displays);
        captureAudio = Theme.Toggle("同时录下电脑里播放的声音", options.SystemAudio);
        Theme.Add(desktop, captureAudio);
        Theme.Add(desktop, Theme.Label("默认播放设备（全部播放声音），也可指定输出设备", true));
        Theme.Add(desktop, audio); audio.Enabled = options.SystemAudio;
        Theme.Add(desktop, Theme.Label("输出尺寸 · 固定 30 fps，保持比例，不放大", true));
        outputSize.Items.AddRange(["均衡 · 最长边 1920 像素", "1440p · 最长边 2560 像素", "原始尺寸"]);
        string[] profiles = ["balanced", "detailed", "native"];
        int profileIndex = Array.IndexOf(profiles, options.OutputProfile); outputSize.SelectedIndex = profileIndex >= 0 ? profileIndex : 2;
        Theme.Add(desktop, outputSize);
        Theme.Add(desktop, Theme.Label("画质"));
        quality.Items.AddRange(["省空间", "标准 · 推荐", "高画质"]);
        string[] levels = ["compact", "standard", "high"];
        quality.SelectedIndex = Math.Max(0, Array.IndexOf(levels, options.Quality));
        Theme.Add(desktop, quality); Theme.Add(desktop, estimate); Theme.Add(mainPage, desktop);
        captureAudio.CheckedChanged += (_, _) => Change(() => { options.SystemAudio = captureAudio.Checked; audio.Enabled = options.SystemAudio; });
        audio.SelectedIndexChanged += (_, _) => { if (!loading) Change(() => options.AudioId = (audio.SelectedItem as AudioDevice)?.Id ?? options.AudioId); };
        outputSize.SelectedIndexChanged += (_, _) => Change(() => options.OutputProfile = profiles[outputSize.SelectedIndex]);
        quality.SelectedIndexChanged += (_, _) => Change(() => options.Quality = levels[quality.SelectedIndex]);

        Theme.Add(advancedCard, Theme.Label("一般不需要改动，默认值已按采访录制调好。", true));
        var changeFolder = Theme.Button("更改…");
        changeFolder.Click += (_, _) => { owner.ChangeOutputDirectory(this); UpdatePaths(); FitContent(); };
        Theme.Add(advancedCard, Theme.Row(0, Theme.Label("保存位置"), changeFolder));
        Theme.Add(advancedCard, advancedPath);
        stealth = Theme.Toggle("在录屏里隐身", owner.StealthInCapture);
        stealth.CheckedChanged += (_, _) => { owner.SetStealthInCapture(stealth.Checked); SyncStealth(); };
        Theme.Add(advancedCard, stealth);
        Theme.Add(advancedCard, Theme.Label("开启：录制画面、远程协助和会议共享都看不到小窗。关闭：远程协助可以看到并操作小窗，但小窗也会被录进桌面画面。", true));
        var detect = Theme.Button("检测");
        detect.Click += (_, _) => { if (owner.CanChangeStealth) { owner.DetectDevices(); ReloadDevices(); } };
        Theme.Add(advancedCard, Theme.Row(0, Theme.Label("重新检测设备"), detect));
        Theme.Add(advancedCard, Theme.Label("插拔设备后自动更新，检测不会替换失联的录制目标。", true));
        Theme.Add(advancedCard, Theme.Label("异常中断恢复"));
        var recover = Theme.Button("扫描并恢复未完成素材的副本");
        recover.Click += async (_, _) => await owner.RecoverAsync(this);
        Theme.Add(advancedCard, recover);
        Theme.Add(advancedCard, Theme.Label("恢复已写入片段为副本，保留原文件；不会自动继续录制。", true));
        Theme.Add(advancedPage, advancedCard); advancedPage.Visible = false;
        Theme.Add(content, mainPage); Theme.Add(content, advancedPage);
        advanced = Theme.Button("高级设置 ›"); advanced.ForeColor = Theme.Accent;
        advanced.FlatAppearance.BorderSize = 0; advanced.BackColor = Theme.Background;
        advanced.Padding = Padding.Empty; advanced.Click += (_, _) => ShowAdvanced(true);
        var footerText = Theme.Column(); Theme.Add(footerText, savePath); Theme.Add(footerText, advanced);
        done = Theme.Button("完成", true); done.Anchor = AnchorStyles.Bottom | AnchorStyles.Right;
        done.Click += (_, _) => { if (IsAdvanced) ShowAdvanced(false); else Close(); };
        Theme.Add(content, Theme.Row(0, footerText, done));
        scroll.Padding = new Padding(0, 0, SystemInformation.VerticalScrollBarWidth, 0);
        scroll.Controls.Add(content); Controls.Add(scroll);
        Resize += (_, _) => FitContent();
        DpiChanged += (_, _) => { if (IsHandleCreated) BeginInvoke((Action)FitContent); };
        content.DpiChangedAfterParent += (_, _) => FitContent();
        FontChanged += (_, _) => { if (IsHandleCreated) FitContent(); };
        Shown += (_, _) => { FitWindow(); FitContent(); };
        FormClosing += (_, e) => { if (recovering) e.Cancel = true; };
        FormClosed += (_, _) => tips.Dispose();
        UpdatePaths(); ReloadDevices(); SyncStealth();
        ResumeLayout(false);
    }
    int U(int logical) => (int)Math.Round(LogicalToDeviceUnits(logical) * layoutScale);
    void FitWindow()
    {
        var area = Screen.FromControl(this).WorkingArea;
        MinimumSize = new(Math.Min(U(440), area.Width), Math.Min(U(360), area.Height));
        ClientSize = new(Math.Min(U(680), area.Width - U(32)), Math.Min(U(780), area.Height - U(80)));
    }
    void Change(Action change)
    {
        if (!owner.CanChangeStealth) return;
        try { change(); options.Save(); owner.DetectDevices(); UpdateEstimate(); FitContent(); }
        catch (Exception ex) { MessageBox.Show(this, ex.Message, "录制设置未能保存", MessageBoxButtons.OK, MessageBoxIcon.Warning); }
    }
    void UpdatePaths()
    {
        advancedPath.Text = owner.OutputDirectory;
        savePath.Text = IsAdvanced ? $"版本 {Application.ProductVersion}" : $"保存到 {owner.OutputDirectory}";
    }
    internal void ShowAdvanced(bool value)
    {
        IsAdvanced = value; mainPage.Visible = !value; advancedPage.Visible = value;
        back.Visible = value; advanced.Visible = !value;
        heading.Text = value ? "高级设置" : "录制设置"; done.Text = value ? "返回" : "完成";
        scroll.AutoScrollPosition = Point.Empty; UpdatePaths(); FitContent();
    }
    internal void SyncStealth()
    {
        stealth.Checked = owner.StealthInCapture;
        stealth.Enabled = owner.CanChangeStealth;
        desktop.Enabled = advancedCard.Enabled = owner.CanChangeStealth;
    }
    internal void SetRecovering(bool value)
    {
        recovering = value; content.Enabled = !value;
        ControlBox = !value; SyncStealth();
    }
    void ReloadDevices()
    {
        loading = true;
        try
        {
            foreach (Control tile in displays.Controls.Cast<Control>().ToArray()) { tips.SetToolTip(tile, null); tile.Dispose(); }
            displays.Controls.Clear();
            var names = DisplayNames.FriendlyNames();
            var allScreens = Screen.AllScreens;
            for (int i = 0; i < allScreens.Length; i++)
            {
                var screen = allScreens[i];
                var tile = new DisplayTile(screen, DisplayNames.Caption(screen, i, names), options.ScreenId == screen.DeviceName);
                tile.Click += (_, _) =>
                {
                    Change(() => options.ScreenId = screen.DeviceName);
                    foreach (DisplayTile other in displays.Controls) { other.Selected = other.ScreenId == options.ScreenId; other.Invalidate(); }
                };
                tips.SetToolTip(tile, tile.Text); displays.Controls.Add(tile);
            }
            audio.Items.Clear();
            foreach (var device in CoreAudio.Devices()) audio.Items.Add(device.Id.Length == 0 ? new AudioDevice("", "默认播放设备（全部播放声音）") : device);
            audio.SelectedItem = audio.Items.Cast<AudioDevice>().FirstOrDefault(d => d.Id == options.AudioId);
            if (audio.SelectedIndex < 0 && options.AudioId.Length != 0)
            {
                var missing = new AudioDevice(options.AudioId, "原播放设备已断开，请重新选择"); audio.Items.Add(missing); audio.SelectedItem = missing;
            }
            UpdateEstimate(); FitContent();
        }
        catch (Exception ex) { estimate.Text = "设备检测未完成：" + ex.Message; }
        finally { loading = false; }
    }
    void UpdateEstimate()
    {
        var screen = Screen.AllScreens.FirstOrDefault(x => x.DeviceName == options.ScreenId);
        if (screen == null) { estimate.Text = "所选屏幕已断开，请重新选择"; return; }
        var target = RecordingOptions.OutputSize(options.OutputProfile, screen.Bounds.Width, screen.Bounds.Height);
        double megabits = RecordingOptions.BitRate(options.Quality, target.Width, target.Height) / 1_000_000.0;
        estimate.Text = $"输出 {target.Width} × {target.Height} · {RecordingOptions.FramesPerSecond} fps · {megabits:0.#} Mbps · 成品约 {(megabits + (options.SystemAudio ? .192 : 0)) * .45:0.0} GB/小时\nWindows 保留中间素材，实际磁盘占用高于成品。";
    }
    internal void FitContent()
    {
        if (fitting) return;
        fitting = true;
        try
        {
            back.Size = new(U(32), U(32));
            scroll.Padding = new Padding(0, 0, SystemInformation.VerticalScrollBarWidth, 0);
            // Reserve the scrollbar gutter even when the page fits, avoiding width/height oscillation.
            content.Width = Math.Max(1, scroll.ClientSize.Width - scroll.Padding.Horizontal);
            content.PerformLayout();
            int width = Math.Max(1, content.Width - content.Padding.Horizontal);
            mainPage.Width = advancedPage.Width = width;
            desktop.Width = advancedCard.Width = width;
            int inside = Math.Max(1, width - desktop.Padding.Horizontal);
            displays.MaximumSize = new(inside, 0);
            displays.Width = inside;
            foreach (DisplayTile tile in displays.Controls)
            {
                tile.Width = Math.Max(1, Math.Min(U(280), inside - tile.Margin.Horizontal));
                tile.Height = U(132) + tile.CaptionLineHeight * tile.CaptionLines.Length + U(20);
            }
            foreach (Control page in new Control[] { content, mainPage, advancedPage, desktop, advancedCard }) Theme.WrapLabels(page);
            content.PerformLayout();
            content.Height = content.GetPreferredSize(new Size(content.Width, 0)).Height;
        }
        finally { fitting = false; }
    }
    internal void ScaleForLayoutTest(float factor)
    {
        layoutScale = factor; Theme.ScaleLayoutFixture(this, factor);
        FitWindow(); FitContent();
    }
    protected override void WndProc(ref Message message)
    {
        base.WndProc(ref message);
        if ((message.Msg == 0x219 || message.Msg == 0x7E) && !recovering && IsHandleCreated)
            BeginInvoke((Action)(() => { if (!IsDisposed && owner.CanChangeStealth) { owner.DetectDevices(); ReloadDevices(); } }));
    }

    sealed class DisplayTile : Button
    {
        readonly Image? thumbnail;
        internal readonly string ScreenId;
        internal readonly string[] CaptionLines;
        internal int CaptionLineHeight => TextRenderer.MeasureText("显示器 2560×1440", Font).Height;
        internal bool Selected;
        internal DisplayTile(Screen screen, string caption, bool selected)
        {
            ScreenId = screen.DeviceName; Selected = selected; Text = caption;
            CaptionLines = caption.Split('\n', 2);
            AccessibleName = "选择录制屏幕 " + caption; AccessibleRole = AccessibleRole.RadioButton;
            FlatStyle = FlatStyle.Flat; BackColor = Theme.Panel; ForeColor = Theme.Ink;
            Margin = new Padding(0, 0, 12, 12); Cursor = Cursors.Hand;
            SetStyle(ControlStyles.UserPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
            try
            {
                using var bitmap = new Bitmap(screen.Bounds.Width, screen.Bounds.Height);
                using (var g = Graphics.FromImage(bitmap)) g.CopyFromScreen(screen.Bounds.Location, Point.Empty, screen.Bounds.Size);
                thumbnail = new Bitmap(bitmap, new Size(480, Math.Max(1, 480 * bitmap.Height / bitmap.Width)));
            }
            catch (Exception ex) when (ex is ArgumentException or System.Runtime.InteropServices.ExternalException)
            { AccessibleDescription = "预览不可用"; }
        }
        protected override void OnPaint(PaintEventArgs e)
        {
            e.Graphics.Clear(BackColor); e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
            int inset = LogicalToDeviceUnits(8);
            int lineHeight = CaptionLineHeight;
            int captionHeight = lineHeight * CaptionLines.Length + inset;
            var imageArea = new Rectangle(inset, inset, Math.Max(1, Width - inset * 2), Math.Max(1, Height - captionHeight - inset * 3));
            if (thumbnail != null)
            {
                double scale = Math.Min((double)imageArea.Width / thumbnail.Width, (double)imageArea.Height / thumbnail.Height);
                var size = new Size(Math.Max(1, (int)(thumbnail.Width * scale)), Math.Max(1, (int)(thumbnail.Height * scale)));
                e.Graphics.DrawImage(thumbnail, new Rectangle(imageArea.Left + (imageArea.Width - size.Width) / 2, imageArea.Top + (imageArea.Height - size.Height) / 2, size.Width, size.Height));
            }
            else TextRenderer.DrawText(e.Graphics, "预览不可用", Font, imageArea, Theme.Muted, TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter);
            for (int i = 0; i < CaptionLines.Length; i++)
            {
                var line = new Rectangle(inset, Height - captionHeight - inset + i * lineHeight, Math.Max(1, Width - inset * 2), lineHeight);
                TextRenderer.DrawText(e.Graphics, CaptionLines[i], Font, line, Enabled ? Theme.Ink : Theme.Muted,
                    TextFormatFlags.SingleLine | TextFormatFlags.EndEllipsis | TextFormatFlags.NoPrefix);
            }
            using var path = Theme.Rounded(Rectangle.Inflate(ClientRectangle, -2, -2), LogicalToDeviceUnits(10));
            using var pen = new Pen(Selected ? Theme.Accent : Theme.Border, LogicalToDeviceUnits(Selected ? 2 : 1)); e.Graphics.DrawPath(pen, path);
            if (Focused && ShowFocusCues) ControlPaint.DrawFocusRectangle(e.Graphics, Rectangle.Inflate(ClientRectangle, -inset, -inset));
        }
        protected override void Dispose(bool disposing) { if (disposing) thumbnail?.Dispose(); base.Dispose(disposing); }
    }
}
