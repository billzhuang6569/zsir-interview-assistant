using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Windows.Media.Imaging;
using System.Windows.Threading;

namespace ZSirCapture;

internal interface IRecordingHost
{
    bool IsVisible { get; }
    bool IsMinimized { get; }
    bool IsEnabled { get; }
    bool IsDocked { get; }
    bool ApplyCaptureVisibility(bool stealth);
    bool ConfirmVisibleRecording();
    void ShowError(Exception error);
    void Notify(string message, string title);
    void Reveal(bool activate);
    void ResetIdle();
    void TickEdge();
}

// Owns recording, preview lifetimes and gates; the host supplies window services only.
internal sealed class RecordingController : IDisposable
{
    readonly IRecordingHost host;
    readonly Dispatcher dispatcher;
    readonly DispatcherTimer timer;
    readonly RecordingOptions options = RecordingOptions.Load();
    readonly SemaphoreSlim idlePreviewGate = new(1, 1);
    readonly string preference = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "ZSirCapture", "output-directory.txt");
    string root = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.MyVideos), "ZSir Recordings");
    string? lastFolder;
    Recorder? recorder;
    IdlePreview? idleCamera, idlePreview;
    AudioDevice? selectedAudio;
    string idleCameraId = "", idleDesktopId = "";
    int pendingCameraPreview, pendingPreview, idlePreviewGeneration, idleCameraGeneration;
    DateTime nextIdlePreviewAttempt, nextDesktopPreviewAttempt;
    bool disposed, excluded, settingsOpen;
    public MainViewModel ViewModel { get; } = new();
    public string Tools { get; }
    public bool LayoutOnly { get; }
    public bool Automation { get; set; }
    public RecordingOptions Options => options;
    public string OutputDirectory => root;
    public string? LastFolder => lastFolder;
    public Exception? LastError { get; private set; }
    public Recorder? CurrentRecorder => recorder;
    public bool IsRecording => ViewModel.IsRecording;
    public bool IsBusy => ViewModel.IsBusy;
    public string Timecode => ViewModel.Timecode;
    public bool StealthInCapture => options.StealthInCapture;
    public bool CanChangeStealth => !IsBusy && !IsRecording && recorder?.CleanupPending != true;
    public bool CanStartRecording => CanChangeStealth && host.IsEnabled && (!StealthInCapture || excluded);
    public event Action? ControlsChanged;

    public RecordingController(string tools, IRecordingHost host, Dispatcher dispatcher, bool automation = false, bool layoutOnly = false)
    {
        Tools = tools; this.host = host; this.dispatcher = dispatcher; Automation = automation; LayoutOnly = layoutOnly;
        ViewModel.Mode = options.Mode; ViewModel.Stealth = StealthInCapture;
        ViewModel.Detail = ModeDetail();
        try
        {
            if (File.Exists(preference)) { string saved = File.ReadAllText(preference).Trim(); if (Path.IsPathFullyQualified(saved)) root = saved; }
            RefreshDevices();
        }
        catch (Exception ex) { ShowError(ex); }
        timer = new DispatcherTimer(TimeSpan.FromMilliseconds(500), DispatcherPriority.Background, async (_, _) => await TickAsync(), dispatcher);
        if (layoutOnly) timer.Stop();
    }
    string ModeDetail() => (options.Mode == "camera" ? "摄像头 + 话筒" : options.Mode == "both" ? "摄像头 + 桌面" : "桌面 + 系统声音") + " · 素材仅保存在本机";
    async Task TickAsync()
    {
        if (disposed) return;
        if (!IsRecording && !IsBusy && recorder != null && !recorder.CleanupPending) { recorder = null; SyncControls(); }
        if (!IsBusy && recorder?.CleanupPending != true) await UpdateIdlePreviewAsync();
        if (!IsRecording || recorder == null) return;
        recorder.PreviewEnabled = PreviewWanted;
        ViewModel.Timecode = FormatTimecode(recorder.Seconds);
        ViewModel.MicLevel = Math.Clamp(recorder.Peak * 100, 0, 100);
        ViewModel.Detail = options.IncludesCamera ? (recorder.Peak > .001 ? "正在写入本机 · ● 收到话筒声音" : "正在写入本机 · ○ 话筒静音") : !options.SystemAudio ? "正在写入本机 · 系统声音已关闭" : recorder.Peak > .001 ? "正在写入本机 · ● 收到系统声音" : "正在写入本机 · ○ 系统声音静音";
        UpdatePreviewState();
        try { recorder.CheckHealth(); }
        catch (Exception ex) { await StopRecordingAsync(ex.Message); }
        host.TickEdge();
    }
    bool PreviewWanted => !disposed && host.IsVisible && !host.IsMinimized && ViewModel.PreviewVisible && !host.IsDocked;
    public static string FormatTimecode(double elapsed) { long seconds = (long)Math.Max(0, elapsed); return $"{seconds / 3600:00}:{seconds / 60 % 60:00}:{seconds % 60:00}"; }
    public void SetTestOutput(string directory) { if (IsBusy) throw new InvalidOperationException(); root = directory; }
    public void SetMode(string mode, bool persist = true)
    {
        if (!CanChangeStealth || mode is not ("camera" or "desktop" or "both")) return;
        string previous = options.Mode; options.Mode = mode;
        try { if (persist) options.Save(); }
        catch (Exception ex) { options.Mode = previous; ShowError(ex); return; }
        ViewModel.Mode = mode;
        if (ViewModel.Phase is "未检测到摄像头" or "摄像头不可用") ViewModel.Phase = "准备就绪";
        ViewModel.CameraImage = null; ViewModel.DesktopImage = null; ViewModel.MicLevel = 0; ViewModel.CameraMessage = "等待预览";
        ViewModel.CameraAvailable = true; ViewModel.Detail = ModeDetail();
        nextIdlePreviewAttempt = nextDesktopPreviewAttempt = DateTime.MinValue;
        SyncControls(); UpdatePreviewState(); _ = UpdateIdlePreviewAsync();
    }
    public void TogglePreview()
    {
        ViewModel.PreviewVisible = !ViewModel.PreviewVisible;
        if (ViewModel.PreviewVisible) nextIdlePreviewAttempt = nextDesktopPreviewAttempt = DateTime.MinValue;
        if (recorder != null) recorder.PreviewEnabled = PreviewWanted;
        _ = UpdateIdlePreviewAsync();
    }
    public void VisibilityChanged()
    {
        if (PreviewWanted) nextIdlePreviewAttempt = nextDesktopPreviewAttempt = DateTime.MinValue;
        SyncControls();
        if (recorder != null) recorder.PreviewEnabled = PreviewWanted;
        _ = UpdateIdlePreviewAsync();
    }
    public void SetSettingsOpen(bool value)
    {
        settingsOpen = value;
        if (!value) nextIdlePreviewAttempt = nextDesktopPreviewAttempt = DateTime.MinValue;
        _ = UpdateIdlePreviewAsync();
    }
    public Task ReleaseIdleForSettingsAsync() => StopIdlePreviewAsync();
    public void DetectDevices()
    {
        if (!CanChangeStealth) return;
        nextIdlePreviewAttempt = nextDesktopPreviewAttempt = DateTime.MinValue;
        ViewModel.CameraAvailable = true; ViewModel.CameraMessage = "等待预览";
        RefreshDevices(); SyncControls(); _ = UpdateIdlePreviewAsync();
    }
    void RefreshDevices()
    {
        try
        {
            if (options.ScreenId.Length == 0) options.ScreenId = Screen.PrimaryScreen?.DeviceName ?? "";
            selectedAudio = null;
            selectedAudio = CoreAudio.Devices().FirstOrDefault(x => x.Id == options.AudioId);
        }
        catch (Exception ex) { ShowError(ex); }
    }
    public void ChangeOutputDirectory(string directory)
    {
        if (!CanChangeStealth) return;
        try { Directory.CreateDirectory(Path.GetDirectoryName(preference)!); File.WriteAllText(preference, directory); root = directory; }
        catch (Exception ex) { ShowError(ex); }
    }
    public async Task RecoverAsync()
    {
        if (!CanChangeStealth) return;
        ViewModel.IsBusy = true; SyncControls();
        var recoveryRecorder = new Recorder(Tools);
        try
        {
            await StopIdlePreviewAsync();
            var recovered = await recoveryRecorder.RecoverUnfinishedAsync(root);
            host.Notify(recovered.Length == 0 ? "未找到可恢复的未完成素材。正在录制的目录会跳过。" : $"已生成 {recovered.Length} 份恢复副本。请在素材目录的 Recovery 文件夹检查音画。原素材保留。", "素材恢复");
        }
        catch (Exception ex) { host.Notify(ex.Message, "恢复未完成，原素材保留"); }
        finally
        {
            ViewModel.IsBusy = false;
            if (recoveryRecorder.CleanupPending)
            {
                recorder = recoveryRecorder; ViewModel.Phase = "素材需要检查";
                ViewModel.Detail = "恢复进程尚未退出，暂不可再次录制或恢复。可退出后重新打开。";
            }
            SyncControls(); _ = UpdateIdlePreviewAsync();
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
        idleCamera = null; idlePreview = null; ClearPreview(camera: true); ClearPreview(camera: false);
        try { await Task.WhenAll(camera?.StopAsync() ?? Task.CompletedTask, current?.StopAsync() ?? Task.CompletedTask); }
        finally { camera?.Dispose(); current?.Dispose(); }
    }
    async Task UpdateIdlePreviewAsync()
    {
        if (LayoutOnly || disposed || !await idlePreviewGate.WaitAsync(0)) return;
        try
        {
            var screen = Screen.AllScreens.FirstOrDefault(x => x.DeviceName == options.ScreenId);
            bool cameraWanted = PreviewWanted && !IsBusy && !settingsOpen && recorder?.CleanupPending != true && options.IncludesCamera;
            if (idleCamera != null && (!cameraWanted || idleCameraId != options.CameraId || idleCamera.HasExited))
            {
                var old = idleCamera; idleCamera = null; ClearPreview(camera: true);
                try { await old.StopAsync(); } finally { old.Dispose(); }
            }
            bool wanted = PreviewWanted && options.IncludesDesktop && !settingsOpen && !IsBusy && recorder?.CleanupPending != true && screen != null;
            if (idlePreview != null && (!wanted || idleDesktopId != options.ScreenId || idlePreview.Bounds != screen!.Bounds || idlePreview.HasExited)) await StopIdlePreviewCoreAsync();
            // Start desktop independently of camera discovery, including the no-camera case.
            if (wanted && PreviewWanted && !IsBusy && idlePreview == null && DateTime.UtcNow >= nextDesktopPreviewAttempt)
            {
                nextDesktopPreviewAttempt = DateTime.UtcNow.AddSeconds(5);
                ClearPreview(camera: false);
                int generation = idlePreviewGeneration;
                string screenId = options.ScreenId;
                idleDesktopId = screenId;
                idlePreview = new IdlePreview(Tools, screen!.Bounds, bytes => QueueFrame(bytes, false,
                    () => !IsBusy && !settingsOpen && generation == idlePreviewGeneration && screenId == options.ScreenId && options.IncludesDesktop && PreviewWanted));
            }
            if (cameraWanted && idleCamera == null && DateTime.UtcNow >= nextIdlePreviewAttempt)
            {
                try
                {
                    nextIdlePreviewAttempt = DateTime.UtcNow.AddSeconds(5);
                    ClearPreview(camera: true);
                    int generation = idleCameraGeneration;
                    string cameraId = options.CameraId;
                    var device = await CameraDevices.ResolveAsync(Tools, cameraId);
                    if (!CameraDevices.Fake) CapturePrivacy.Check("webcam");
                    var format = CameraDevices.ChooseFormat(await CameraDevices.FormatsAsync(Tools, device));
                    if (!PreviewWanted || IsBusy || settingsOpen || generation != idleCameraGeneration || !options.IncludesCamera || options.CameraId != cameraId) return;
                    idleCameraId = cameraId;
                    ViewModel.CameraAvailable = true; ViewModel.CameraMessage = "等待预览"; SyncControls();
                    if (ViewModel.Phase is "未检测到摄像头" or "摄像头不可用") { ViewModel.Phase = "准备就绪"; ViewModel.Detail = ModeDetail(); }
                    idleCamera = new IdlePreview(Tools, Rectangle.Empty, bytes => QueueFrame(bytes, true,
                        () => !IsBusy && !settingsOpen && generation == idleCameraGeneration && cameraId == options.CameraId && options.IncludesCamera && PreviewWanted), device, format);
                }
                catch (Exception ex) when (ex is IOException or System.ComponentModel.Win32Exception or InvalidOperationException or TimeoutException)
                { CameraPreviewFailed(ex); }
            }
        }
        catch (Exception ex) when (ex is IOException or System.ComponentModel.Win32Exception or InvalidOperationException or TimeoutException)
        {
            UpdatePreviewState();
            // Preview failure must not block a desktop-only recording.
        }
        finally { idlePreviewGate.Release(); }
    }
    void CameraPreviewFailed(Exception ex)
    {
        ClearPreview(camera: true);
        ViewModel.CameraAvailable = false; ViewModel.CameraMessage = ex.Message == CameraDevices.NoCamera ? "未检测到摄像头" : ex.Message;
        ViewModel.Phase = ex.Message == CameraDevices.NoCamera ? "未检测到摄像头" : "摄像头不可用";
        ViewModel.Detail = ex.Message == CameraDevices.NoCamera ? "连接摄像头后点「重新检测」，或切换到「桌面」" : ex.Message;
        SyncControls(); UpdatePreviewState();
    }
    void ClearPreview(bool camera)
    {
        if (camera)
        {
            idleCameraGeneration++; ViewModel.CameraImage = null; ViewModel.MicLevel = 0;
            if (ViewModel.CameraAvailable) ViewModel.CameraMessage = "等待预览";
        }
        else { idlePreviewGeneration++; ViewModel.DesktopImage = null; }
        UpdatePreviewState();
    }
    void QueueFrame(byte[] bytes, bool camera, Func<bool> valid)
    {
        if (disposed) return;
        if (camera ? Interlocked.Exchange(ref pendingCameraPreview, 1) != 0 : Interlocked.Exchange(ref pendingPreview, 1) != 0) return;
        try
        {
            dispatcher.BeginInvoke(DispatcherPriority.Render, new Action(() =>
            {
                try
                {
                    if (disposed || !valid()) return;
                    var image = DecodeFrame(bytes);
                    if (camera) { ViewModel.CameraImage = image; ViewModel.CameraAvailable = true; ViewModel.CameraMessage = ""; }
                    else ViewModel.DesktopImage = image;
                    UpdatePreviewState();
                }
                catch (Exception ex) when (ex is ArgumentException or IOException or NotSupportedException or FormatException or System.Runtime.InteropServices.COMException) { }
                finally { ClearPending(camera); }
            }));
        }
        catch (InvalidOperationException) { ClearPending(camera); }
    }
    void ClearPending(bool camera) { if (camera) Interlocked.Exchange(ref pendingCameraPreview, 0); else Interlocked.Exchange(ref pendingPreview, 0); }
    internal static BitmapSource DecodeFrame(byte[] bytes)
    {
        using var input = new MemoryStream(bytes);
        var image = new BitmapImage(); image.BeginInit(); image.CacheOption = BitmapCacheOption.OnLoad; image.StreamSource = input; image.EndInit(); image.Freeze(); return image;
    }
    void UpdatePreviewState() => ViewModel.PreviewState = options.IncludesCamera && !ViewModel.CameraAvailable ? "摄像头不可用" : ViewModel.HasTimecode && !IsRecording ? "上次录制画面" : (options.IncludesCamera ? ViewModel.CameraImage : ViewModel.DesktopImage) == null ? "等待预览" : "实时画面";
    public async Task StartRecordingAsync()
    {
        if (IsBusy || IsRecording || recorder?.CleanupPending == true) return;
        if (!StealthInCapture && !Automation && !host.ConfirmVisibleRecording()) return;
        LastError = null; ViewModel.Timecode = "00:00:00"; ViewModel.HasTimecode = false; ViewModel.IsBusy = true; ViewModel.Phase = "正在准备…"; SyncControls();
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
            var current = new Recorder(Tools) { PreviewEnabled = ViewModel.PreviewVisible };
            recorder = current;
            void ReceiveRecordingCamera(byte[] bytes) => QueueFrame(bytes, true, () => recorder == current && IsBusy && PreviewWanted && options.IncludesCamera);
            current.CameraPreview = ReceiveRecordingCamera;
            current.Preview = bytes => { if (!options.IncludesDesktop) ReceiveRecordingCamera(bytes); else QueueFrame(bytes, false, () => recorder == current && IsBusy && PreviewWanted); };
            ViewModel.CameraImage = null; ViewModel.DesktopImage = null;
            await current.StartAsync(root, screen.Bounds, audioDevice?.Id ?? "", options.Quality, options.SystemAudio, options.OutputProfile, StealthInCapture, options.Mode, options.CameraId, options.MicrophoneId);
            lastFolder = current.Folder; ViewModel.IsRecording = true; ViewModel.HasTimecode = true; host.ResetIdle();
            ViewModel.Phase = "正在录制"; ViewModel.PreviewState = "等待预览"; SyncControls();
        }
        catch (Exception ex)
        {
            lastFolder = recorder?.Folder; if (recorder?.CleanupPending != true) recorder = null; ViewModel.IsBusy = false;
            SetThreadExecutionState(0x80000000); ViewModel.Phase = "素材需要检查"; ShowError(ex); SyncControls();
            if (recorder?.CleanupPending == true) ViewModel.Detail = "后台资源尚未释放，暂不可再次录制。可退出后重新打开恢复原素材。";
        }
    }
    public async Task StopRecordingAsync(string? reason = null)
    {
        if (!IsRecording || recorder == null) return;
        ViewModel.IsRecording = false; host.Reveal(false); ViewModel.Phase = "正在保存…"; ViewModel.Detail = "正在合成音画，请勿退出或拔盘"; SyncControls();
        var current = recorder;
        try
        {
            await current.StopAsync(reason);
            ViewModel.Phase = current.Failure == null ? "录制已保存" : "素材需要检查";
            ViewModel.Detail = current.Failure ?? (options.Mode == "camera" ? "camera.mp4" : options.Mode == "both" ? "camera.mp4 + desktop.mp4" : "desktop.mp4") + " · 请检查音画后交付";
            if (current.Failure != null) LastError = new InvalidOperationException(current.Failure);
        }
        catch (Exception ex) { ViewModel.Phase = "素材需要检查"; ShowError(ex); }
        finally
        {
            ViewModel.IsBusy = false; if (!current.CleanupPending) recorder = null; SetThreadExecutionState(0x80000000); SyncControls(); UpdatePreviewState();
            if (current.CleanupPending) ViewModel.Detail = "素材需要检查；后台资源尚未释放，暂不可再次录制。可退出后重新打开恢复原素材。";
            _ = UpdateIdlePreviewAsync();
        }
    }
    void SyncControls()
    {
        ViewModel.HasWarning = LastError != null || recorder?.CleanupPending == true || (StealthInCapture && !excluded);
        ViewModel.CanChange = CanChangeStealth; ViewModel.CanStart = CanStartRecording && (!options.IncludesCamera || ViewModel.CameraMessage != "未检测到摄像头");
        ControlsChanged?.Invoke();
    }
    public void SetStealthInCapture(bool value, bool persist = true)
    {
        if (!CanChangeStealth || value == StealthInCapture) return;
        bool previous = StealthInCapture; options.StealthInCapture = value;
        try { if (persist) options.Save(); }
        catch (Exception ex) { options.StealthInCapture = previous; ShowError(ex); return; }
        ApplyCaptureVisibility();
    }
    public void ApplyCaptureVisibility()
    {
        excluded = host.ApplyCaptureVisibility(StealthInCapture); ViewModel.Stealth = StealthInCapture; SyncControls();
        if (StealthInCapture && !excluded) { ViewModel.Phase = "素材需要检查"; ViewModel.Detail = "小窗未能隐藏，请关闭「在录屏里隐身」后重试，或反馈此问题"; }
        else if (ViewModel.Detail == "小窗未能隐藏，请关闭「在录屏里隐身」后重试，或反馈此问题") { ViewModel.Phase = "准备就绪"; ViewModel.Detail = ModeDetail(); }
    }
    public void HandleSystemMessage(int message, IntPtr parameter)
    {
        if ((message == 0x218 && parameter.ToInt32() == 4 || message == 0x7E) && IsRecording)
            dispatcher.BeginInvoke(new Action(async () => await StopRecordingAsync("系统睡眠或显示器配置改变，请检查已保留素材")));
        if ((message == 0x219 || message == 0x7E) && !IsBusy) dispatcher.BeginInvoke(new Action(DetectDevices));
    }
    public void OpenMaterialFolder()
    {
        try { string path = lastFolder ?? root; Directory.CreateDirectory(path); Process.Start(new ProcessStartInfo(path) { UseShellExecute = true }); }
        catch (Exception ex) { ShowError(ex); }
    }
    void ShowError(Exception ex) { host.Reveal(false); LastError = ex; ViewModel.HasWarning = true; ViewModel.Detail = ex.Message; if (!Automation) host.ShowError(ex); }
    internal void SetRecordingLayoutForTest(bool value)
    {
        ViewModel.IsRecording = value; ViewModel.HasTimecode = value; ViewModel.Timecode = "00:12:34"; ViewModel.Phase = value ? "正在录制" : "准备就绪"; SyncControls();
    }
    internal void SetNoCameraLayoutForTest()
    {
        ViewModel.CameraAvailable = false; ViewModel.CameraImage = null; ViewModel.DesktopImage = null; ViewModel.MicLevel = 0; ViewModel.CameraMessage = "未检测到摄像头";
        ViewModel.Phase = "未检测到摄像头"; ViewModel.Detail = "连接摄像头后点「重新检测」，或切换到「桌面」"; SyncControls(); UpdatePreviewState();
    }
    public void Dispose()
    {
        disposed = true; timer.Stop(); idlePreview?.Dispose(); idleCamera?.Dispose(); idlePreview = idleCamera = null;
    }
    [DllImport("kernel32.dll")] static extern uint SetThreadExecutionState(uint flags);
}
