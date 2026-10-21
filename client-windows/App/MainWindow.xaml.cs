using System.Diagnostics;
using System.Text.Json;
using System.Windows;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Threading;
using Forms = System.Windows.Forms;

namespace ZsirRecorder.App;
public partial class MainWindow : Window
{
    readonly LocalState state = LocalState.Load();
    readonly Forms.NotifyIcon tray;
    readonly DispatcherTimer timer = new() { Interval = TimeSpan.FromSeconds(1) };
    Process? recorder;
    bool busy, confirming, recovered;
    string? warning;
    SetupWindow? setup;
    internal MainWindow()
    {
        InitializeComponent();
        PrivateWindow.Setup(this, Warn);
        var area = SystemParameters.WorkArea;
        Left = Math.Clamp(state.Left ?? area.Right - Width - 16, SystemParameters.VirtualScreenLeft, SystemParameters.VirtualScreenLeft + SystemParameters.VirtualScreenWidth - Width);
        Top = Math.Clamp(state.Top ?? area.Top + 16, SystemParameters.VirtualScreenTop, SystemParameters.VirtualScreenTop + SystemParameters.VirtualScreenHeight - Height);
        tray = new Forms.NotifyIcon { Icon = System.Drawing.SystemIcons.Application, Visible = true, Text = "庄Sir采访 · 就绪" };
        var menu = new Forms.ContextMenuStrip();
        menu.Items.Add("打开浮窗", null, (_, _) => { Show(); Activate(); });
        menu.Items.Add("设置", null, (_, _) => OpenSettings());
        menu.Items.Add("退出", null, (_, _) => { if (busy || recorder != null) { Warn("请先停止录制；退出不会自动停止录制。"); Show(); return; } setup?.Close(); tray.Dispose(); Application.Current.Shutdown(); });
        tray.ContextMenuStrip = menu;
        tray.DoubleClick += (_, _) => { Show(); Activate(); };
        Loaded += (_, _) => {
            recorder = state.ExistingRecorder();
            if (recorder != null) { recovered = true; Action.IsEnabled = false; Warn("上次录制仍在继续，断开后 60 秒内自动保存。"); }
            else if (state.RecorderPid != 0) Warn("上次录制意外退出，请打开输出目录检查文件。");
            else if (!state.Onboarded) OpenSettings();
        };
        timer.Tick += (_, _) => Tick(); timer.Start();
    }
    void Warn(string text) { warning = text; Status.Text = "⚠ " + text; Status.Foreground = Brushes.Goldenrod; Status.ToolTip = text; }
    void Error(string text) { RecordingLight.Visibility = Visibility.Collapsed; Status.Text = "● RECORDER_CRASHED"; Status.Foreground = Brushes.IndianRed; Status.ToolTip = text; Tracks.Text = text; Tracks.ToolTip = text; tray.Text = "庄Sir采访 · 录制出错"; }
    void Tick()
    {
        try
        {
            long bytes = new DriveInfo(Path.GetPathRoot(Path.GetFullPath(state.Output))!).AvailableFreeSpace;
            Folder.Content = $"剩余 {bytes / 1073741824d:F1} GB";
            if (recorder != null && recovered)
            {
                if (recorder.HasExited) {
                    recorder.Dispose(); recorder = null; recovered = false; Action.IsEnabled = true;
                    using var saved = JsonDocument.Parse(File.ReadAllText(Path.Combine(state.LastSession!, "session.json")));
                    if (saved.RootElement.GetProperty("state").GetString() == "finished") { RecordingLight.Visibility = Visibility.Collapsed; Status.Text = "● 就绪 · 上次录制已保存"; Status.Foreground = Brushes.MediumSeaGreen; Tracks.Text = state.LastSession; }
                    else Error("上次录制进程已退出，请检查文件。");
                    state.RecorderPid = 0; state.Save();
                }
                else if (state.LastSession != null && File.Exists(Path.Combine(state.LastSession, "session.json"))) { using var snapshot = JsonDocument.Parse(File.ReadAllText(Path.Combine(state.LastSession, "session.json"))); Render(snapshot.RootElement); }
            }
            if (bytes < 10L * 1073741824 && recorder != null) Warn("磁盘不足 10 GB，请尽快停止录制。");
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or JsonException or ArgumentException) { Warn("无法读取磁盘或录制状态，请检查输出目录。"); }
    }
    void Render(JsonElement json)
    {
        if (!json.TryGetProperty("t", out var time)) return;
        RecordingLight.Visibility = Visibility.Visible;
        Status.Text = $"录制中 {TimeSpan.FromSeconds(time.GetDouble()):hh\\:mm\\:ss}";
        Status.Foreground = warning == null ? Brushes.IndianRed : Brushes.Goldenrod;
        if (warning != null) { Status.Text += " ⚠"; Status.ToolTip = warning; }
        if (json.TryGetProperty("tracks", out var tracks)) Tracks.Text = string.Join("  ", tracks.EnumerateObject().Select(t => $"{(t.Name == "cam" ? "A" : "B")} {(t.Value.GetProperty("ok").GetBoolean() ? "✓" : "!")} {t.Value.GetProperty("bytes").GetInt64() / 1048576d:F0} MB"));
        if (json.TryGetProperty("levels", out var levels)) {
            MicLevel.Value = levels.TryGetProperty("cam", out var cam) ? Math.Clamp(cam.GetDouble() + 60, 0, 60) : 0;
            SystemLevel.Value = levels.TryGetProperty("screen", out var screen) ? Math.Clamp(screen.GetDouble() + 60, 0, 60) : 0;
        }
        if (recovered) { Tracks.Text = "上次录制仍在继续 · 断开后 60 秒自动保存"; Tracks.ToolTip = state.LastSession; }
        tray.Text = "庄Sir采访 · 录制中";
    }
    async void Toggle(object sender, RoutedEventArgs e)
    {
        if (busy || recovered) return;
        if (recorder != null)
        {
            if (!confirming) { confirming = true; Action.Content = "确认停止"; return; }
            busy = true; Action.IsEnabled = false; Status.Text = "正在保存，请稍候…";
            try { await recorder.StandardInput.WriteLineAsync("stop"); await recorder.StandardInput.FlushAsync(); }
            catch (IOException ex) { Error(ex.Message); }
            return;
        }
        if (!state.Onboarded) { OpenSettings(); return; }
        if (setup != null) { Warn("请先完成并关闭设置窗口。"); setup.Activate(); return; }
        busy = true; warning = null; Action.IsEnabled = false;
        try
        {
            for (int i = 3; i > 0; i--) { Status.Text = $"{i} · 即将开始录制"; Status.Foreground = Brushes.IndianRed; await Task.Delay(1000); }
            string output = Path.Combine(state.Output, DateTime.Now.ToString("yyyyMMdd-HHmmss"));
            Directory.CreateDirectory(output);
            var args = new[] { "capture", "--out", output, "--tracks", state.Tracks, "--quality", state.Quality, "--stdin-control" }.Concat(state.Selection());
            recorder = RecorderBridge.Start(args);
            state.LastSession = output; state.RecorderPid = recorder.Id; state.RecorderStarted = recorder.StartTime.ToUniversalTime().Ticks;
            try { state.Save(); } catch { await recorder.StandardInput.WriteLineAsync("stop"); await recorder.StandardInput.FlushAsync(); await Monitor(recorder, output); throw; }
            Action.Content = "停止录制"; Action.IsEnabled = true; busy = false;
            await Monitor(recorder, output);
        }
        catch (Exception ex) { Error(ex.Message); }
        finally { busy = false; confirming = false; Action.IsEnabled = !recovered; Action.Content = "开始录制"; }
    }
    async Task Monitor(Process process, string output)
    {
        async Task Errors() {
            while (await process.StandardError.ReadLineAsync() is { } line) {
                try { File.AppendAllText(Path.Combine(output, "log.txt"), line + Environment.NewLine); } catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { Warn("日志写入失败，录制仍在继续。"); }
                if (line.StartsWith("ENCODER_FALLBACK:")) Warn("硬件编码不可用，已降低画质继续录制。");
                if (line.StartsWith("POWER_REQUEST_FAILED:")) Warn("无法阻止休眠，请保持电脑唤醒。");
                if (line.StartsWith("DISK_CRITICAL:")) Warn("磁盘不足，正在安全停止录制。");
            }
        }
        var errors = Errors();
        string? captureError = null;
        try {
            while (await process.StandardOutput.ReadLineAsync() is { } line) {
                try {
                    using var json = JsonDocument.Parse(line);
                    if (json.RootElement.TryGetProperty("errors", out var failures)) captureError = string.Join("\n", failures.EnumerateArray().Select(x => x.GetString()));
                    Render(json.RootElement);
                }
                catch (JsonException) { Warn("录制状态暂时不可读，请查看输出目录。"); }
            }
            await process.WaitForExitAsync(); await errors;
            if (process.ExitCode != 0) Error(captureError ?? "录制异常停止，请查看输出目录的 log.txt。");
            else { RecordingLight.Visibility = Visibility.Collapsed; Status.Text = "● 就绪 · 已保存"; Status.Foreground = Brushes.MediumSeaGreen; Tracks.Text = "已保存到 " + output; Tracks.ToolTip = output; tray.Text = "庄Sir采访 · 已保存"; }
            state.RecorderPid = 0; state.Save();
        }
        finally { if (process.HasExited) { process.Dispose(); recorder = null; } }
    }
    void OpenSettings()
    {
        if (busy || recorder != null) { Warn("请先停止录制再修改设置。"); return; }
        if (setup != null) { setup.Activate(); return; }
        setup = new SetupWindow(state, Warn); setup.Closed += (_, _) => { setup = null; if (state.Onboarded && warning == null) { Status.Text = "● 就绪 · 本地使用"; Status.Foreground = Brushes.MediumSeaGreen; } }; setup.Show();
    }
    void Settings(object sender, RoutedEventArgs e) => OpenSettings();
    void HidePanel(object sender, RoutedEventArgs e) { if (recorder == null && !busy) Hide(); }
    void Drag(object sender, MouseButtonEventArgs e) { if (e.OriginalSource is System.Windows.Controls.TextBlock && e.LeftButton == MouseButtonState.Pressed) { DragMove(); state.Left = Left; state.Top = Top; try { state.Save(); } catch (IOException ex) { Warn(ex.Message); } } }
    void OpenFolder(object sender, RoutedEventArgs e) { try { var path = state.LastSession ?? state.Output; Directory.CreateDirectory(path); Process.Start(new ProcessStartInfo("explorer.exe", path) { UseShellExecute = true }); } catch (Exception ex) { Warn(ex.Message); } }
    protected override void OnClosing(System.ComponentModel.CancelEventArgs e) { e.Cancel = true; if (recorder == null && !busy) Hide(); base.OnClosing(e); }
}
