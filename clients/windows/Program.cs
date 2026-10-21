namespace ZSirCapture;

internal static class Program
{
    [STAThread]
    static void Main(string[] args)
    {
        ApplicationConfiguration.Initialize();
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
