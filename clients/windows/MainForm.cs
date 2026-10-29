using System.Diagnostics;
using System.Drawing.Drawing2D;
using System.Runtime.InteropServices;

namespace ZSirCapture;

internal sealed class MainForm : Form
{
    readonly RecordingOptions options = RecordingOptions.Load();
    readonly Button settingsButton = new() { Text = "录制设置", AutoSize = true };
    readonly ComboBox screens = new() { DropDownStyle = ComboBoxStyle.DropDownList, Dock = DockStyle.Fill };
    readonly ComboBox outputs = new() { DropDownStyle = ComboBoxStyle.DropDownList, Dock = DockStyle.Fill };
    readonly Button action = new() { Text = "开始录制", AutoSize = true, BackColor = Color.FromArgb(232, 93, 46), ForeColor = Color.White, FlatStyle = FlatStyle.Flat };
    readonly Button refresh = new() { Text = "刷新设备", AutoSize = true };
    readonly Button folder = new() { Text = "更改保存位置", AutoSize = true };
    readonly Button fold = new() { Text = "实时预览  ∧", AutoSize = true, FlatStyle = FlatStyle.Flat };
    readonly Label state = new() { Text = "准备就绪", AutoSize = true, Font = new("Microsoft YaHei UI", 12, FontStyle.Bold) };
    readonly Label detail = new() { Text = "桌面 + 系统声音 · 仅保存在本机", AutoSize = true };
    readonly Label clock = new() { Text = "00:00:00", AutoSize = true, Visible = false, Font = new("Consolas", 22, FontStyle.Bold), ForeColor = Color.FromArgb(255, 137, 106) };
    readonly RecordingEdge edge;
    internal RecordingEdge Edge => edge;
    public string Timecode => clock.Text;
    internal static string FormatTimecode(double elapsed) { long seconds = (long)Math.Max(0, elapsed); return $"{seconds / 3600:00}:{seconds / 60 % 60:00}:{seconds % 60:00}"; }
    readonly Label sound = new() { Text = "仅录系统声音，不采集话筒", AutoSize = true };
    readonly TableLayoutPanel layout = new() { AutoSize = true, AutoSizeMode = AutoSizeMode.GrowAndShrink, Dock = DockStyle.Top, Padding = new(16, 10, 16, 14), ColumnCount = 1, RowCount = 10 };
    static readonly Color Ink = Color.FromArgb(236, 238, 243);
    static readonly Color Muted = Color.FromArgb(157, 164, 179);
    readonly PictureBox preview = new() { Dock = DockStyle.Fill, BackColor = Color.FromArgb(30, 35, 43), SizeMode = PictureBoxSizeMode.Zoom, Height = 174 };
    readonly System.Windows.Forms.Timer timer = new() { Interval = 500 };
    readonly string tools;
    readonly string preference = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "ZSirCapture", "output-directory.txt");
    string root = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.MyVideos), "ZSir Recordings");
    string? lastFolder;
    Recorder? recorder;
    bool busy, recording, excluded, previewVisible = true;
    int pendingPreview;
    readonly SemaphoreSlim idlePreviewGate = new(1, 1);
    IdlePreview? idlePreview;
    int idlePreviewGeneration;
    DateTime nextIdlePreviewAttempt;
    public bool IsRecording => recording;
    public bool IsBusy => busy;
    public Recorder? CurrentRecorder => recorder;
    public string? LastFolder => lastFolder;
    public Exception? LastError { get; private set; }
    public bool Automation { get; set; }

    public MainForm(string toolsDirectory, bool automation = false)
    {
        edge = new RecordingEdge(this);
        tools = toolsDirectory;
        Automation = automation;
        Text = "庄Sir采访录制助手";
        Icon = Icon.ExtractAssociatedIcon(Application.ExecutablePath);
        Font = new("Microsoft YaHei UI", 9);
        BackColor = Color.FromArgb(29, 31, 38); ForeColor = Ink;
        DoubleBuffered = true;
        FormBorderStyle = FormBorderStyle.None; ControlBox = false; MinimizeBox = false; MaximizeBox = false; TopMost = true;
        StartPosition = FormStartPosition.Manual; AutoScaleMode = AutoScaleMode.Dpi;
        ClientSize = new(352, 380);
        detail.MaximumSize = sound.MaximumSize = new Size(320, 0);
        detail.ForeColor = sound.ForeColor = Muted;
        state.Font = new Font(Font.FontFamily, 12, FontStyle.Bold);
        preview.Paint += (_, e) => { if (preview.Image == null) TextRenderer.DrawText(e.Graphics, "正在加载桌面预览", Font, preview.ClientRectangle, Color.LightGray, TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter); };
        var area = Screen.PrimaryScreen!.WorkingArea; Location = new(area.Right - Width - 16, area.Top + 16);
        layout.BackColor = Color.Transparent;
        layout.ColumnStyles.Add(new(SizeType.Percent, 100));
        var title = new Panel { Height = 32, Dock = DockStyle.Top, BackColor = Color.Transparent, Margin = new Padding(0, 0, 0, 6) };
        var mark = new PictureBox { Image = Icon?.ToBitmap(), SizeMode = PictureBoxSizeMode.Zoom, Bounds = new Rectangle(0, 2, 24, 24) };
        var name = new Label { Text = Text, AutoSize = false, Bounds = new Rectangle(32, 3, 218, 24), ForeColor = Ink };
        var minimize = new Button { Text = "−", AccessibleName = "最小化", Bounds = new Rectangle(260, 0, 28, 28) };
        var close = new Button { Text = "×", AccessibleName = "关闭窗口", Bounds = new Rectangle(292, 0, 28, 28) };
        minimize.Click += (_, _) => WindowState = FormWindowState.Minimized;
        close.Click += (_, _) => Close();
        MouseEventHandler drag = (_, e) => { if (e.Button == MouseButtons.Left) { ReleaseCapture(); SendMessage(Handle, 0xA1, (IntPtr)2, IntPtr.Zero); } };
        title.MouseDown += drag; name.MouseDown += drag; mark.MouseDown += drag;
        title.Controls.AddRange([mark, name, minimize, close]);
        layout.Controls.Add(title); layout.Controls.Add(state); layout.Controls.Add(clock); layout.Controls.Add(detail);
        var devices = new TableLayoutPanel { AutoSize = true, Dock = DockStyle.Top, ColumnCount = 2, BackColor = Color.Transparent, Margin = new Padding(0, 10, 0, 6) };
        devices.ColumnStyles.Add(new(SizeType.Absolute, 64)); devices.ColumnStyles.Add(new(SizeType.Percent, 100));
        devices.Controls.Add(new Label { Text = "画面", AutoSize = true }, 0, 0); devices.Controls.Add(screens, 1, 0);
        devices.Controls.Add(new Label { Text = "系统声音", AutoSize = true }, 0, 1); devices.Controls.Add(outputs, 1, 1);
        settingsButton.Click += (_, _) => ShowRecordingSettings();
        layout.Controls.Add(settingsButton); layout.Controls.Add(sound);
        fold.Name = "previewToggle";
        fold.Click += (_, _) => TogglePreview();
        layout.Controls.Add(fold); layout.Controls.Add(preview);
        preview.Height = 160; preview.Dock = DockStyle.Top; preview.Margin = new Padding(0, 4, 0, 12);
        for (int i = 0; i < 10; i++) layout.RowStyles.Add(new(SizeType.AutoSize));
        var buttons = new FlowLayoutPanel { AutoSize = true, Dock = DockStyle.Top, WrapContents = false, BackColor = Color.Transparent, Margin = Padding.Empty };
        buttons.Controls.Add(action);
        var open = new Button { Text = "素材目录", AutoSize = true };
        open.Click += (_, _) => { try { string path = lastFolder ?? root; Directory.CreateDirectory(path); Process.Start(new ProcessStartInfo(path) { UseShellExecute = true }); } catch (Exception ex) { ShowError(ex); } };
        buttons.Controls.Add(open); buttons.Controls.Add(refresh); layout.Controls.Add(buttons);
        layout.Controls.Add(folder); Controls.Add(layout);
        StyleControls(layout);
        minimize.Padding = close.Padding = Padding.Empty;
        minimize.FlatAppearance.BorderSize = close.FlatAppearance.BorderSize = 0;
        minimize.BackColor = close.BackColor = BackColor;
        FormClosed += (_, _) => mark.Image?.Dispose();
        action.BackColor = Color.FromArgb(232, 93, 46); action.ForeColor = Color.White;
        action.FlatAppearance.BorderSize = 0; action.MinimumSize = new(124, 36);
        fold.FlatAppearance.BorderSize = folder.FlatAppearance.BorderSize = 0;
        fold.BackColor = folder.BackColor = BackColor;
        fold.ForeColor = folder.ForeColor = Muted;
        fold.Padding = folder.Padding = Padding.Empty;
        refresh.Click += (_, _) => RefreshDevices();
        folder.Click += (_, _) =>
        {
            using var dialog = new FolderBrowserDialog { InitialDirectory = root, Description = "选择素材目录" };
            if (dialog.ShowDialog(this) == DialogResult.OK)
            {
                try { Directory.CreateDirectory(Path.GetDirectoryName(preference)!); File.WriteAllText(preference, dialog.SelectedPath); root = dialog.SelectedPath; }
                catch (Exception ex) { ShowError(ex); }
            }
        };
        action.Click += async (_, _) => { if (recording) await StopRecordingAsync(); else if (!busy) await StartRecordingAsync(); };
        timer.Tick += async (_, _) =>
        {
            if (!recording && !busy && recorder != null && !recorder.CleanupPending)
            { recorder = null; SetControls(true); }
            if (!busy && recorder?.CleanupPending != true) await UpdateIdlePreviewAsync();
            if (!recording || recorder == null) return;
            recorder.PreviewEnabled = previewVisible && Visible && WindowState != FormWindowState.Minimized && !edge.IsDocked;
            clock.Text = FormatTimecode(recorder.Seconds);
            detail.Text = "正在写入本机 · 15 秒无操作后收起";
            sound.Text = !options.SystemAudio ? "系统声音已关闭" : recorder.Peak > .001 ? "●  收到系统声音" : "○  系统声音静音 · 时长正常保留";
            try { recorder.CheckHealth(); }
            catch (Exception ex) { await StopRecordingAsync(ex.Message); }
            edge.Tick();
        };
        Shown += (_, _) =>
        {
            FitContent(); ApplyGlass();
            var working = Screen.FromHandle(Handle).WorkingArea;
            Location = new(working.Right - Width - 16, working.Top + 16);
            excluded = SetWindowDisplayAffinity(Handle, 0x11);
            if (!excluded) { action.Enabled = false; state.Text = "无法排除录制小窗"; detail.Text = "请使用 Windows 10 2004 或更新版本"; }
        };
        VisibleChanged += async (_, _) => { if (recorder != null) recorder.PreviewEnabled = previewVisible && Visible && WindowState != FormWindowState.Minimized; await UpdateIdlePreviewAsync(); };
        Resize += async (_, _) => await UpdateIdlePreviewAsync();
        FormClosing += (_, e) =>
        {
            if (busy) { e.Cancel = true; if (!Automation) MessageBox.Show(this, "请先停止录制并等待保存完成，再关闭窗口。", "正在处理素材"); }
        };
        FormClosed += (_, _) => { timer.Dispose(); idlePreview?.Dispose(); idlePreview = null; edge.Dispose(); preview.Image?.Dispose(); };
        try { if (File.Exists(preference)) { string saved = File.ReadAllText(preference).Trim(); if (Path.IsPathFullyQualified(saved)) root = saved; } RefreshDevices(); }
        catch (Exception ex) { ShowError(ex); }
        timer.Start();
    }

    void ShowRecordingSettings()
    {
        if (busy) return;
        RefreshDevices();
        using var dialog = new Form { Text = "录制设置", Size = new(720, 660), StartPosition = FormStartPosition.CenterParent, BackColor = BackColor, ForeColor = Ink, Font = Font, AutoScroll = true, MinimizeBox = false, MaximizeBox = false };
        var content = new FlowLayoutPanel { Dock = DockStyle.Fill, AutoScroll = true, FlowDirection = FlowDirection.TopDown, WrapContents = false, Padding = new(24) };
        dialog.Controls.Add(content);
        var title = new Label { Text = "桌面画面 · 点击缩略图选择", AutoSize = true, Font = new(Font, FontStyle.Bold) }; content.Controls.Add(title);
        var cards = new FlowLayoutPanel { Width = 640, Height = 200, AutoScroll = true, WrapContents = false };
        content.Controls.Add(cards);
        var estimate = new Label { AutoSize = true, MaximumSize = new(620, 0) };
        void Estimate() {
            var screen = Screen.AllScreens.FirstOrDefault(x => x.DeviceName == options.ScreenId);
            if (screen == null) { estimate.Text = "所选屏幕已断开，请重新选择"; return; }
            var target = RecordingOptions.OutputSize(options.OutputProfile, screen.Bounds.Width, screen.Bounds.Height);
            double megabits = RecordingOptions.BitRate(options.Quality, target.Width, target.Height) / 1_000_000.0;
            estimate.Text = $"输出 {target.Width} × {target.Height} · {RecordingOptions.FramesPerSecond} fps · {megabits:0.#} Mbps · 成品约 {(megabits + (options.SystemAudio ? .192 : 0)) * .45:0.0} GB/小时\nWindows 保留中间素材，实际磁盘占用高于成品。";
        }
        void FillScreens() {
            foreach (Control c in cards.Controls.Cast<Control>().ToArray()) { if (c is Button b) b.Image?.Dispose(); c.Dispose(); }
            cards.Controls.Clear(); RefreshDevices();
            foreach (var screen in Screen.AllScreens) {
                var card = new Button { Width = 270, Height = 170, Text = screen.DeviceName + (options.ScreenId == screen.DeviceName ? " · 已选择" : ""), TextImageRelation = TextImageRelation.ImageAboveText, BackColor = options.ScreenId == screen.DeviceName ? Color.FromArgb(80, 48, 30) : BackColor, ForeColor = Ink, FlatStyle = FlatStyle.Flat, AccessibleName = "选择录制屏幕 " + screen.DeviceName };
                try {
                    using var bitmap = new Bitmap(screen.Bounds.Width, screen.Bounds.Height);
                    using (var g = Graphics.FromImage(bitmap)) g.CopyFromScreen(screen.Bounds.Location, Point.Empty, screen.Bounds.Size);
                    card.Image = new Bitmap(bitmap, new Size(240, Math.Max(1, 240 * bitmap.Height / bitmap.Width)));
                } catch (Exception ex) when (ex is System.ComponentModel.Win32Exception or ArgumentException) { card.Text += " · 预览不可用"; }
                card.Click += (_, _) => { options.ScreenId = screen.DeviceName; options.Save(); FillScreens(); Estimate(); };
                cards.Controls.Add(card);
            }
        }
        FillScreens();
        var captureAudio = new CheckBox { Text = "同时录下电脑里播放的声音", Checked = options.SystemAudio, AutoSize = true };
        content.Controls.Add(captureAudio);
        content.Controls.Add(new Label { Text = "默认播放设备（全部播放声音），也可指定输出设备", AutoSize = true });
        var audioChoice = new ComboBox { Width = 620, DropDownStyle = ComboBoxStyle.DropDownList, Enabled = options.SystemAudio };
        audioChoice.Items.AddRange(outputs.Items.Cast<object>().ToArray());
        audioChoice.SelectedItem = outputs.SelectedItem; content.Controls.Add(audioChoice);
        audioChoice.SelectedIndexChanged += (_, _) => { options.AudioId = (audioChoice.SelectedItem as AudioDevice)?.Id ?? ""; options.Save(); RefreshDevices(); };
        captureAudio.CheckedChanged += (_, _) => { options.SystemAudio = captureAudio.Checked; audioChoice.Enabled = options.SystemAudio; options.Save(); Estimate(); };
        content.Controls.Add(new Label { Text = "输出尺寸 · 固定 30 fps，保持比例，不放大", AutoSize = true, Padding = new(0, 14, 0, 0) });
        var outputSize = new ComboBox { Width = 620, DropDownStyle = ComboBoxStyle.DropDownList, AccessibleName = "输出尺寸" };
        outputSize.Items.AddRange(["均衡 · 最长边 1920 像素", "1440p · 最长边 2560 像素", "原始尺寸"]);
        string[] profiles = ["balanced", "detailed", "native"];
        int profileIndex = Array.IndexOf(profiles, options.OutputProfile);
        outputSize.SelectedIndex = profileIndex >= 0 ? profileIndex : 2;
        outputSize.SelectedIndexChanged += (_, _) => { options.OutputProfile = profiles[outputSize.SelectedIndex]; options.Save(); Estimate(); };
        content.Controls.Add(outputSize);
        content.Controls.Add(new Label { Text = "画质", AutoSize = true, Padding = new(0, 14, 0, 0) });
        var quality = new ComboBox { Width = 620, DropDownStyle = ComboBoxStyle.DropDownList, AccessibleName = "画质" };
        quality.Items.AddRange(["省空间", "标准 · 推荐", "高画质"]);
        string[] levels = ["compact", "standard", "high"]; quality.SelectedIndex = Math.Max(0, Array.IndexOf(levels, options.Quality));
        quality.SelectedIndexChanged += (_, _) => { options.Quality = levels[quality.SelectedIndex]; options.Save(); Estimate(); };
        content.Controls.Add(quality); content.Controls.Add(estimate); Estimate();
        var refreshDevices = new Button { Text = "重新检测设备", AutoSize = true };
        refreshDevices.Click += (_, _) => { FillScreens(); Estimate(); }; content.Controls.Add(refreshDevices);
        var recover = new Button { Text = "扫描并恢复未完成素材的副本", AutoSize = true };
        bool recovering = false;
        dialog.FormClosing += (_, e) => { if (recovering) e.Cancel = true; };
        recover.Click += async (_, _) => {
            if (busy) return;
            busy = recovering = true;
            SetControls(false); content.Enabled = false;
            var recoveryRecorder = new Recorder(tools);
            try {
                await StopIdlePreviewAsync();
                var recovered = await recoveryRecorder.RecoverUnfinishedAsync(root);
                MessageBox.Show(dialog, recovered.Length == 0 ? "未找到可恢复的未完成素材。正在录制的目录会跳过。" : $"已生成 {recovered.Length} 份恢复副本。请在素材目录的 Recovery 文件夹检查音画。原素材保留。", "素材恢复");
            } catch (Exception ex) { MessageBox.Show(dialog, ex.Message, "恢复未完成，原素材保留"); }
            finally {
                busy = recovering = false; content.Enabled = true;
                if (recoveryRecorder.CleanupPending) {
                    recorder = recoveryRecorder; state.Text = "素材需要检查";
                    detail.Text = "恢复进程尚未退出，暂不可再次录制或恢复。可退出后重新打开。";
                    content.Enabled = false;
                }
                SetControls(true);
            }
        };
        content.Controls.Add(recover);
        var done = new Button { Text = "完成", AutoSize = true, BackColor = Color.FromArgb(255, 102, 38) }; done.Click += (_, _) => dialog.Close(); content.Controls.Add(done);
        dialog.FormClosed += (_, _) => { foreach (Button card in cards.Controls) card.Image?.Dispose(); };
        dialog.ShowDialog(this);
        _ = UpdateIdlePreviewAsync();
    }

    async Task StopIdlePreviewAsync()
    {
        await idlePreviewGate.WaitAsync();
        try { await StopIdlePreviewCoreAsync(); }
        finally { idlePreviewGate.Release(); }
    }
    async Task StopIdlePreviewCoreAsync()
    {
        var current = idlePreview;
        if (current == null) return;
        idlePreviewGeneration++;
        idlePreview = null;
        try { await current.StopAsync(); }
        finally { current.Dispose(); }
    }
    async Task UpdateIdlePreviewAsync()
    {
        // Timer and visibility changes may overlap while the process is exiting.
        if (!await idlePreviewGate.WaitAsync(0)) return;
        try
        {
            var screen = Screen.AllScreens.FirstOrDefault(x => x.DeviceName == options.ScreenId);
            bool wanted = !IsDisposed && !Disposing && !busy && recorder?.CleanupPending != true && Visible && previewVisible && WindowState != FormWindowState.Minimized && !edge.IsDocked && screen != null;
            if (idlePreview != null && (!wanted || idlePreview.Bounds != screen!.Bounds || idlePreview.HasExited))
                await StopIdlePreviewCoreAsync();
            if (!wanted || IsDisposed || Disposing || busy || !Visible || !previewVisible || WindowState == FormWindowState.Minimized || idlePreview != null || DateTime.UtcNow < nextIdlePreviewAttempt) return;
            nextIdlePreviewAttempt = DateTime.UtcNow.AddSeconds(5);
            int generation = ++idlePreviewGeneration;
            idlePreview = new IdlePreview(tools, screen!.Bounds, bytes =>
            {
                if (IsDisposed || busy || Interlocked.Exchange(ref pendingPreview, 1) != 0) return;
                try
                {
                    BeginInvoke((Action)(() =>
                    {
                        try
                        {
                            if (IsDisposed || busy || generation != idlePreviewGeneration || !Visible || !previewVisible || WindowState == FormWindowState.Minimized) return;
                            using var input = new MemoryStream(bytes); using var image = Image.FromStream(input);
                            var old = preview.Image; preview.Image = new Bitmap(image); old?.Dispose();
                            fold.Text = "实时预览  ∧";
                        }
                        catch (ArgumentException) { }
                        finally { Interlocked.Exchange(ref pendingPreview, 0); }
                    }));
                }
                catch (InvalidOperationException) { Interlocked.Exchange(ref pendingPreview, 0); }
            });
        }
        catch (Exception ex) when (ex is IOException or System.ComponentModel.Win32Exception or InvalidOperationException or TimeoutException)
        { /* Preview availability must never block recording; retry is bounded. */ }
        finally { idlePreviewGate.Release(); }
    }

    void TogglePreview()
    {
        previewVisible = !previewVisible;
        preview.Visible = previewVisible;
        fold.Text = previewVisible ? "实时预览  ∧" : "展开预览  ∨";
        if (recorder != null) recorder.PreviewEnabled = previewVisible;
        _ = UpdateIdlePreviewAsync();
        FitContent();
    }
    void FitContent()
    {
        if (layout.Parent == null) return;
        layout.PerformLayout();
        ClientSize = new(ClientSize.Width, layout.GetPreferredSize(new Size(ClientSize.Width, 0)).Height);
    }
    void StyleControls(Control parent)
    {
        foreach (Control control in parent.Controls)
        {
            if (control is Button button)
            {
                button.FlatStyle = FlatStyle.Flat; button.UseVisualStyleBackColor = false;
                button.BackColor = Color.FromArgb(43, 46, 55); button.ForeColor = Ink;
                button.FlatAppearance.BorderColor = Color.FromArgb(65, 69, 81);
                button.FlatAppearance.MouseOverBackColor = Color.FromArgb(66, 67, 76);
                button.Padding = new Padding(4, 3, 4, 3); button.Margin = new Padding(0, 2, 6, 2);
                button.Cursor = Cursors.Hand;
            }
            else if (control is ComboBox combo)
            {
                combo.FlatStyle = FlatStyle.Flat; combo.BackColor = Color.FromArgb(43, 46, 55); combo.ForeColor = Ink;
                combo.DropDownWidth = 400;
                combo.DrawMode = DrawMode.OwnerDrawFixed; combo.ItemHeight = 24;
                combo.DrawItem += (_, e) =>
                {
                    bool selected = (e.State & DrawItemState.Selected) != 0;
                    using var fill = new SolidBrush(selected ? Color.FromArgb(63, 66, 79) : combo.BackColor);
                    e.Graphics.FillRectangle(fill, e.Bounds);
                    string text = (e.Index >= 0 ? combo.GetItemText(combo.Items[e.Index]) : combo.Text) ?? "";
                    var textBounds = Rectangle.Inflate(e.Bounds, -6, 0);
                    TextRenderer.DrawText(e.Graphics, text, combo.Font, textBounds, combo.Enabled ? Ink : Muted,
                        TextFormatFlags.Left | TextFormatFlags.VerticalCenter | TextFormatFlags.EndEllipsis);
                    e.DrawFocusRectangle();
                };
            }
            else if (control is Label label) { label.BackColor = Color.Transparent; label.Margin = new Padding(0, 3, 0, 3); }
            StyleControls(control);
        }
    }
    void ApplyGlass()
    {
        if (!OperatingSystem.IsWindowsVersionAtLeast(10, 0, 22000)) return;
        int dark = 1, corner = 2, acrylic = 3;
        DwmSetWindowAttribute(Handle, 20, ref dark, sizeof(int));
        DwmSetWindowAttribute(Handle, 33, ref corner, sizeof(int));
        if (OperatingSystem.IsWindowsVersionAtLeast(10, 0, 22621))
            DwmSetWindowAttribute(Handle, 38, ref acrylic, sizeof(int));
    }
    protected override void OnPaintBackground(PaintEventArgs e)
    {
        using var tint = new LinearGradientBrush(ClientRectangle, Color.FromArgb(43, 45, 55), BackColor, 80f);
        e.Graphics.FillRectangle(tint, ClientRectangle);
    }
    [DllImport("user32.dll")] static extern bool ReleaseCapture();
    [DllImport("user32.dll")] static extern IntPtr SendMessage(IntPtr hwnd, int message, IntPtr wParam, IntPtr lParam);
    [DllImport("dwmapi.dll")] static extern int DwmSetWindowAttribute(IntPtr hwnd, int attribute, ref int value, int size);

    void RefreshDevices()
    {
        try
        {
            string screenId = options.ScreenId;
            if (screenId.Length == 0) screenId = Screen.PrimaryScreen?.DeviceName ?? "";
            string deviceId = options.AudioId;
            screens.Items.Clear();
            foreach (var screen in Screen.AllScreens) screens.Items.Add(new ScreenOption(screen.DeviceName, $"{screen.DeviceName} · {screen.Bounds.Width}×{screen.Bounds.Height}"));
            if (!screens.Items.Cast<ScreenOption>().Any(x => x.Id == screenId)) screens.Items.Add(new ScreenOption(screenId, "原目标已断开，请在设置中重选"));
            screens.SelectedItem = screens.Items.Cast<ScreenOption>().First(x => x.Id == screenId);
            options.ScreenId = screenId;
            outputs.Items.Clear(); outputs.Items.AddRange(CoreAudio.Devices().Cast<object>().ToArray());
            outputs.SelectedItem = outputs.Items.Cast<AudioDevice>().FirstOrDefault(x => x.Id == deviceId) ?? (deviceId.Length == 0 && outputs.Items.Count > 0 ? outputs.Items[0] : null);
        }
        catch (Exception ex) { ShowError(ex); }
    }
    public void SetTestOutput(string directory) { if (busy) throw new InvalidOperationException(); root = directory; }
    public async Task StartRecordingAsync()
    {
        if (busy || recorder?.CleanupPending == true) return;
        LastError = null; clock.Text = "00:00:00"; clock.Visible = false; busy = true; SetControls(false); state.Text = "正在准备…";
        try
        {
            await StopIdlePreviewAsync();
            if (!excluded) throw new InvalidOperationException("小窗排除设置未成功，取消录制");
            RefreshDevices();
            string id = options.ScreenId;
            Screen screen = id.Length == 0 ? Screen.PrimaryScreen! : Screen.AllScreens.FirstOrDefault(x => x.DeviceName == id) ?? throw new InvalidOperationException("所选显示器已断开");
            var audioDevice = outputs.SelectedItem as AudioDevice;
            if (options.SystemAudio && audioDevice == null) throw new InvalidOperationException("请选择系统声音输出设备");
            SetThreadExecutionState(0x80000001);
            var current = new Recorder(tools) { PreviewEnabled = previewVisible };
            recorder = current;
            current.Preview = bytes =>
            {
                if (IsDisposed || Interlocked.Exchange(ref pendingPreview, 1) != 0) return;
                try
                {
                    BeginInvoke((Action)(() =>
                    {
                        try
                        {
                            if (recorder != current || !previewVisible || edge.IsDocked) return;
                            using var input = new MemoryStream(bytes); using var image = Image.FromStream(input);
                            var old = preview.Image; preview.Image = new Bitmap(image); old?.Dispose();
                        }
                        catch (ArgumentException) { }
                        finally { Interlocked.Exchange(ref pendingPreview, 0); }
                    }));
                }
                catch (InvalidOperationException) { Interlocked.Exchange(ref pendingPreview, 0); }
            };
            var previous = preview.Image; preview.Image = null; previous?.Dispose();
            await current.StartAsync(root, screen.Bounds, audioDevice?.Id ?? "", options.Quality, options.SystemAudio, options.OutputProfile);
            lastFolder = current.Folder; recording = true; clock.Visible = true; edge.ResetIdle();
            state.Text = "● 正在录制"; state.ForeColor = Color.FromArgb(255, 137, 106);
            action.Text = "■  停止并保存"; action.Enabled = true; fold.Text = previewVisible ? "实时预览  ∧" : "展开实时预览  ∨"; FitContent();
        }
        catch (Exception ex)
        {
            lastFolder = recorder?.Folder; if (recorder?.CleanupPending != true) recorder = null; busy = false;
            SetThreadExecutionState(0x80000000); SetControls(true); state.Text = recorder?.CleanupPending == true ? "素材需要检查" : "未能开始"; ShowError(ex);
            if (recorder?.CleanupPending == true) { detail.Text = "后台资源尚未释放，暂不可再次录制。可退出后重新打开恢复原素材。"; FitContent(); }
        }
    }
    public async Task StopRecordingAsync(string? reason = null)
    {
        if (!recording || recorder == null) return;
        recording = false; edge.Reveal(false); action.Enabled = false; state.Text = "正在保存…"; detail.Text = "正在合成音画，请勿退出或拔盘";
        var current = recorder;
        try
        {
            await current.StopAsync(reason);
            state.Text = current.Failure == null ? "录制已保存" : "素材需要检查";
            detail.Text = current.Failure ?? "desktop.mp4 · 请检查音画后交付";
            if (current.Failure != null) LastError = new InvalidOperationException(current.Failure);
        }
        catch (Exception ex) { state.Text = "素材需要检查"; ShowError(ex); }
        finally
        {
            busy = false; if (!current.CleanupPending) recorder = null; SetThreadExecutionState(0x80000000); SetControls(true);
            action.Text = "开始录制"; state.ForeColor = Ink; sound.Text = "原始素材已保留，可在目录中查看";
            if (current.CleanupPending) detail.Text = "素材需要检查；后台资源尚未释放，暂不可再次录制。可退出后重新打开恢复原素材。";
            fold.Text = previewVisible ? "上次录制画面  ∧" : "展开上次画面  ∨"; FitContent();
        }
    }
    void SetControls(bool enabled) { enabled &= recorder?.CleanupPending != true; settingsButton.Enabled = screens.Enabled = outputs.Enabled = folder.Enabled = refresh.Enabled = enabled; action.Enabled = enabled && excluded; }
    void ShowError(Exception ex) { edge.Reveal(false); LastError = ex; detail.Text = ex.Message; FitContent(); if (!Automation) MessageBox.Show(this, ex.Message, "录制提示", MessageBoxButtons.OK, MessageBoxIcon.Warning); }
    protected override void WndProc(ref Message message)
    {
        if ((message.Msg == 0x218 && message.WParam.ToInt32() == 4 || message.Msg == 0x7E) && recording)
            BeginInvoke((Action)(async () => await StopRecordingAsync("系统睡眠或显示器配置改变，请检查已保留素材")));
        if ((message.Msg == 0x219 || message.Msg == 0x7E) && !busy) BeginInvoke((Action)RefreshDevices);
        base.WndProc(ref message);
    }
    [DllImport("user32.dll", SetLastError = true)] static extern bool SetWindowDisplayAffinity(IntPtr window, uint affinity);
    [DllImport("kernel32.dll")] static extern uint SetThreadExecutionState(uint flags);
    record ScreenOption(string Id, string Name) { public override string ToString() => Name; }
}
