using System.ComponentModel;
using System.Windows;
using System.Windows.Media.Imaging;

namespace ZSirCapture;

internal sealed class MainViewModel : INotifyPropertyChanged
{
    public event PropertyChangedEventHandler? PropertyChanged;
    string phase = "准备就绪", detail = "桌面 + 系统声音 · 素材仅保存在本机", timecode = "00:00:00", mode = "desktop", previewState = "等待预览", cameraMessage = "等待预览";
    bool recording, busy, stealth = true, previewVisible = true, hasTimecode, cameraAvailable = true, canChange = true, canStart;
    BitmapSource? cameraImage, desktopImage;
    double micLevel;
    public string Phase { get => phase; internal set { phase = value; Changed(); } }
    public string Detail { get => detail; internal set { detail = value; Changed(); } }
    public string Timecode { get => timecode; internal set { timecode = value; Changed(); } }
    public string Mode { get => mode; internal set { mode = value; Changed(); } }
    public string PreviewState { get => previewState; internal set { previewState = value; Changed(); } }
    public string CameraMessage { get => cameraMessage; internal set { cameraMessage = value; Changed(); } }
    public bool IsRecording { get => recording; internal set { recording = value; Changed(); } }
    public bool IsBusy { get => busy; internal set { busy = value; Changed(); } }
    public bool Stealth { get => stealth; internal set { stealth = value; Changed(); } }
    public bool PreviewVisible { get => previewVisible; internal set { previewVisible = value; Changed(); } }
    public bool HasTimecode { get => hasTimecode; internal set { hasTimecode = value; Changed(); } }
    public bool CameraAvailable { get => cameraAvailable; internal set { cameraAvailable = value; Changed(); } }
    public bool CanChange { get => canChange; internal set { canChange = value; Changed(); } }
    public bool CanStart { get => canStart; internal set { canStart = value; Changed(); } }
    public BitmapSource? CameraImage { get => cameraImage; internal set { cameraImage = value; Changed(); } }
    public BitmapSource? DesktopImage { get => desktopImage; internal set { desktopImage = value; Changed(); } }
    public double MicLevel { get => micLevel; internal set { micLevel = value; Changed(); } }
    public bool CameraRetry => CameraMessage == "未检测到摄像头";
    public bool IncludesCamera => Mode is "camera" or "both";
    public bool IncludesDesktop => Mode is "desktop" or "both";
    public bool CameraSelected => Mode == "camera";
    public bool DesktopSelected => Mode == "desktop";
    public bool BothSelected => Mode == "both";
    public GridLength CameraColumn => new(IncludesCamera ? 1 : 0, GridUnitType.Star);
    public GridLength DesktopColumn => new(IncludesDesktop ? 1 : 0, GridUnitType.Star);
    public GridLength TileGap => new(Mode == "both" ? 8 : 0);
    public double PreviewRatio => Mode == "both" ? 1.6 : 16.0 / 9;
    public string Disclosure => PreviewVisible ? "收起预览" : "展开预览";
    public string Chevron => PreviewVisible ? "\uE70D" : "\uE76C";
    public string Chip => Stealth ? "本地保存" : "远程可见";
    public string ClockHint => IsRecording ? "15 秒无操作后收起" : "本次录制时长";
    public string ActionText => IsRecording ? "停止并保存" : IsBusy ? "正在处理…" : "开始录制";
    public string ActionGlyph => IsRecording ? "\uE71A" : "\uE7C8";
    public bool ActionEnabled => IsRecording || CanStart;
    // All derived bindings depend on a small shared state; publish them in one notification.
    void Changed() => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(""));
}
