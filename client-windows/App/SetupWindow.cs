using System.Diagnostics;
using System.Text.Json;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using Windows.Media.Capture;

namespace ZsirRecorder.App;
internal sealed class SetupWindow : Window
{
    readonly LocalState state;
    readonly StackPanel body = new() { Margin = new Thickness(24, 12, 24, 12) };
    readonly StackPanel steps = new() { Width = 166, Margin = new Thickness(12) };
    readonly TextBlock message = new() { Margin = new Thickness(0, 10, 0, 4), Foreground = Brushes.Goldenrod };
    readonly Button next = new() { Content = "下一步" };
    readonly Button back = new() { Content = "上一步" };
    readonly DispatcherTimer previewTimer = new() { Interval = TimeSpan.FromMilliseconds(150) };
    VideoSource? camera, screen;
    AudioSource? mic;
    Image camImage = new(), screenImage = new();
    ProgressBar meter = new() { Maximum = 60, Height = 8 };
    int page;
    bool working, closing, passed;
    ImageSource? lastCam, lastScreen;
    readonly bool settings;
    JsonElement devices;
    internal SetupWindow(LocalState state, Action<string> warn)
    {
        this.state = state; settings = state.Onboarded;
        Title = "庄Sir线上采访助手 · 引导与设置"; Width = 800; Height = 560; WindowStartupLocation = WindowStartupLocation.CenterScreen;
        PrivateWindow.Setup(this, text => { warn(text); message.Text = text; });
        var root = new DockPanel(); Content = root;
        var header = new DockPanel { Background = new SolidColorBrush(Color.FromRgb(23,24,28)) };
        var close = Button("关闭", () => Close()); DockPanel.SetDock(close, Dock.Right); header.Children.Add(close);
        var title = new TextBlock { Text = Title, Margin = new Thickness(16), FontWeight = FontWeights.Bold }; title.MouseLeftButtonDown += (_, _) => DragMove(); header.Children.Add(title);
        DockPanel.SetDock(header, Dock.Top); root.Children.Add(header);
        DockPanel.SetDock(steps, Dock.Left); root.Children.Add(steps);
        var main = new DockPanel(); root.Children.Add(main);
        var footer = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(12) };
        footer.Children.Add(back); footer.Children.Add(next); DockPanel.SetDock(footer, Dock.Bottom); main.Children.Add(footer);
        main.Children.Add(new ScrollViewer { Content = body, VerticalScrollBarVisibility = ScrollBarVisibility.Auto });
        back.Click += async (_, _) => { if (!working) { await StopPreview(); page--; Draw(); } };
        next.Click += async (_, _) => { if (working) return; await StopPreview(); if (page == 5) { state.Onboarded = true; if (Save()) Close(); return; } page++; Draw(); };
        previewTimer.Tick += (_, _) => {
            UpdateImage(camera, camImage); UpdateImage(screen, screenImage);
            meter.Value = mic == null ? 0 : Math.Clamp(mic.LevelDb + 60, 0, 60);
        };
        Closing += async (_, e) => { if (closing) return; e.Cancel = true; if (working) { message.Text = "请等待当前检查完成。"; return; } closing = true; await StopPreview(); await Dispatcher.Yield(); Close(); };
        page = settings ? 2 : 0; Draw();
    }
    static Button Button(string text, Action action) { var b = new Button { Content = text }; b.Click += (_, _) => action(); return b; }
    void Text(string text, double size = 13) => body.Children.Add(new TextBlock { Text = text, FontSize = size, Margin = new Thickness(0, 6, 0, 6) });
    bool Save() { try { state.Save(); return true; } catch (Exception ex) { message.Text = "设置未保存：" + ex.Message; return false; } }
    void Draw()
    {
        body.Children.Clear(); steps.Children.Clear(); message.Text = ""; back.IsEnabled = page > 0; next.IsEnabled = true;
        string[] names = ["欢迎", "系统权限", "选择设备", "自检", "输入邀请码 · 稍后", "欢迎与就绪 · 稍后"];
        for (int i = 0; i < names.Length; i++) steps.Children.Add(new TextBlock { Text = $"{i + 1}  {names[i]}", Foreground = i == page ? Brushes.White : Brushes.Gray, FontWeight = i == page ? FontWeights.Bold : FontWeights.Normal, Margin = new Thickness(8, 12, 0, 12) });
        Text(names[page], 22); next.Content = page == 5 ? "直接本地使用" : "下一步";
        if (page == 0) {
            Text("不联网，也能录好这次采访。", 18);
            Text("① 不录制时，摄像头、麦克风、屏幕不会被访问。设备预览和自检期间会临时访问，离开页面立即关闭。");
            Text("② 开始录制前一定有 3 秒倒计时，录制中一定有红点。");
            Text("③ 录制文件只存在您的电脑上；未来上传会显示进度，并可随时暂停。本版本没有上传功能。");
        }
        if (page == 1) {
            Text("检查摄像头与麦克风访问权限；如未允许，请打开设置，允许桌面应用访问。");
            body.Children.Add(Button("检查权限", async () => await Permissions()));
            body.Children.Add(Button("打开摄像头设置", () => Open("ms-settings:privacy-webcam")));
            body.Children.Add(Button("打开麦克风设置", () => Open("ms-settings:privacy-microphone")));
        }
        if (page == 2) { next.IsEnabled = false; _ = Devices(); }
        if (page == 3) {
            next.IsEnabled = passed = false;
            Text("试录 3 秒，检查两路画面、声音和编码器。只录屏幕时，可保留摄像头缺失提示继续。");
            AddImages();
            body.Children.Add(Button("运行 / 重新自检", async () => await Preflight()));
        }
        if (page == 4) Text("输入邀请码（M4 开放）\n稍后可连接导演；目前所有操作仅在本机进行。");
        if (page == 5) Text("已准备好本地录制。\n点击「直接本地使用」，在角落浮窗开始或停止录制。\n房间欢迎卡稍后开放。");
        body.Children.Add(message);
    }
    async Task Permissions()
    {
        working = true; next.IsEnabled = false;
        try {
            var results = new List<string>();
            foreach (var mode in new[] { StreamingCaptureMode.Video, StreamingCaptureMode.Audio }) {
                using var capture = new MediaCapture();
                try { await capture.InitializeAsync(new MediaCaptureInitializationSettings { StreamingCaptureMode = mode }); results.Add((mode == StreamingCaptureMode.Video ? "摄像头" : "麦克风") + "：✓ 可访问"); }
                catch (UnauthorizedAccessException) { results.Add((mode == StreamingCaptureMode.Video ? "摄像头" : "麦克风") + "：未授权，请打开设置允许访问。"); }
                catch (Exception) { results.Add((mode == StreamingCaptureMode.Video ? "摄像头" : "麦克风") + "：未找到可用设备或设备被占用，请连接设备并关闭其他软件后重试。"); }
            }
            message.Text = string.Join("\n", results);
        } finally { working = false; next.IsEnabled = true; }
    }
    async Task Devices()
    {
        working = true;
        try {
            devices = await RecorderBridge.Query(["devices", "--json"]);
            body.Children.Remove(message);
            Select("摄像头", "cameras", state.Camera, v => state.Camera = v);
            Select("话筒", "mics", state.Mic, v => state.Mic = v);
            Select("显示器（多屏请明确选择）", "displays", state.Display, v => state.Display = v);
            Choice("画质", ["recommended", "high", "saver"], ["推荐", "高画质", "省空间"], state.Quality, v => state.Quality = v);
            Choice("录制范围", ["cam,screen", "cam", "screen"], ["两路", "仅摄像头", "仅屏幕"], state.Tracks, v => state.Tracks = v);
            var output = new TextBox { Text = state.Output, Margin = new Thickness(0, 6, 0, 6) };
            Text("输出目录"); body.Children.Add(output);
            output.LostFocus += (_, _) => { try { state.Output = Path.GetFullPath(output.Text); Save(); } catch (Exception ex) { message.Text = ex.Message; next.IsEnabled = false; } };
            Text("预览会临时访问设备，离开此页停止访问。"); AddImages();
            body.Children.Add(Button("开始 / 刷新预览", async () => await Preview()));
            if (settings) body.Children.Add(Button("重新引导", async () => { if (working) return; await StopPreview(); page = 0; Draw(); }));
            body.Children.Add(message);
            next.IsEnabled = devices.GetProperty("displays").GetArrayLength() <= 1 || state.Display != null;
        } catch (Exception ex) { message.Text = ex.Message; }
        finally { working = false; }
    }
    void Select(string label, string key, string? selected, Action<string?> set)
    {
        Text(label);
        var entries = devices.GetProperty(key).EnumerateArray().Select(x => new KeyValuePair<string, string>(x.GetProperty("id").GetString()!, x.GetProperty("name").GetString()!)).ToArray();
        var combo = new ComboBox { ItemsSource = entries, DisplayMemberPath = "Value", SelectedValuePath = "Key" };
        combo.SelectedValue = selected;
        if (combo.SelectedIndex < 0 && entries.Length > 0 && (key != "displays" || entries.Length == 1)) combo.SelectedIndex = 0;
        set(combo.SelectedValue as string);
        combo.SelectionChanged += async (_, _) => { await StopPreview(); set(combo.SelectedValue as string); passed = false; Save(); if (key == "displays") next.IsEnabled = combo.SelectedIndex >= 0; };
        body.Children.Add(combo);
    }
    void Choice(string label, string[] keys, string[] names, string current, Action<string> set)
    {
        Text(label); var combo = new ComboBox { ItemsSource = names, SelectedIndex = Math.Max(0, Array.IndexOf(keys, current)) };
        combo.SelectionChanged += async (_, _) => { await StopPreview(); set(keys[combo.SelectedIndex]); passed = false; Save(); }; body.Children.Add(combo);
    }
    void AddImages()
    {
        var row = new System.Windows.Controls.Primitives.UniformGrid { Columns = 2 };
        camImage = new Image { Width = 240, Height = 125, Stretch = Stretch.Uniform };
        screenImage = new Image { Width = 240, Height = 125, Stretch = Stretch.Uniform };
        camImage.Source = lastCam; screenImage.Source = lastScreen;
        row.Children.Add(camImage); row.Children.Add(screenImage); body.Children.Add(row);
        Text(page == 3 ? "A · 摄像头 / B · 屏幕（设备页预览留帧，非试录截图）" : "A · 摄像头                             B · 屏幕");
        meter = new ProgressBar { Height = 6, Maximum = 60, Foreground = Brushes.MediumSeaGreen }; body.Children.Add(meter);
    }
    async Task Preview()
    {
        if (working) return; working = true; next.IsEnabled = false;
        await StopPreview();
        var errors = new List<string>();
        try {
            if (state.Tracks.Contains("cam")) {
                try { if (state.Camera == null) throw new IOException("CAM_NOT_FOUND：请连接摄像头后重试。"); camera = await VideoSource.Camera(state.Camera, "摄像头", state.Quality); } catch (Exception ex) { errors.Add(ex.Message); }
                try { mic = new AudioSource(false, state.Mic); mic.Begin(Stopwatch.GetTimestamp()); mic.Start(); } catch (Exception ex) { mic?.Dispose(); mic = null; errors.Add(ex.Message); }
            }
            if (state.Tracks.Contains("screen")) { try { if (state.Display == null) throw new IOException("请选择显示器。"); screen = await VideoSource.Screen((nint)long.Parse(state.Display)); } catch (Exception ex) { errors.Add(ex.Message); } }
            previewTimer.Start(); message.Text = errors.Count == 0 ? "预览中；请确认画面并对话筒说话。" : string.Join("\n", errors);
        } finally { working = false; next.IsEnabled = state.Display != null || state.Tracks == "cam"; }
    }
    static void UpdateImage(VideoSource? source, Image image)
    {
        if (source?.Latest is not { } bytes) return;
        image.Source = BitmapSource.Create(source.Width, source.Height, 96, 96, PixelFormats.Bgra32, null, bytes, source.Width * 4);
    }
    async Task StopPreview()
    {
        lastCam = camImage.Source; lastScreen = screenImage.Source;
        previewTimer.Stop();
        var cam = camera; camera = null; var scr = screen; screen = null;
        mic?.Dispose(); mic = null;
        if (cam != null) await cam.DisposeAsync(); if (scr != null) await scr.DisposeAsync();
    }
    async Task Preflight()
    {
        if (working) return; working = true; next.IsEnabled = false; message.Text = "正在试录，请稍候…";
        try {
            await StopPreview();
            Directory.CreateDirectory(state.Output);
            string probe = Path.Combine(state.Output, ".write-test-" + Guid.NewGuid().ToString("N"));
            using (File.Create(probe)) { } File.Delete(probe);
            var result = await RecorderBridge.Query(new[] { "preflight", "--json" }.Concat(state.Selection()));
            var errors = result.GetProperty("errors").EnumerateArray().Select(x => x.GetString()!).ToArray();
            bool cam = result.GetProperty("cam").GetProperty("ok").GetBoolean();
            bool scr = result.GetProperty("screen").GetProperty("ok").GetBoolean();
            long free = new DriveInfo(Path.GetPathRoot(state.Output)!).AvailableFreeSpace;
            passed = (!state.Tracks.Contains("cam") || cam) && (!state.Tracks.Contains("screen") || scr) && free >= 2L * 1073741824;
            message.Text = $"摄像头：{(cam ? "✓" : "未通过")}    屏幕：{(scr ? "✓" : "未通过")}\n系统声音：{result.GetProperty("systemAudio").GetProperty("ok")}\n编码器：{result.GetProperty("encoder").GetString()}\n输出目录：可写 ✓    剩余 {free / 1073741824d:F1} GB\n" + string.Join("\n", errors) + (passed ? "\n所选范围已通过，可以继续。" : "\n请按提示处理，或返回修改录制范围，再自检。");
            if (cam && result.GetProperty("cam").TryGetProperty("levelDb", out var level)) meter.Value = Math.Clamp(level.GetDouble() + 60, 0, 60);
            Save();
        } catch (Exception ex) { passed = false; message.Text = "自检失败：" + ex.Message; }
        finally { working = false; next.IsEnabled = passed; }
    }
    void Open(string uri) { try { Process.Start(new ProcessStartInfo(uri) { UseShellExecute = true }); } catch (Exception ex) { message.Text = ex.Message; } }
}
