using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Threading;

namespace ZSirCapture;

public partial class EdgeWindow : Window
{
    readonly MainWindow main;
    readonly DispatcherTimer animation;
    double lastInteraction;
    bool breathing;
    internal bool IsDocked { get; private set; }
    internal bool Excluded { get; private set; }
    internal IntPtr Handle => new WindowInteropHelper(this).Handle;
    static double Now => Stopwatch.GetTimestamp() / (double)Stopwatch.Frequency;
    internal EdgeWindow(MainWindow main)
    {
        InitializeComponent(); this.main = main;
        SourceInitialized += (_, _) =>
        {
            SetWindowLongPtr(Handle, -20, new IntPtr(GetWindowLongPtr(Handle, -20).ToInt64() | 0x08000000));
            ApplyCaptureVisibility();
        };
        animation = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(80) };
        animation.Tick += (_, _) => { Place(); UpdateMotion(); };
        Closed += (_, _) => animation.Stop(); ResetIdle();
    }
    internal void ApplyCaptureVisibility() { if (Handle != IntPtr.Zero) Excluded = CaptureVisibility.Apply(Handle, main.Controller.StealthInCapture); }
    internal void ResetIdle() => lastInteraction = Now;
    internal void Tick()
    {
        var controller = main.Controller;
        if (!controller.IsRecording || controller.LastError != null || !main.IsEnabled)
        { if (IsDocked) Reveal(false); ResetIdle(); return; }
        RevealButton.ToolTip = $"正在录制 {controller.Timecode} · 点击展开";
        AutomationProperties.SetName(RevealButton, $"正在录制 {controller.Timecode}，展开录制窗口");
        if (!IsDocked && Now - lastInteraction >= 15 && main.WindowState != WindowState.Minimized)
        {
            if (controller.StealthInCapture && !Excluded) { ResetIdle(); return; }
            Place(); IsDocked = true; Show(); main.Hide(); animation.Start(); UpdateMotion();
        }
    }
    void Place()
    {
        var area = ScreenGeometry.ToDip(Screen.FromHandle(main.Handle).WorkingArea, ScreenGeometry.ScaleForWindow(Handle));
        Left = area.Right - Width; Top = Math.Clamp(main.Top + main.ActualHeight / 2 - Height / 2, area.Top, area.Bottom - Height);
    }
    void UpdateMotion()
    {
        bool enabled = SystemParameters.ClientAreaAnimation;
        if (enabled == breathing) return;
        RevealButton.ApplyTemplate();
        if (RevealButton.Template.FindName("Dot", RevealButton) is not UIElement dot) return;
        breathing = enabled;
        dot.BeginAnimation(OpacityProperty, enabled ? new DoubleAnimation(.5, 1, TimeSpan.FromMilliseconds(850)) { AutoReverse = true, RepeatBehavior = RepeatBehavior.Forever } : null);
    }
    void RevealClick(object sender, RoutedEventArgs e) => Reveal(true);
    internal void Reveal(bool activate)
    {
        ResetIdle(); if (!IsDocked) return;
        IsDocked = false; animation.Stop(); Hide();
        var position = ScreenGeometry.Clamp(main.Left, main.Top, main.ActualWidth, main.ActualHeight, ScreenGeometry.WorkingArea(main.Handle));
        main.Left = position.X; main.Top = position.Y;
        main.Show(); if (activate) main.Activate();
    }
    internal IDisposable ScaleForLayoutTest(double factor) => SmokeTest.ScaleForLayoutTest(this, factor);
    [DllImport("user32.dll", EntryPoint = "GetWindowLongPtrW")] static extern IntPtr GetWindowLongPtr(IntPtr window, int index);
    [DllImport("user32.dll", EntryPoint = "SetWindowLongPtrW")] static extern IntPtr SetWindowLongPtr(IntPtr window, int index, IntPtr value);
}
