using System.Diagnostics;
using System.Drawing.Drawing2D;
using System.Runtime.InteropServices;

namespace ZSirCapture;

internal sealed class MainForm : Form
{
    readonly RecordingOptions options = RecordingOptions.Load();
    readonly ToolTip tips = new();
    readonly Button settingsButton;
    readonly Button action = Theme.Button("开始录制", true);
    readonly Theme.DisclosureButton fold = new();
    readonly Label state = Theme.Label("准备就绪");
    readonly Label dot = Theme.Label("●");
    readonly Label detail = Theme.Label("桌面 + 系统声音 · 仅保存在本机", true);
    readonly Label clock = Theme.Label("00:00:00");
    readonly Label clockHint = Theme.Label("本次录制时长", true);
    readonly Label previewState = Theme.Label("等待预览", true);
    readonly TableLayoutPanel timeRow;
    readonly TrayMenu tray;
    SettingsForm? settingsDialog;
    readonly RecordingEdge edge;
    internal RecordingEdge Edge => edge;
    public string Timecode => clock.Text;
    internal static string FormatTimecode(double elapsed) { long seconds = (long)Math.Max(0, elapsed); return $"{seconds / 3600:00}:{seconds / 60 % 60:00}:{seconds % 60:00}"; }
    readonly TableLayoutPanel layout = Theme.Column();
    readonly Theme.PreviewTile preview = new() { Dock = DockStyle.Top };
    readonly Theme.PreviewTile cameraPreview = new() { Dock = DockStyle.Fill, Caption = "摄像头 · 话筒" };
    readonly TableLayoutPanel previewRow = new() { Dock = DockStyle.Top, ColumnCount = 2, RowCount = 1, Margin = Padding.Empty };
    readonly List<Theme.SegmentButton> modeButtons = [];
    IdlePreview? idleCamera;
    string idleCameraId = "";
    int pendingCameraPreview;
    internal string Tools => tools;
    internal bool LayoutOnly => layoutOnly;
    internal RecordingOptions Options => options;
    internal Task ReleaseIdleForSettingsAsync() => StopIdlePreviewAsync();
    AudioDevice? selectedAudio;
    bool fitting, hasTimecode;
    float layoutScale = 1;
    readonly bool layoutOnly;
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
    DateTime nextIdlePreviewAttempt, nextDesktopPreviewAttempt;
    public bool IsRecording => recording;
    public bool IsBusy => busy;
    internal bool StealthInCapture => options.StealthInCapture;
    internal bool CanChangeStealth => !busy && !recording && recorder?.CleanupPending != true;
    internal bool CanStartRecording => CanChangeStealth && Enabled && (!StealthInCapture || excluded);
    public Recorder? CurrentRecorder => recorder;
    public string? LastFolder => lastFolder;
    public Exception? LastError { get; private set; }
    public bool Automation { get; set; }

    public MainForm(string toolsDirectory, bool automation = false, bool layoutOnly = false)
    {
        SuspendLayout();
        edge = new RecordingEdge(this);
        tools = toolsDirectory;
        Automation = automation;
        this.layoutOnly = layoutOnly;
        Text = "庄Sir采访录制助手";
        Icon = Icon.ExtractAssociatedIcon(Application.ExecutablePath);
        tray = new TrayMenu(this);
        Theme.Window(this);
        DoubleBuffered = true;
        FormBorderStyle = FormBorderStyle.None; ControlBox = false; MinimizeBox = false; MaximizeBox = false; TopMost = true;
        StartPosition = FormStartPosition.Manual;
        ClientSize = new(336, 420);
        layout.Padding = new Padding(16);
        var mark = new PictureBox { Image = Icon?.ToBitmap(), SizeMode = PictureBoxSizeMode.Zoom, Margin = new Padding(0, 2, 8, 2) };
        var name = new Label { Text = Text, AutoEllipsis = true, Dock = DockStyle.Fill, TextAlign = ContentAlignment.MiddleLeft, Font = Theme.Font(10, FontStyle.Bold), Margin = Padding.Empty };
        var close = Theme.IconButton("\uE8BB", "关闭窗口", tips);
        close.Font = Theme.IconFont(10); close.ForeColor = Theme.Muted;
        close.FlatAppearance.BorderSize = 0; close.BackColor = Color.Transparent;
        close.FlatAppearance.MouseOverBackColor = close.FlatAppearance.MouseDownBackColor = Theme.Panel;
        close.Click += (_, _) => Close();
        var title = Theme.Row(1, mark, name, close);
        title.Margin = new Padding(0, 0, 0, 8);
        MouseEventHandler drag = (_, e) => { if (e.Button == MouseButtons.Left) { ReleaseCapture(); SendMessage(Handle, 0xA1, (IntPtr)2, IntPtr.Zero); } };
        title.MouseDown += drag; name.MouseDown += drag; mark.MouseDown += drag;
        var local = Theme.Label("本地保存", true); local.Font = Theme.Font(8); local.Anchor = AnchorStyles.Right;
        state.Font = Theme.Font(11, FontStyle.Bold); dot.ForeColor = Theme.Mint;
        dot.Margin = new Padding(0, 4, 6, 4);
        var status = Theme.Row(1, dot, state, local); state.Dock = DockStyle.Fill;
        clock.Font = new Font("Consolas", 22, FontStyle.Bold); clock.ForeColor = Theme.Accent;
        clockHint.Font = Theme.Font(8); clockHint.Anchor = AnchorStyles.Right;
        timeRow = Theme.Row(1, clock, clockHint); timeRow.Visible = false;
        var modes = new TableLayoutPanel { AutoSize = true, Dock = DockStyle.Top, ColumnCount = 3, RowCount = 1,
            BackColor = Theme.Panel, Margin = new Padding(0, 10, 0, 8) };
        string[] modeIds = ["camera", "desktop", "both"];
        string[] modeNames = ["摄像头", "桌面", "摄像头+桌面"];
        for (int i = 0; i < modeNames.Length; i++)
        {
            modes.ColumnStyles.Add(new(SizeType.Percent, 100f / 3));
            var mode = new Theme.SegmentButton(modeNames[i], options.Mode == modeIds[i]) { Dock = DockStyle.Fill };
            mode.Padding = new Padding(0, 6, 0, 6); mode.Margin = Padding.Empty;
            mode.AccessibleName = modeNames[i];
            string selectedMode = modeIds[i];
            mode.Click += (_, _) => SetMode(selectedMode);
            modeButtons.Add(mode);
            modes.Controls.Add(mode, i, 0);
        }
        fold.Name = "previewToggle";
        fold.Click += (_, _) => TogglePreview();
        previewState.Font = Theme.Font(8); previewState.Anchor = AnchorStyles.Right;
        var disclosure = Theme.Row(0, fold, previewState); fold.Anchor = AnchorStyles.Left;
        previewRow.ColumnStyles.Add(new(SizeType.Percent, 50)); previewRow.ColumnStyles.Add(new(SizeType.Percent, 50));
        previewRow.Controls.Add(cameraPreview, 0, 0); previewRow.Controls.Add(preview, 1, 0);
        preview.Dock = DockStyle.Fill;
        preview.Margin = new Padding(0, 4, 0, 12);
        settingsButton = Theme.IconButton("\uE713", "录制设置", tips);
        settingsButton.Click += (_, _) => ShowRecordingSettings();
        var open = Theme.IconButton("\uE8B7", "打开素材目录", tips);
        open.Click += (_, _) => OpenMaterialFolder();
        action.Dock = DockStyle.Fill; action.AccessibleName = "开始录制";
        action.TextImageRelation = TextImageRelation.ImageBeforeText;
        tips.SetToolTip(action, "开始录制 / 停止并保存");
        open.Margin = settingsButton.Margin = new Padding(6, 4, 0, 4);
        var buttons = Theme.Row(0, action, open, settingsButton);
        Theme.Add(layout, title); Theme.Add(layout, status); Theme.Add(layout, detail); Theme.Add(layout, timeRow);
        Theme.Add(layout, modes); Theme.Add(layout, disclosure); Theme.Add(layout, previewRow); Theme.Add(layout, buttons);
        Controls.Add(layout);
        void CustomSizes()
        {
            mark.Size = new(U(26), U(26)); close.Size = new(U(28), U(28));
            open.Size = settingsButton.Size = new(U(38), U(38)); previewRow.Height = U(148); cameraPreview.Height = preview.Height = U(148);
            detail.MaximumSize = new(Math.Max(1, U(304)), detail.Font.Height * 2 + U(2)); detail.AutoEllipsis = true;
            clockHint.MaximumSize = new(U(134), 0);
            action.MinimumSize = new(0, U(38));
            UpdateActionIcon();
        }
        void Refit() { CustomSizes(); FitContent(); }
        DpiChanged += (_, _) => { if (IsHandleCreated) BeginInvoke((Action)Refit); };
        layout.DpiChangedAfterParent += (_, _) => Refit();
        FontChanged += (_, _) => { if (IsHandleCreated) Refit(); };
        CustomSizes();
        FormClosed += (_, _) => { mark.Image?.Dispose(); action.Image?.Dispose(); tips.Dispose(); };
        action.Click += async (_, _) => { if (recording) await StopRecordingAsync(); else if (!busy) await StartRecordingAsync(); };
        timer.Tick += async (_, _) =>
        {
            if (!recording && !busy && recorder != null && !recorder.CleanupPending)
            { recorder = null; SetControls(true); }
            if (!busy && recorder?.CleanupPending != true) await UpdateIdlePreviewAsync();
            if (!recording || recorder == null) return;
            recorder.PreviewEnabled = previewVisible && Visible && WindowState != FormWindowState.Minimized && !edge.IsDocked;
            clock.Text = FormatTimecode(recorder.Seconds);
            detail.Text = options.IncludesCamera ? (recorder.Peak > .001 ? "正在写入本机 · ● 收到话筒声音" : "正在写入本机 · ○ 话筒静音") : !options.SystemAudio ? "正在写入本机 · 系统声音已关闭" : recorder.Peak > .001 ? "正在写入本机 · ● 收到系统声音" : "正在写入本机 · ○ 系统声音静音";
            previewState.Text = (options.IncludesCamera ? cameraPreview.Image : preview.Image) == null ? "等待预览" : "实时画面";
            FitContent();
            try { recorder.CheckHealth(); }
            catch (Exception ex) { await StopRecordingAsync(ex.Message); }
            edge.Tick();
        };
        Shown += (_, _) =>
        {
            FitContent();
            var working = Screen.FromHandle(Handle).WorkingArea;
            Location = new(working.Right - Width - U(16), working.Top + U(16));
            ApplyCaptureVisibility();
        };
        VisibleChanged += async (_, _) => { if (recorder != null) recorder.PreviewEnabled = previewVisible && Visible && WindowState != FormWindowState.Minimized; await UpdateIdlePreviewAsync(); };
        Resize += async (_, _) => await UpdateIdlePreviewAsync();
        FormClosing += (_, e) =>
        {
            if (busy) { e.Cancel = true; if (!Automation) MessageBox.Show(this, "请先停止录制并等待保存完成，再关闭窗口。", "正在处理素材"); }
        };
        FormClosed += (_, _) => { tray.Dispose(); timer.Dispose(); idlePreview?.Dispose(); idlePreview = null; idleCamera?.Dispose(); idleCamera = null; cameraPreview.Image?.Dispose(); edge.Dispose(); preview.Image?.Dispose(); };
        try { if (File.Exists(preference)) { string saved = File.ReadAllText(preference).Trim(); if (Path.IsPathFullyQualified(saved)) root = saved; } RefreshDevices(); }
        catch (Exception ex) { ShowError(ex); }
        ResumeLayout(false);
        timer.Start();
    }

    void ShowRecordingSettings()
    {
        if (!CanChangeStealth) return;
        using var dialog = CreateSettingsForm();
        dialog.ShowDialog(this);
        _ = UpdateIdlePreviewAsync();
    }
    internal SettingsForm CreateSettingsForm()
    {
        RefreshDevices();
        var dialog = new SettingsForm(this, options);
        settingsDialog = dialog;
        dialog.HandleCreated += (_, _) => ApplyCaptureVisibility();
        dialog.FormClosed += (_, _) => { settingsDialog = null; ApplyCaptureVisibility(); };
        return dialog;
    }
    internal string OutputDirectory => root;
    internal void ChangeOutputDirectory(IWin32Window owner)
    {
        if (!CanChangeStealth) return;
        using var dialog = new FolderBrowserDialog { InitialDirectory = root, Description = "选择素材目录" };
        if (dialog.ShowDialog(owner) != DialogResult.OK) return;
        try { Directory.CreateDirectory(Path.GetDirectoryName(preference)!); File.WriteAllText(preference, dialog.SelectedPath); root = dialog.SelectedPath; }
        catch (Exception ex) { ShowError(ex); }
    }
    internal void DetectDevices() { if (CanChangeStealth) { RefreshDevices(); _ = UpdateIdlePreviewAsync(); } }
    internal async Task RecoverAsync(SettingsForm dialog)
    {
        if (!CanChangeStealth) return;
        busy = true; SetControls(false); dialog.SetRecovering(true);
        var recoveryRecorder = new Recorder(tools);
        try
        {
            await StopIdlePreviewAsync();
            var recovered = await recoveryRecorder.RecoverUnfinishedAsync(root);
            MessageBox.Show(dialog, recovered.Length == 0 ? "未找到可恢复的未完成素材。正在录制的目录会跳过。" : $"已生成 {recovered.Length} 份恢复副本。请在素材目录的 Recovery 文件夹检查音画。原素材保留。", "素材恢复");
        }
        catch (Exception ex) { MessageBox.Show(dialog, ex.Message, "恢复未完成，原素材保留"); }
        finally
        {
            busy = false;
            if (recoveryRecorder.CleanupPending)
            {
                recorder = recoveryRecorder; state.Text = "素材需要检查";
                detail.Text = "恢复进程尚未退出，暂不可再次录制或恢复。可退出后重新打开。";
            }
            dialog.SetRecovering(false); SetControls(true); FitContent(); _ = UpdateIdlePreviewAsync();
        }
    }

    async Task StopIdlePreviewAsync()
    {
        await idlePreviewGate.WaitAsync();
        try { await StopIdlePreviewCoreAsync(); }
        finally { idlePreviewGate.Release(); }
    }
    async Task StopIdlePreviewCoreAsync()
    {
        var camera = idleCamera; var current = idlePreview;
        idleCamera = null; idlePreview = null; idlePreviewGeneration++;
        try { await Task.WhenAll(camera?.StopAsync() ?? Task.CompletedTask, current?.StopAsync() ?? Task.CompletedTask); }
        finally { camera?.Dispose(); current?.Dispose(); }
    }
    async Task UpdateIdlePreviewAsync()
    {
        if (layoutOnly || IsDisposed || Disposing) return;
        // Timer and visibility changes may overlap while the process is exiting.
        if (!await idlePreviewGate.WaitAsync(0)) return;
        try
        {
            var screen = Screen.AllScreens.FirstOrDefault(x => x.DeviceName == options.ScreenId);
            bool cameraWanted = !IsDisposed && !Disposing && !busy && settingsDialog == null && recorder?.CleanupPending != true && Visible && previewVisible && WindowState != FormWindowState.Minimized && !edge.IsDocked && options.IncludesCamera;
            if (idleCamera != null && (!cameraWanted || idleCameraId != options.CameraId || idleCamera.HasExited))
            { var old = idleCamera; idleCamera = null; try { await old.StopAsync(); } finally { old.Dispose(); } }
            bool wanted = options.IncludesDesktop && settingsDialog == null && !IsDisposed && !Disposing && !busy && recorder?.CleanupPending != true && Visible && previewVisible && WindowState != FormWindowState.Minimized && !edge.IsDocked && screen != null;
            if (idlePreview != null && (!wanted || idlePreview.Bounds != screen!.Bounds || idlePreview.HasExited))
                await StopIdlePreviewCoreAsync();
            if (cameraWanted && idleCamera == null && DateTime.UtcNow >= nextIdlePreviewAttempt)
            {
                nextIdlePreviewAttempt = DateTime.UtcNow.AddSeconds(5);
                string cameraId = options.CameraId;
                var device = await CameraDevices.ResolveAsync(tools, cameraId);
                if (!CameraDevices.Fake) CapturePrivacy.Check("webcam");
                var format = CameraDevices.ChooseFormat(await CameraDevices.FormatsAsync(tools, device));
                if (busy || IsDisposed || settingsDialog != null || !Visible || !previewVisible || edge.IsDocked || WindowState == FormWindowState.Minimized || !options.IncludesCamera || options.CameraId != cameraId) return;
                idleCameraId = cameraId;
                idleCamera = new IdlePreview(tools, Rectangle.Empty, bytes => ReceiveCameraPreview(bytes), device, format);
            }
            if (!wanted || IsDisposed || Disposing || busy || !Visible || !previewVisible || WindowState == FormWindowState.Minimized || idlePreview != null || DateTime.UtcNow < nextDesktopPreviewAttempt) return;
            nextDesktopPreviewAttempt = DateTime.UtcNow.AddSeconds(5);
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
                            previewState.Text = "实时画面";
                        }
                        catch (ArgumentException) { }
                        finally { Interlocked.Exchange(ref pendingPreview, 0); }
                    }));
                }
                catch (InvalidOperationException) { Interlocked.Exchange(ref pendingPreview, 0); }
            });
        }
        catch (Exception ex) when (ex is IOException or System.ComponentModel.Win32Exception or InvalidOperationException or TimeoutException)
        { previewState.Text = "预览不可用"; /* Preview failure must not block recording. */ }
        finally { idlePreviewGate.Release(); }
    }

    internal void SetMode(string mode, bool persist = true)
    {
        if (!CanChangeStealth || mode is not ("camera" or "desktop" or "both")) return;
        string previous = options.Mode; options.Mode = mode;
        try { if (persist) options.Save(); }
        catch (Exception ex) { options.Mode = previous; ShowError(ex); return; }
        for (int i = 0; i < modeButtons.Count; i++)
        {
            var button = modeButtons[i]; button.Selected = mode == new[] { "camera", "desktop", "both" }[i];
            button.AccessibleDescription = button.Selected ? "已选择" : "未选择"; button.Invalidate();
        }
        var old = cameraPreview.Image; cameraPreview.Image = null; old?.Dispose();
        detail.Text = (mode == "camera" ? "摄像头 + 话筒" : mode == "both" ? "摄像头 + 桌面" : "桌面 + 系统声音") + " · 仅保存在本机";
        FitContent(); _ = UpdateIdlePreviewAsync();
    }
    void ReceiveCameraPreview(byte[] bytes)
    {
        if (IsDisposed || Interlocked.Exchange(ref pendingCameraPreview, 1) != 0) return;
        try
        {
            BeginInvoke((Action)(() =>
            {
                try
                {
                    if (IsDisposed || !previewVisible || !Visible || edge.IsDocked || WindowState == FormWindowState.Minimized || !options.IncludesCamera) return;
                    using var input = new MemoryStream(bytes); using var image = Image.FromStream(input);
                    var old = cameraPreview.Image; cameraPreview.Image = new Bitmap(image); old?.Dispose();
                }
                catch (ArgumentException) { }
                finally { Interlocked.Exchange(ref pendingCameraPreview, 0); }
            }));
        }
        catch (InvalidOperationException) { Interlocked.Exchange(ref pendingCameraPreview, 0); }
    }

    void TogglePreview()
    {
        previewVisible = !previewVisible;
        previewRow.Visible = previewVisible;
        fold.Text = previewVisible ? "收起预览" : "展开预览";
        fold.Expanded = previewVisible; fold.Invalidate();
        if (recorder != null) recorder.PreviewEnabled = previewVisible;
        _ = UpdateIdlePreviewAsync();
        FitContent();
    }
    int U(int logical) => (int)Math.Round(LogicalToDeviceUnits(logical) * layoutScale);
    void UpdateActionIcon()
    {
        if (action.Image != null && action.Image.Width == U(16) && action.Tag is bool previous && previous == recording) return;
        var old = action.Image; action.Image = new Bitmap(U(16), U(16)); action.Tag = recording;
        ((Bitmap)action.Image).SetResolution(DeviceDpi, DeviceDpi);
        using (var g = Graphics.FromImage(action.Image))
        using (var font = Theme.IconFont(11 * layoutScale))
        using (var ink = new SolidBrush(Theme.Ink))
        using (var format = new StringFormat { Alignment = StringAlignment.Center, LineAlignment = StringAlignment.Center })
            g.DrawString(recording ? "\uE71A" : "\uE768", font, ink, new RectangleF(0, 0, action.Image.Width, action.Image.Height), format);
        old?.Dispose();
    }
    internal void FitContent()
    {
        if (layout.Parent == null || fitting) return;
        fitting = true;
        try
        {
            ClientSize = new(U(336), ClientSize.Height);
            layout.Width = ClientSize.Width;
            UpdateActionIcon();
            layout.PerformLayout();
            Theme.WrapLabels(layout);
            detail.MaximumSize = new(U(304), detail.Font.Height * 2 + U(2));
            clockHint.MaximumSize = new(Math.Max(1, timeRow.Width - clock.Width - clock.Margin.Horizontal - clockHint.Margin.Horizontal), 0);
            timeRow.Visible = hasTimecode;
            clockHint.Text = recording ? "15 秒无操作后收起" : "本次录制时长";
            dot.ForeColor = recording ? Theme.Accent : busy || LastError != null || state.Text == "素材需要检查" ? Theme.Orange : Theme.Mint;
            previewRow.Visible = previewVisible;
            cameraPreview.Visible = options.IncludesCamera; preview.Visible = options.IncludesDesktop;
            previewRow.ColumnStyles[0].Width = options.Mode == "both" ? 50 : options.IncludesCamera ? 100 : 0;
            previewRow.ColumnStyles[1].Width = 100 - previewRow.ColumnStyles[0].Width;
            cameraPreview.Invalidate();
            preview.Caption = options.SystemAudio ? "桌面 · 系统声音" : "桌面 · 无声音";
            preview.Invalidate();
            layout.PerformLayout();
            ClientSize = new(ClientSize.Width, layout.GetPreferredSize(new Size(ClientSize.Width, 0)).Height);
        }
        finally { fitting = false; }
    }
    internal void ScaleForLayoutTest(float factor)
    {
        layoutScale = factor;
        Theme.ScaleLayoutFixture(this, factor);
        FitContent();
    }
    internal void SetRecordingLayoutForTest(bool value)
    {
        // Only the layout fixture uses this; it never creates a recorder or writes preferences.
        recording = value; hasTimecode = value; clock.Text = "00:12:34";
        state.Text = value ? "正在录制" : "准备就绪";
        action.Text = value ? "停止并保存" : "开始录制"; FitContent();
    }
    protected override void OnPaintBackground(PaintEventArgs e)
    {
        using var tint = new LinearGradientBrush(ClientRectangle, Color.FromArgb(43, 45, 55), BackColor, 80f);
        e.Graphics.FillRectangle(tint, ClientRectangle);
    }
    [DllImport("user32.dll")] static extern bool ReleaseCapture();
    [DllImport("user32.dll")] static extern IntPtr SendMessage(IntPtr hwnd, int message, IntPtr wParam, IntPtr lParam);

    void RefreshDevices()
    {
        try
        {
            if (options.ScreenId.Length == 0) options.ScreenId = Screen.PrimaryScreen?.DeviceName ?? "";
            selectedAudio = null;
            var devices = CoreAudio.Devices();
            selectedAudio = devices.FirstOrDefault(x => x.Id == options.AudioId);
        }
        catch (Exception ex) { ShowError(ex); }
    }
    public void SetTestOutput(string directory) { if (busy) throw new InvalidOperationException(); root = directory; }
    public async Task StartRecordingAsync()
    {
        if (busy || recording || recorder?.CleanupPending == true) return;
        if (!StealthInCapture && !Automation && MessageBox.Show(this, "已关闭「在录屏里隐身」：小窗会出现在本次桌面录制画面中（15 秒无操作后收起为边缘红点）。继续录制？", "录制提示", MessageBoxButtons.OKCancel, MessageBoxIcon.Warning) != DialogResult.OK) return;
        LastError = null; clock.Text = "00:00:00"; hasTimecode = false; busy = true; SetControls(false); state.Text = "正在准备…"; FitContent();
        try
        {
            await StopIdlePreviewAsync();
            if (StealthInCapture && !excluded) throw new InvalidOperationException("小窗排除设置未成功，取消录制");
            RefreshDevices();
            string id = options.ScreenId;
            Screen screen = !options.IncludesDesktop || id.Length == 0 ? Screen.PrimaryScreen! : Screen.AllScreens.FirstOrDefault(x => x.DeviceName == id) ?? throw new InvalidOperationException("所选显示器已断开");
            var audioDevice = selectedAudio;
            if (options.IncludesDesktop && options.SystemAudio && audioDevice == null) throw new InvalidOperationException("请选择系统声音输出设备");
            SetThreadExecutionState(0x80000001);
            var current = new Recorder(tools) { PreviewEnabled = previewVisible };
            recorder = current;
            current.CameraPreview = ReceiveCameraPreview;
            current.Preview = bytes =>
            {
                if (!options.IncludesDesktop) { ReceiveCameraPreview(bytes); return; }
                ReceiveDesktopPreview(bytes);
            };
            void ReceiveDesktopPreview(byte[] bytes)
            {
                if (IsDisposed || Interlocked.Exchange(ref pendingPreview, 1) != 0) return;
                try
                {
                    BeginInvoke((Action)(() =>
                    {
                        try
                        {
                            if (IsDisposed || recorder != current || !previewVisible || edge.IsDocked) return;
                            using var input = new MemoryStream(bytes); using var image = Image.FromStream(input);
                            var old = preview.Image; preview.Image = new Bitmap(image); old?.Dispose();
                            previewState.Text = "实时画面";
                        }
                        catch (ArgumentException) { }
                        finally { Interlocked.Exchange(ref pendingPreview, 0); }
                    }));
                }
                catch (InvalidOperationException) { Interlocked.Exchange(ref pendingPreview, 0); }
            }
            var previousCamera = cameraPreview.Image; cameraPreview.Image = null; previousCamera?.Dispose();
            var previous = preview.Image; preview.Image = null; previous?.Dispose();
            await current.StartAsync(root, screen.Bounds, audioDevice?.Id ?? "", options.Quality, options.SystemAudio, options.OutputProfile, StealthInCapture, options.Mode, options.CameraId, options.MicrophoneId);
            lastFolder = current.Folder; recording = true; hasTimecode = true; edge.ResetIdle();
            state.Text = "正在录制";
            action.Text = "停止并保存"; action.AccessibleName = action.Text; action.Enabled = true; previewState.Text = "等待预览"; FitContent();
        }
        catch (Exception ex)
        {
            lastFolder = recorder?.Folder; if (recorder?.CleanupPending != true) recorder = null; busy = false;
            SetThreadExecutionState(0x80000000); SetControls(true); state.Text = "素材需要检查"; ShowError(ex);
            if (recorder?.CleanupPending == true) { detail.Text = "后台资源尚未释放，暂不可再次录制。可退出后重新打开恢复原素材。"; FitContent(); }
        }
    }
    public async Task StopRecordingAsync(string? reason = null)
    {
        if (!recording || recorder == null) return;
        recording = false; edge.Reveal(false); action.Enabled = false; state.Text = "正在保存…"; detail.Text = "正在合成音画，请勿退出或拔盘"; FitContent();
        var current = recorder;
        try
        {
            await current.StopAsync(reason);
            state.Text = current.Failure == null ? "录制已保存" : "素材需要检查";
            detail.Text = current.Failure ?? (options.Mode == "camera" ? "camera.mp4" : options.Mode == "both" ? "camera.mp4 + desktop.mp4" : "desktop.mp4") + " · 请检查音画后交付";
            if (current.Failure != null) LastError = new InvalidOperationException(current.Failure);
        }
        catch (Exception ex) { state.Text = "素材需要检查"; ShowError(ex); }
        finally
        {
            busy = false; if (!current.CleanupPending) recorder = null; SetThreadExecutionState(0x80000000); SetControls(true);
            action.Text = "开始录制"; action.AccessibleName = action.Text;
            if (current.CleanupPending) detail.Text = "素材需要检查；后台资源尚未释放，暂不可再次录制。可退出后重新打开恢复原素材。";
            FitContent(); _ = UpdateIdlePreviewAsync();
        }
    }
    void SetControls(bool enabled)
    {
        enabled &= recorder?.CleanupPending != true;
        settingsButton.Enabled = enabled;
        foreach (var button in modeButtons) button.Enabled = enabled;
        action.Enabled = enabled && (!StealthInCapture || excluded);
        settingsDialog?.SyncStealth();
    }
    internal void SetStealthInCapture(bool value, bool persist = true)
    {
        if (!CanChangeStealth || value == StealthInCapture) return;
        bool previous = StealthInCapture;
        options.StealthInCapture = value;
        try { if (persist) options.Save(); }
        catch (Exception ex) { options.StealthInCapture = previous; ShowError(ex); return; }
        ApplyCaptureVisibility();
        settingsDialog?.SyncStealth();
    }
    void ApplyCaptureVisibility()
    {
        excluded = CaptureVisibility.Apply(this, StealthInCapture);
        edge.ApplyCaptureVisibility();
        excluded &= edge.Excluded;
        if (settingsDialog?.IsHandleCreated == true) excluded &= CaptureVisibility.Apply(settingsDialog, StealthInCapture);
        SetControls(CanChangeStealth);
        if (StealthInCapture && !excluded) { state.Text = "素材需要检查"; detail.Text = "请使用 Windows 10 2004 或更新版本"; }
        else if (detail.Text == "请使用 Windows 10 2004 或更新版本") { state.Text = "准备就绪"; detail.Text = "桌面 + 系统声音 · 仅保存在本机"; }
        FitContent();
    }
    internal void ShowSmallWindow()
    {
        edge.Reveal(true); Show();
        if (WindowState == FormWindowState.Minimized) WindowState = FormWindowState.Normal;
        Activate();
    }
    internal void OpenMaterialFolder()
    {
        try { string path = lastFolder ?? root; Directory.CreateDirectory(path); Process.Start(new ProcessStartInfo(path) { UseShellExecute = true }); }
        catch (Exception ex) { ShowError(ex); }
    }
    void ShowError(Exception ex)
    {
        edge.Reveal(false); LastError = ex; detail.Text = ex.Message; FitContent();
        if (Automation) return;
        if (ex.Message.Contains("Windows 隐私设置禁止"))
        {
            if (MessageBox.Show(this, ex.Message + "。打开 Windows 隐私设置？", "录制提示", MessageBoxButtons.YesNo, MessageBoxIcon.Warning) == DialogResult.Yes)
                Process.Start(new ProcessStartInfo("ms-settings:privacy-" + (ex.Message.Contains("摄像头") ? "webcam" : "microphone")) { UseShellExecute = true });
        }
        else MessageBox.Show(this, ex.Message, "录制提示", MessageBoxButtons.OK, MessageBoxIcon.Warning);
    }
    protected override void WndProc(ref Message message)
    {
        if ((message.Msg == 0x218 && message.WParam.ToInt32() == 4 || message.Msg == 0x7E) && recording)
            BeginInvoke((Action)(async () => await StopRecordingAsync("系统睡眠或显示器配置改变，请检查已保留素材")));
        if ((message.Msg == 0x219 || message.Msg == 0x7E) && !busy) BeginInvoke((Action)RefreshDevices);
        base.WndProc(ref message);
    }
    [DllImport("kernel32.dll")] static extern uint SetThreadExecutionState(uint flags);
}
