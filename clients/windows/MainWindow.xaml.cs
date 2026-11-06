using System.ComponentModel;
using System.Diagnostics;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Threading;

namespace ZSirCapture;

public partial class MainWindow : Window, IRecordingHost
{
    internal RecordingController Controller { get; }
    internal EdgeWindow Edge { get; }
    SettingsWindow? settings;
    readonly TrayMenu tray;
    HwndSource? source;
    bool animating, placed;
    internal IntPtr Handle => new WindowInteropHelper(this).Handle;
    bool IRecordingHost.IsEnabled => IsEnabled && settings == null;
    bool IRecordingHost.IsMinimized => WindowState == WindowState.Minimized;
    bool IRecordingHost.IsDocked => Edge?.IsDocked == true;
    internal MainWindow(string tools, bool automation = false, bool layoutOnly = false)
    {
        InitializeComponent();
        Controller = new RecordingController(tools, this, Dispatcher, automation, layoutOnly);
        DataContext = Controller.ViewModel;
        Edge = new EdgeWindow(this);
        tray = new TrayMenu(Controller, () => Reveal(true), Close);
        SourceInitialized += (_, _) =>
        {
            if (WindowEffects.Apply(this, mica: true)) { Root.Background = new SolidColorBrush(Color.FromArgb(217, 32, 34, 40)); }
            source = HwndSource.FromHwnd(Handle); source?.AddHook(WindowMessage);
            new WindowInteropHelper(Edge).EnsureHandle();
            Controller.ApplyCaptureVisibility();
        };
        Loaded += (_, _) => { if (!placed) { PlaceInitial(); placed = true; } UpdateDesktopCaption(); Controller.VisibilityChanged(); };
        IsVisibleChanged += (_, _) => Controller.VisibilityChanged();
        StateChanged += (_, _) => Controller.VisibilityChanged();
        IsEnabledChanged += (_, _) => Controller.VisibilityChanged();
        PreviewMouseMove += (_, _) => Edge.ResetIdle();
        PreviewMouseDown += (_, _) => Edge.ResetIdle();
        PreviewMouseWheel += (_, _) => Edge.ResetIdle();
        PreviewKeyDown += (_, _) => Edge.ResetIdle();
        Closing += OnClosing;
        Closed += (_, _) => { source?.RemoveHook(WindowMessage); tray.Dispose(); Edge.Close(); Controller.Dispose(); };
        Root.SizeChanged += AnimateHeight;
    }
    void PlaceInitial()
    {
        var area = Screen.FromHandle(Handle).WorkingArea;
        var transform = source?.CompositionTarget?.TransformFromDevice ?? Matrix.Identity;
        var topRight = transform.Transform(new Point(area.Right, area.Top));
        Left = topRight.X - ActualWidth - 16; Top = topRight.Y + 16;
    }
    void DragEmptyArea(object sender, MouseButtonEventArgs e)
    {
        for (DependencyObject? current = e.OriginalSource as DependencyObject; current != null && current != Root; current = current is Visual ? VisualTreeHelper.GetParent(current) : LogicalTreeHelper.GetParent(current))
            if (current is ButtonBase or ComboBox) return;
        if (e.ButtonState == MouseButtonState.Pressed) DragMove();
    }
    void AnimateHeight(object sender, SizeChangedEventArgs e)
    {
        if (!IsLoaded || Controller.Automation || !SystemParameters.ClientAreaAnimation || animating || !e.HeightChanged || e.PreviousSize.Height <= 0) return;
        animating = true;
        double oldHeight = e.PreviousSize.Height;
        Dispatcher.BeginInvoke(DispatcherPriority.Loaded, new Action(() =>
        {
            double target = Root.DesiredSize.Height;
            if (Math.Abs(target - oldHeight) < .5) { animating = false; return; }
            SizeToContent = SizeToContent.Manual; Height = target;
            var animation = new DoubleAnimation(oldHeight, target, TimeSpan.FromMilliseconds(150)) { EasingFunction = new CubicEase { EasingMode = EasingMode.EaseOut } };
            animation.Completed += (_, _) => { BeginAnimation(HeightProperty, null); SizeToContent = SizeToContent.Height; animating = false; };
            BeginAnimation(HeightProperty, animation);
        }));
    }
    void CloseClick(object sender, RoutedEventArgs e) => Close();
    async void RecordClick(object sender, RoutedEventArgs e) { if (Controller.IsRecording) await Controller.StopRecordingAsync(); else if (!Controller.IsBusy) await Controller.StartRecordingAsync(); }
    void ModeClick(object sender, RoutedEventArgs e) { Controller.SetMode((string)((RadioButton)sender).Tag); UpdateDesktopCaption(); }
    void TogglePreviewClick(object sender, RoutedEventArgs e) => Controller.TogglePreview();
    void FolderClick(object sender, RoutedEventArgs e) => Controller.OpenMaterialFolder();
    void RetryCamera(object sender, RoutedEventArgs e) => Controller.DetectDevices();
    void SettingsClick(object sender, RoutedEventArgs e)
    {
        if (!Controller.CanChangeStealth) return;
        var dialog = CreateSettingsWindow(); dialog.ShowDialog(); Controller.VisibilityChanged(); UpdateDesktopCaption();
    }
    internal SettingsWindow CreateSettingsWindow()
    {
        Controller.DetectDevices(); Controller.SetSettingsOpen(true);
        var dialog = new SettingsWindow(this, Controller); settings = dialog;
        dialog.SourceInitialized += (_, _) => Controller.ApplyCaptureVisibility();
        dialog.Closed += (_, _) => { settings = null; Controller.SetSettingsOpen(false); Controller.ApplyCaptureVisibility(); UpdateDesktopCaption(); };
        return dialog;
    }
    void UpdateDesktopCaption() => DesktopTile.Caption = Controller.Options.SystemAudio ? "桌面 · 系统声音" : "桌面 · 无声音";
    bool IRecordingHost.ApplyCaptureVisibility(bool stealth)
    {
        bool result = Handle != IntPtr.Zero && CaptureVisibility.Apply(Handle, stealth);
        Edge.ApplyCaptureVisibility(); result &= Edge.Excluded;
        if (settings != null && settings.Handle != IntPtr.Zero) result &= CaptureVisibility.Apply(settings.Handle, stealth);
        return result;
    }
    bool IRecordingHost.ConfirmVisibleRecording() => MessageBox.Show(this, "已关闭「在录屏里隐身」：小窗会出现在本次桌面录制画面中（15 秒无操作后收起为边缘红点）。继续录制？", "录制提示", MessageBoxButton.OKCancel, MessageBoxImage.Warning) == MessageBoxResult.OK;
    void IRecordingHost.ShowError(Exception ex)
    {
        if (!IsLoaded)
        {
            RoutedEventHandler? show = null;
            show = (_, _) => { Loaded -= show; ((IRecordingHost)this).ShowError(ex); };
            Loaded += show; return;
        }
        if (ex.Message.Contains("Windows 隐私设置禁止"))
        {
            if (MessageBox.Show(this, ex.Message + "。打开 Windows 隐私设置？", "录制提示", MessageBoxButton.YesNo, MessageBoxImage.Warning) == MessageBoxResult.Yes)
                Process.Start(new ProcessStartInfo("ms-settings:privacy-" + (ex.Message.Contains("摄像头") ? "webcam" : "microphone")) { UseShellExecute = true });
        }
        else MessageBox.Show(this, ex.Message, "录制提示", MessageBoxButton.OK, MessageBoxImage.Warning);
    }
    void IRecordingHost.Notify(string message, string title) { if (!Controller.Automation) MessageBox.Show(settings ?? (Window)this, message, title); }
    public void Reveal(bool activate)
    {
        Edge?.Reveal(activate);
        if (!IsLoaded) return;
        Show(); if (WindowState == WindowState.Minimized) WindowState = WindowState.Normal;
        if (activate) Activate();
    }
    void IRecordingHost.ResetIdle() => Edge.ResetIdle();
    void IRecordingHost.TickEdge() => Edge.Tick();
    void OnClosing(object? sender, CancelEventArgs e)
    {
        if (!Controller.IsBusy) return;
        e.Cancel = true;
        if (!Controller.Automation) MessageBox.Show(this, "请先停止录制并等待保存完成，再关闭窗口。", "正在处理素材");
    }
    IntPtr WindowMessage(IntPtr hwnd, int message, IntPtr wParam, IntPtr lParam, ref bool handled) { Controller.HandleSystemMessage(message, wParam); return IntPtr.Zero; }
    internal void ScaleForLayoutTest(double factor)
    {
        Root.LayoutTransform = new ScaleTransform(factor, factor); Width = 336 * factor; UpdateLayout();
    }
    internal void FitContent() => UpdateLayout();
}
