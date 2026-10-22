namespace ZSirCapture;

internal static class Program
{
    [STAThread]
    static void Main(string[] args)
    {
        ApplicationConfiguration.Initialize();
        if (args.Length == 1 && args[0] == "--check-settings") {
            if (RecordingOptions.BitRate("standard", 1920, 1080) != 12_000_000 ||
                RecordingOptions.BitRate("high", 3840, 2160) != 72_000_000 ||
                RecordingOptions.BitRate("compact", 720, 1280) != 6_000_000 ||
                RecordingOptions.BitRate("standard", 3841, 2161) != 48_000_000 ||
                RecordingOptions.BitRate("invalid", 1920, 1080) != 12_000_000) throw new Exception("Quality mapping failed");
            bool rejected = false;
            try { RecordingOptions.BitRate("high", 0, 1080); } catch (ArgumentOutOfRangeException) { rejected = true; }
            if (!rejected) throw new Exception("Invalid dimensions accepted");
            return;
        }
        using var mutex = new Mutex(true, "Local\\ZSirCapture.Windows", out bool first);
        if (!first) { MessageBox.Show("采访录制助手已经运行，请使用现有小窗。", "庄Sir采访录制助手"); return; }
        string tools = Path.Combine(AppContext.BaseDirectory, "tools");
        var form = new MainForm(tools, args.Length == 2 && args[0] == "--smoke-test");
        if (args.Length == 2 && args[0] == "--smoke-test")
        {
            form.Automation = true;
            form.Shown += async (_, _) => await SmokeTest.RunAsync(form, tools, args[1]);
        }
        Application.Run(form);
    }
}
