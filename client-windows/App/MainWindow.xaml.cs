using ZsirRecorder.Shared;

namespace ZsirRecorder.App;

public partial class MainWindow : System.Windows.Window
{
    public MainWindow()
    {
        InitializeComponent();
        Title = $"庄Sir线上采访助手 {VersionInfo.Version}";
    }
}
