using System.ComponentModel;
using System.Diagnostics;
using System.Drawing;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using Forms = System.Windows.Forms;

namespace ZSirCapture;

public partial class SettingsWindow : Window
{
    readonly RecordingController controller;
    readonly RecordingOptions options;
    readonly DispatcherTimer previewTimer = new() { Interval = TimeSpan.FromMilliseconds(100) };
    readonly SemaphoreSlim previewGate = new(1, 1);
    static readonly string[] Profiles = ["balanced", "detailed", "native"], Levels = ["compact", "standard", "high"];
    IdlePreview? idleCamera;
    Loopback? mic;
    string? micFile;
    bool closing, closeReady, closed, recovering, loading = true, syncing;
    int pendingFrame;
    HwndSource? source;
    internal bool IsAdvanced { get; private set; }
    internal IntPtr Handle => new WindowInteropHelper(this).Handle;
    internal SettingsWindow(MainWindow owner, RecordingController controller)
    {
        InitializeComponent(); Owner = owner; this.controller = controller; options = controller.Options;
        CameraCard.Visibility = options.IncludesCamera ? Visibility.Visible : Visibility.Collapsed;
        DesktopCard.Visibility = options.IncludesDesktop ? Visibility.Visible : Visibility.Collapsed;
        OutputSize.ItemsSource = new[] { "均衡 · 最长边 1920 像素", "1440p · 最长边 2560 像素", "原始尺寸" };
        int profileIndex = Array.IndexOf(Profiles, options.OutputProfile); OutputSize.SelectedIndex = profileIndex >= 0 ? profileIndex : 2;
        Quality.ItemsSource = new[] { "省空间", "标准 · 推荐", "高画质" }; Quality.SelectedIndex = Math.Max(0, Array.IndexOf(Levels, options.Quality));
        CaptureAudio.IsChecked = options.SystemAudio; Audio.IsEnabled = options.SystemAudio;
        previewTimer.Tick += (_, _) => MicLevel.Value = Math.Clamp((mic?.Peak ?? 0) * 100, 0, 100);
        controller.ControlsChanged += SyncStealth;
        SourceInitialized += (_, _) =>
        {
            WindowEffects.Apply(this); source = HwndSource.FromHwnd(Handle); source?.AddHook(WindowMessage);
            CaptureVisibility.Apply(Handle, controller.StealthInCapture);
        };
        Loaded += async (_, _) => { FitWindow(); await ReloadCamerasAsync(); };
        StateChanged += async (_, _) => await RestartCameraPreviewAsync();
        Closing += OnClosing;
        Closed += (_, _) => { closed = true; previewTimer.Stop(); controller.ControlsChanged -= SyncStealth; source?.RemoveHook(WindowMessage); };
        UpdatePaths(); ReloadDevices(); SyncStealth(); loading = false;
    }
    void FitWindow()
    {
        var area = ScreenGeometry.WorkingArea(Handle);
        MaxHeight = Math.Max(200, area.Height - 32);
        UpdateLayout();
    }
    void Change(Action change)
    {
        if (loading || !controller.CanChangeStealth) return;
        try { change(); options.Save(); controller.DetectDevices(); UpdateEstimate(); }
        catch (Exception ex) { MessageBox.Show(this, ex.Message, "录制设置未能保存", MessageBoxButton.OK, MessageBoxImage.Warning); }
    }
    async void CameraChanged(object sender, SelectionChangedEventArgs e)
    {
        if (loading || Cameras.SelectedItem is not CameraDevice device) return;
        Change(() => options.CameraId = device.Id); await RestartCameraPreviewAsync();
    }
    async void MicrophoneChanged(object sender, SelectionChangedEventArgs e)
    {
        if (loading || Microphones.SelectedItem is not AudioDevice device) return;
        Change(() => options.MicrophoneId = device.Id); await RestartCameraPreviewAsync();
    }
    void AudioChanged(object sender, SelectionChangedEventArgs e) { if (!loading && Audio.SelectedItem is AudioDevice device) Change(() => options.AudioId = device.Id); }
    void DisplayChanged(object sender, SelectionChangedEventArgs e) { if (!loading && Displays.SelectedItem is DisplayChoice display) Change(() => options.ScreenId = display.Id); }
    void OutputChanged(object sender, SelectionChangedEventArgs e) { if (OutputSize.SelectedIndex >= 0) Change(() => options.OutputProfile = Profiles[OutputSize.SelectedIndex]); }
    void QualityChanged(object sender, SelectionChangedEventArgs e) { if (Quality.SelectedIndex >= 0) Change(() => options.Quality = Levels[Quality.SelectedIndex]); }
    void SystemAudioChanged(object sender, RoutedEventArgs e) => Change(() => { options.SystemAudio = CaptureAudio.IsChecked == true; Audio.IsEnabled = options.SystemAudio; });
    void StealthChanged(object sender, RoutedEventArgs e) { if (syncing || loading) return; controller.SetStealthInCapture(Stealth.IsChecked == true); SyncStealth(); }
    void UpdatePaths() { AdvancedPath.Text = controller.OutputDirectory; SavePath.Text = IsAdvanced ? $"版本 {typeof(Program).Assembly.GetName().Version?.ToString(3)}" : $"保存到 {controller.OutputDirectory}"; }
    internal void ShowAdvanced(bool value)
    {
        IsAdvanced = value; MainPage.Visibility = value ? Visibility.Collapsed : Visibility.Visible; AdvancedPage.Visibility = value ? Visibility.Visible : Visibility.Collapsed;
        Back.Visibility = value ? Visibility.Visible : Visibility.Collapsed; Advanced.Visibility = value ? Visibility.Collapsed : Visibility.Visible;
        Heading.Text = value ? "高级设置" : "录制设置"; Done.Content = value ? "返回" : "完成";
        Done.Style = (Style)FindResource(value ? typeof(Button) : "AccentButton");
        Viewport.ScrollToHome(); UpdatePaths(); UpdateLayout(); _ = RestartCameraPreviewAsync();
    }
    void AdvancedClick(object sender, RoutedEventArgs e) => ShowAdvanced(true);
    void BackClick(object sender, RoutedEventArgs e) => ShowAdvanced(false);
    void DoneClick(object sender, RoutedEventArgs e) { if (IsAdvanced) ShowAdvanced(false); else Close(); }
    void ChangeFolderClick(object sender, RoutedEventArgs e)
    {
        if (!controller.CanChangeStealth) return;
        using var dialog = new Forms.FolderBrowserDialog { InitialDirectory = controller.OutputDirectory, Description = "选择素材目录" };
        if (dialog.ShowDialog(new NativeOwner(Handle)) == Forms.DialogResult.OK) controller.ChangeOutputDirectory(dialog.SelectedPath);
        UpdatePaths();
    }
    async void DetectClick(object sender, RoutedEventArgs e)
    {
        if (!controller.CanChangeStealth) return;
        controller.DetectDevices(); ReloadDevices(); await ReloadCamerasAsync();
    }
    async void RecoverClick(object sender, RoutedEventArgs e)
    {
        if (!controller.CanChangeStealth) return;
        recovering = true; Root.IsEnabled = false;
        try { await controller.RecoverAsync(); }
        finally { recovering = false; Root.IsEnabled = true; SyncStealth(); }
    }
    void PrivacyClick(object sender, RoutedEventArgs e) => Process.Start(new ProcessStartInfo("ms-settings:privacy-" + (CameraState.Text.Contains("摄像头") ? "webcam" : "microphone")) { UseShellExecute = true });
    internal void SyncStealth()
    {
        syncing = true;
        try { Stealth.IsChecked = controller.StealthInCapture; CameraCard.IsEnabled = DesktopCard.IsEnabled = AdvancedCard.IsEnabled = controller.CanChangeStealth; }
        finally { syncing = false; }
    }
    void ReloadDevices()
    {
        bool wasLoading = loading; loading = true;
        try
        {
            var names = DisplayNames.FriendlyNames(); var allScreens = Screen.AllScreens;
            Displays.ItemsSource = allScreens.Select((screen, i) =>
            {
                string caption = DisplayNames.Caption(screen, i, names); string[] lines = caption.Split('\n', 2);
                return new DisplayChoice(screen.DeviceName, lines.Length == 2 ? lines[0] : $"显示器 {i + 1}", lines[^1], Thumbnail(screen));
            }).ToArray();
            Displays.SelectedItem = Displays.Items.Cast<DisplayChoice>().FirstOrDefault(d => d.Id == options.ScreenId);
            Audio.Items.Clear(); foreach (var device in CoreAudio.Devices()) Audio.Items.Add(device);
            Audio.SelectedItem = Audio.Items.Cast<AudioDevice>().FirstOrDefault(d => d.Id == options.AudioId);
            if (Audio.SelectedIndex < 0 && options.AudioId.Length != 0) { var missing = new AudioDevice(options.AudioId, "原播放设备已断开，请重新选择"); Audio.Items.Add(missing); Audio.SelectedItem = missing; }
            UpdateEstimate();
        }
        catch (Exception ex) { Estimate.Text = "设备检测未完成：" + ex.Message; }
        finally { loading = wasLoading; }
    }
    static BitmapSource? Thumbnail(Screen screen)
    {
        try
        {
            using var bitmap = new Bitmap(screen.Bounds.Width, screen.Bounds.Height);
            using (var graphics = Graphics.FromImage(bitmap)) graphics.CopyFromScreen(screen.Bounds.Location, System.Drawing.Point.Empty, screen.Bounds.Size);
            using var small = new Bitmap(bitmap, new System.Drawing.Size(480, Math.Max(1, 480 * bitmap.Height / bitmap.Width)));
            using var stream = new MemoryStream(); small.Save(stream, System.Drawing.Imaging.ImageFormat.Png); return RecordingController.DecodeFrame(stream.ToArray());
        }
        catch (Exception ex) when (ex is ArgumentException or System.Runtime.InteropServices.ExternalException) { return null; }
    }
    void UpdateEstimate()
    {
        var screen = Screen.AllScreens.FirstOrDefault(x => x.DeviceName == options.ScreenId);
        if (screen == null) { Estimate.Text = "所选屏幕已断开，请重新选择"; return; }
        var target = RecordingOptions.OutputSize(options.OutputProfile, screen.Bounds.Width, screen.Bounds.Height);
        double megabits = RecordingOptions.BitRate(options.Quality, target.Width, target.Height) / 1_000_000.0;
        Estimate.Text = $"输出 {target.Width} × {target.Height} · {RecordingOptions.FramesPerSecond} fps · {megabits:0.#} Mbps · 成品约 {(megabits + (options.SystemAudio ? .192 : 0)) * .45:0.0} GB/小时";
        Estimate.ToolTip = "Windows 保留中间素材，实际磁盘占用高于成品。";
    }
    internal async Task ReloadCamerasAsync()
    {
        if (controller.LayoutOnly)
        {
            loading = true; Cameras.Items.Clear(); Cameras.Items.Add(new CameraDevice("fixture", "测试摄像头 · 中文名称与重复设备")); Cameras.SelectedIndex = 0;
            Microphones.Items.Clear(); Microphones.Items.Add(new AudioDevice("fixture", "测试话筒")); Microphones.SelectedIndex = 0; loading = false; return;
        }
        try
        {
            await controller.ReleaseIdleForSettingsAsync();
            await previewGate.WaitAsync(); try { await StopCameraPreviewAsync(); } finally { previewGate.Release(); }
            var devices = await CameraDevices.DiscoverAsync(controller.Tools);
            if (closing || closed) return;
            loading = true;
            try
            {
                Cameras.Items.Clear(); Cameras.Items.Add(new CameraDevice("", "第一台可用摄像头")); foreach (var device in devices) Cameras.Items.Add(device);
                Cameras.SelectedItem = Cameras.Items.Cast<CameraDevice>().FirstOrDefault(d => d.Id == options.CameraId);
                if (Cameras.SelectedIndex < 0) { var missing = new CameraDevice(options.CameraId, "原摄像头已断开，请重新选择"); Cameras.Items.Add(missing); Cameras.SelectedItem = missing; }
                Microphones.Items.Clear(); foreach (var device in CoreAudio.Devices(1)) Microphones.Items.Add(device);
                Microphones.SelectedItem = Microphones.Items.Cast<AudioDevice>().FirstOrDefault(d => d.Id == options.MicrophoneId);
                if (Microphones.SelectedIndex < 0) { var missing = new AudioDevice(options.MicrophoneId, "原话筒已断开，请重新选择"); Microphones.Items.Add(missing); Microphones.SelectedItem = missing; }
                SetCameraState(devices.Count == 0 ? CameraDevices.NoCamera : "");
            }
            finally { loading = false; }
            await RestartCameraPreviewAsync();
        }
        catch (Exception ex) { if (!closed) SetCameraState(ex.Message); }
    }
    void SetCameraState(string message)
    {
        CameraState.Text = message; CameraState.Visibility = message.Length == 0 ? Visibility.Collapsed : Visibility.Visible;
        Privacy.Visibility = message.Contains("Windows 隐私设置禁止") ? Visibility.Visible : Visibility.Collapsed;
    }
    async Task StopCameraPreviewAsync()
    {
        previewTimer.Stop();
        await Task.WhenAll(idleCamera?.StopAsync() ?? Task.CompletedTask, mic?.StopAsync() ?? Task.CompletedTask);
        idleCamera?.Dispose(); idleCamera = null;
        if (mic?.IsActive == true) throw new IOException("话筒仍在释放中");
        mic = null;
        if (micFile != null) { File.Delete(micFile); micFile = null; }
    }
    async Task RestartCameraPreviewAsync()
    {
        await previewGate.WaitAsync();
        try
        {
            await StopCameraPreviewAsync();
            if (controller.LayoutOnly || closing || closed || !IsVisible || IsAdvanced || !options.IncludesCamera || WindowState == WindowState.Minimized || !controller.CanChangeStealth) return;
            await controller.ReleaseIdleForSettingsAsync();
            string cameraId = options.CameraId, microphoneId = options.MicrophoneId;
            var device = await CameraDevices.ResolveAsync(controller.Tools, cameraId);
            if (!CameraDevices.Fake) { CapturePrivacy.Check("webcam"); CapturePrivacy.Check("microphone"); }
            var format = CameraDevices.ChooseFormat(await CameraDevices.FormatsAsync(controller.Tools, device));
            if (closing || closed || IsAdvanced || WindowState == WindowState.Minimized || options.CameraId != cameraId || options.MicrophoneId != microphoneId) return;
            SetCameraState("");
            loading = true;
            try
            {
                if (Cameras.SelectedItem is CameraDevice selected)
                {
                    int index = Cameras.SelectedIndex;
                    Cameras.Items[index] = new CameraDevice(selected.Id, $"{device.Name}（{format.Width}×{format.Height} · {format.Vcodec ?? format.PixelFormat} {format.Fps:0.#}）");
                    Cameras.SelectedIndex = index;
                }
            }
            finally { loading = false; }
            idleCamera = new IdlePreview(controller.Tools, Rectangle.Empty, bytes =>
            {
                if (closing || closed || Interlocked.Exchange(ref pendingFrame, 1) != 0) return;
                try
                {
                    Dispatcher.BeginInvoke(DispatcherPriority.Render, new Action(() =>
                    {
                        try
                        {
                            // Keep validating the acquired camera stream while this page owns the device.
                            if (!closing && !closed && !IsAdvanced) _ = RecordingController.DecodeFrame(bytes);
                        }
                        catch (Exception ex) when (ex is ArgumentException or IOException or NotSupportedException or FormatException or System.Runtime.InteropServices.COMException) { }
                        finally { Interlocked.Exchange(ref pendingFrame, 0); }
                    }));
                }
                catch (InvalidOperationException) { Interlocked.Exchange(ref pendingFrame, 0); }
            }, device, format);
            micFile = Path.Combine(Path.GetTempPath(), "zsir-mic-preview-" + Guid.NewGuid().ToString("N") + ".wav"); mic = new Loopback();
            await mic.StartAsync(micFile, microphoneId, microphone: true, synthetic: CameraDevices.Fake).WaitAsync(TimeSpan.FromSeconds(10));
            previewTimer.Start();
        }
        catch (Exception ex) { if (!closed) SetCameraState(ex.Message); if (closing) throw; }
        finally { previewGate.Release(); }
    }
    async void OnClosing(object? sender, CancelEventArgs e)
    {
        if (recovering) { e.Cancel = true; return; }
        if (closing) { e.Cancel = !closeReady; return; }
        closing = true; if (controller.LayoutOnly) { closeReady = true; return; }
        e.Cancel = true; Root.IsEnabled = false;
        await Task.Yield();
        try { await RestartCameraPreviewAsync(); closeReady = true; Close(); }
        catch (Exception ex) { closing = false; Root.IsEnabled = true; SetCameraState("设备尚未释放：" + ex.Message); }
    }
    IntPtr WindowMessage(IntPtr hwnd, int message, IntPtr wParam, IntPtr lParam, ref bool handled)
    {
        if ((message == 0x219 || message == 0x7E) && !recovering)
            Dispatcher.BeginInvoke(new Action(async () => { if (!closed && controller.CanChangeStealth) { controller.DetectDevices(); ReloadDevices(); await ReloadCamerasAsync(); } }));
        return IntPtr.Zero;
    }
    internal void FitContent() => UpdateLayout();
    internal IDisposable ScaleForLayoutTest(double factor) => SmokeTest.ScaleForLayoutTest(this, factor);
    sealed record NativeOwner(IntPtr Handle) : Forms.IWin32Window;
    internal sealed record DisplayChoice(string Id, string Name, string Metadata, BitmapSource? Thumbnail);
}
