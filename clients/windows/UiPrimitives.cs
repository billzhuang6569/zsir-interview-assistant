using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Interop;
using System.Windows.Media;

namespace ZSirCapture;

public sealed class AspectBorder : Border
{
    public static readonly DependencyProperty RatioProperty = DependencyProperty.Register(nameof(Ratio), typeof(double), typeof(AspectBorder), new FrameworkPropertyMetadata(16.0 / 9, FrameworkPropertyMetadataOptions.AffectsMeasure));
    public double Ratio { get => (double)GetValue(RatioProperty); set => SetValue(RatioProperty, value); }
    protected override Size MeasureOverride(Size availableSize)
    {
        double width = double.IsFinite(availableSize.Width) ? availableSize.Width : 160;
        var size = new Size(width, width / Ratio);
        base.MeasureOverride(size); return size;
    }
    protected override Size ArrangeOverride(Size finalSize)
    {
        var result = base.ArrangeOverride(finalSize);
        Clip = new RectangleGeometry(new Rect(finalSize), CornerRadius.TopLeft, CornerRadius.TopLeft);
        return result;
    }
}

internal static class ScreenGeometry
{
    internal static double ScaleForWindow(IntPtr handle)
    {
        uint dpi = GetDpiForWindow(handle);
        return dpi == 0 ? 1.0 : dpi / 96.0;
    }
    internal static Rect ToDip(Rectangle area, double scale) => new(area.Left / scale, area.Top / scale, area.Width / scale, area.Height / scale);
    internal static Rect WorkingArea(IntPtr handle) => ToDip(Screen.FromHandle(handle).WorkingArea, ScaleForWindow(handle));
    internal static Point Clamp(double left, double top, double width, double height, Rect area) => new(
        Math.Clamp(left, area.Left, Math.Max(area.Left, area.Right - width)),
        Math.Clamp(top, area.Top, Math.Max(area.Top, area.Bottom - height)));
    [DllImport("user32.dll")] static extern uint GetDpiForWindow(IntPtr window);
}

internal static class WindowEffects
{
    internal static bool Apply(Window window, bool mica = false)
    {
        IntPtr handle = new WindowInteropHelper(window).Handle;
        int yes = 1;
        if (DwmSetWindowAttribute(handle, 20, ref yes, 4) != 0) DwmSetWindowAttribute(handle, 19, ref yes, 4);
        int round = 2; DwmSetWindowAttribute(handle, 33, ref round, 4);
        if (!mica || !OperatingSystem.IsWindowsVersionAtLeast(10, 0, 22621)) return false;
        int backdrop = 2;
        if (DwmSetWindowAttribute(handle, 38, ref backdrop, 4) != 0) return false;
        var margins = new Margins { Left = -1, Right = -1, Top = -1, Bottom = -1 };
        DwmExtendFrameIntoClientArea(handle, ref margins);
        if (HwndSource.FromHwnd(handle) is { CompositionTarget: { } target }) target.BackgroundColor = Colors.Transparent;
        return true;
    }
    [StructLayout(LayoutKind.Sequential)] struct Margins { public int Left, Right, Top, Bottom; }
    [DllImport("dwmapi.dll")] static extern int DwmSetWindowAttribute(IntPtr window, int attribute, ref int value, int size);
    [DllImport("dwmapi.dll")] static extern int DwmExtendFrameIntoClientArea(IntPtr window, ref Margins margins);
}
