using System.Windows;

namespace ZSirCapture;

internal static class Program
{
    [STAThread]
    static void Main(string[] args)
    {
        AppDomain.CurrentDomain.UnhandledException += (_, e) => LogCrash(e.ExceptionObject);
        if (args.Length == 1 && args[0] == "--check-settings") {
            if (RecordingOptions.BitRate("standard", 1920, 1080) != 12_000_000 ||
                RecordingOptions.BitRate("high", 3840, 2160) != 72_000_000 ||
                RecordingOptions.BitRate("compact", 720, 1280) != 6_000_000 ||
                RecordingOptions.BitRate("standard", 3841, 2161) != 48_000_000 ||
                RecordingOptions.BitRate("invalid", 1920, 1080) != 12_000_000) throw new Exception("Quality mapping failed");
            bool rejected = false;
            try { RecordingOptions.BitRate("high", 0, 1080); } catch (ArgumentOutOfRangeException) { rejected = true; }
            if (!rejected) throw new Exception("Invalid dimensions accepted");
            SmokeTest.CheckCameraParsers();
            return;
        }
        using var mutex = new Mutex(true, "Local\\ZSirCapture.Windows", out bool first);
        if (!first) { MessageBox.Show("采访录制助手已经运行，请使用现有小窗。", "庄Sir采访录制助手"); return; }
        string tools = Path.Combine(AppContext.BaseDirectory, "tools");
        if (args.Length == 2 && args[0] == "--device-check")
        {
            try { Task.Run(() => DeviceCheck.RunAsync(tools, args[1])).GetAwaiter().GetResult(); }
            catch (Exception ex) { MessageBox.Show(ex.Message, "设备诊断未完成"); Environment.ExitCode = 1; }
            return;
        }
        CameraDevices.SmokeTestEnabled = args.Length == 2 && args[0] == "--smoke-test";
        var app = new Application { ShutdownMode = ShutdownMode.OnMainWindowClose };
        app.DispatcherUnhandledException += (_, e) =>
        {
            string path = LogCrash(e.Exception);
            e.Handled = false;
            if (!args.Contains("--smoke-test")) MessageBox.Show($"庄Sir采访录制助手遇到错误，详情已写入 {path}", "庄Sir采访录制助手", MessageBoxButton.OK, MessageBoxImage.Error);
        };
        app.Resources.MergedDictionaries.Add(new ResourceDictionary { Source = new Uri("/ZSirCapture.Windows;component/Theme.xaml", UriKind.Relative) });
        var form = new MainWindow(tools, args.Length == 2 && args[0] == "--smoke-test");
        app.MainWindow = form;
        if (args.Length == 2 && args[0] == "--smoke-test")
        {
            form.Controller.Automation = true;
            EventHandler? startSmoke = null;
            startSmoke = async (_, _) => { form.ContentRendered -= startSmoke; await SmokeTest.RunAsync(form, tools, args[1]); };
            form.ContentRendered += startSmoke;
        }
        app.Run(form);
    }
    static string LogCrash(object exception)
    {
        string path = @"%LOCALAPPDATA%\ZSirCapture\crash.log";
        try
        {
            path = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "ZSirCapture", "crash.log");
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            File.AppendAllText(path, $"{DateTimeOffset.Now:O} version {typeof(Program).Assembly.GetName().Version}{Environment.NewLine}{exception}{Environment.NewLine}");
        }
        catch { }
        return path;
    }
}
