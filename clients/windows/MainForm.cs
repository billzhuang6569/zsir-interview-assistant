using System.Diagnostics;
using System.Drawing.Drawing2D;
using System.Runtime.InteropServices;

namespace ZSirCapture;

internal sealed class MainForm : Form
{
    readonly ComboBox screens = new() { DropDownStyle = ComboBoxStyle.DropDownList, Dock = DockStyle.Fill };
    readonly ComboBox outputs = new() { DropDownStyle = ComboBoxStyle.DropDownList, Dock = DockStyle.Fill };
    readonly Button action = new() { Text = "开始录制", AutoSize = true, BackColor = Color.FromArgb(232, 93, 46), ForeColor = Color.White, FlatStyle = FlatStyle.Flat };
    readonly Button refresh = new() { Text = "刷新设备", AutoSize = true };
    readonly Button folder = new() { Text = "更改保存位置", AutoSize = true };
    readonly Button fold = new() { Text = "收起预览  ∧", AutoSize = true, FlatStyle = FlatStyle.Flat };
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
        FormBorderStyle = FormBorderStyle.None; MaximizeBox = false; TopMost = true;
        StartPosition = FormStartPosition.Manual; AutoScaleMode = AutoScaleMode.Dpi;
        ClientSize = new(352, 380);
        detail.MaximumSize = sound.MaximumSize = new Size(320, 0);
        detail.ForeColor = sound.ForeColor = Muted;
        state.Font = new Font(Font.FontFamily, 12, FontStyle.Bold);
        preview.Paint += (_, e) => { if (preview.Image == null) TextRenderer.DrawText(e.Graphics, "开始后显示桌面画面", Font, preview.ClientRectangle, Color.LightGray, TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter); };
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
        title.MouseDown += drag; name.MouseDown += drag;
        title.Controls.AddRange([mark, name, minimize, close]);
        layout.Controls.Add(title); layout.Controls.Add(state); layout.Controls.Add(clock); layout.Controls.Add(detail);
        var devices = new TableLayoutPanel { AutoSize = true, Dock = DockStyle.Top, ColumnCount = 2, BackColor = Color.Transparent, Margin = new Padding(0, 10, 0, 6) };
        devices.ColumnStyles.Add(new(SizeType.Absolute, 64)); devices.ColumnStyles.Add(new(SizeType.Percent, 100));
        devices.Controls.Add(new Label { Text = "画面", AutoSize = true }, 0, 0); devices.Controls.Add(screens, 1, 0);
        devices.Controls.Add(new Label { Text = "系统声音", AutoSize = true }, 0, 1); devices.Controls.Add(outputs, 1, 1);
        layout.Controls.Add(devices); layout.Controls.Add(sound);
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
            if (!recording || recorder == null) return;
            clock.Text = FormatTimecode(recorder.Seconds);
            detail.Text = "正在写入本机 · 15 秒无操作后收起";
            sound.Text = recorder.Peak > .001 ? "●  收到系统声音" : "○  系统声音静音 · 时长正常保留";
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
        FormClosing += (_, e) =>
        {
            if (busy) { e.Cancel = true; if (!Automation) MessageBox.Show(this, "请先停止录制并等待保存完成，再关闭窗口。", "正在处理素材"); }
        };
        FormClosed += (_, _) => { timer.Dispose(); edge.Dispose(); preview.Image?.Dispose(); };
        try { if (File.Exists(preference)) { string saved = File.ReadAllText(preference).Trim(); if (Path.IsPathFullyQualified(saved)) root = saved; } RefreshDevices(); }
        catch (Exception ex) { ShowError(ex); }
        timer.Start();
    }

    void TogglePreview()
    {
        previewVisible = !previewVisible;
        preview.Visible = previewVisible;
        fold.Text = previewVisible ? (recording ? "实时预览  ∧" : preview.Image != null ? "上次录制画面  ∧" : "收起预览  ∧") : "展开预览  ∨";
        if (recorder != null) recorder.PreviewEnabled = previewVisible;
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
            string? screenId = (screens.SelectedItem as ScreenOption)?.Id;
            string? deviceId = (outputs.SelectedItem as AudioDevice)?.Id;
            screens.Items.Clear(); screens.Items.Add(new ScreenOption("", "系统主显示器"));
            foreach (var screen in Screen.AllScreens) screens.Items.Add(new ScreenOption(screen.DeviceName, $"{screen.DeviceName} · {screen.Bounds.Width}×{screen.Bounds.Height}"));
            screens.SelectedItem = screens.Items.Cast<ScreenOption>().FirstOrDefault(x => x.Id == screenId) ?? screens.Items[0];
            outputs.Items.Clear(); outputs.Items.AddRange(CoreAudio.Devices().Cast<object>().ToArray());
            outputs.SelectedItem = outputs.Items.Cast<AudioDevice>().FirstOrDefault(x => x.Id == deviceId) ?? outputs.Items[0];
        }
        catch (Exception ex) { ShowError(ex); }
    }
    public void SetTestOutput(string directory) { if (busy) throw new InvalidOperationException(); root = directory; }
    public async Task StartRecordingAsync()
    {
        if (busy) return;
        LastError = null; clock.Text = "00:00:00"; clock.Visible = false; busy = true; SetControls(false); state.Text = "正在准备…";
        try
        {
            if (!excluded) throw new InvalidOperationException("小窗排除设置未成功，取消录制");
            string id = (screens.SelectedItem as ScreenOption)?.Id ?? "";
            Screen screen = id.Length == 0 ? Screen.PrimaryScreen! : Screen.AllScreens.FirstOrDefault(x => x.DeviceName == id) ?? throw new InvalidOperationException("所选显示器已断开");
            var audioDevice = outputs.SelectedItem as AudioDevice ?? throw new InvalidOperationException("请选择系统声音输出设备");
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
            await current.StartAsync(root, screen.Bounds, audioDevice.Id);
            lastFolder = current.Folder; recording = true; clock.Visible = true; edge.ResetIdle();
            state.Text = "● 正在录制"; state.ForeColor = Color.FromArgb(255, 137, 106);
            action.Text = "■  停止并保存"; action.Enabled = true; fold.Text = previewVisible ? "实时预览  ∧" : "展开实时预览  ∨"; FitContent();
        }
        catch (Exception ex)
        {
            lastFolder = recorder?.Folder; recorder = null; busy = false;
            SetThreadExecutionState(0x80000000); SetControls(true); state.Text = "未能开始"; ShowError(ex);
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
            busy = false; recorder = null; SetThreadExecutionState(0x80000000); SetControls(true);
            action.Text = "开始录制"; state.ForeColor = Ink; sound.Text = "原始素材已保留，可在目录中查看";
            fold.Text = previewVisible ? "上次录制画面  ∧" : "展开上次画面  ∨"; FitContent();
        }
    }
    void SetControls(bool enabled) { screens.Enabled = outputs.Enabled = folder.Enabled = refresh.Enabled = enabled; action.Enabled = enabled && excluded; }
    void ShowError(Exception ex) { edge.Reveal(false); LastError = ex; detail.Text = ex.Message; FitContent(); if (!Automation) MessageBox.Show(this, ex.Message, "录制提示", MessageBoxButtons.OK, MessageBoxIcon.Warning); }
    protected override void WndProc(ref Message message)
    {
        if ((message.Msg == 0x218 && message.WParam.ToInt32() == 4 || message.Msg == 0x7E) && recording)
            BeginInvoke((Action)(async () => await StopRecordingAsync("系统睡眠或显示器配置改变，请检查已保留素材")));
        base.WndProc(ref message);
    }
    [DllImport("user32.dll", SetLastError = true)] static extern bool SetWindowDisplayAffinity(IntPtr window, uint affinity);
    [DllImport("kernel32.dll")] static extern uint SetThreadExecutionState(uint flags);
    record ScreenOption(string Id, string Name) { public override string ToString() => Name; }
}
