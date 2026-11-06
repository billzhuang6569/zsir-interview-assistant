using System.Runtime.InteropServices;

namespace ZSirCapture;

internal static class CaptureVisibility
{
    internal static bool Apply(IntPtr window, bool stealth) => SetWindowDisplayAffinity(window, stealth ? 0x11u : 0u);

    [DllImport("user32.dll", SetLastError = true)]
    static extern bool SetWindowDisplayAffinity(IntPtr window, uint affinity);
}
