using System.Windows;

namespace ZsirRecorder.App;
public partial class App : Application
{
    Mutex? singleton;
    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        singleton = new Mutex(true, "Local\\ZsirInterviewApp", out bool first);
        if (!first) { Shutdown(); return; }
        var window = new MainWindow();
        MainWindow = window;
        window.Show();
    }
    protected override void OnExit(ExitEventArgs e) { singleton?.Dispose(); base.OnExit(e); }
}
