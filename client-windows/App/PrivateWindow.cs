using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;

namespace ZsirRecorder.App;
internal static class PrivateWindow
{
    [DllImport("user32.dll", SetLastError = true)] static extern bool SetWindowDisplayAffinity(nint hwnd, uint affinity);
    internal static void Setup(Window window, Action<string> warn)
    {
        window.ShowInTaskbar = false;
        window.WindowStyle = WindowStyle.None;
        window.ResizeMode = ResizeMode.NoResize;
        window.SourceInitialized += (_, _) => {
            if (!OperatingSystem.IsWindowsVersionAtLeast(10, 0, 19041) || !SetWindowDisplayAffinity(new WindowInteropHelper(window).Handle, 0x11))
                warn("窗口隐藏不可用，请升级 Windows 或避免共享整个屏幕。");
        };
    }
}
