using System.Diagnostics;
using System.Runtime.InteropServices.WindowsRuntime;
using Windows.Devices.Enumeration;
using Windows.Graphics.Capture;
using Windows.Graphics.DirectX;
using Windows.Graphics.DirectX.Direct3D11;
using Windows.Graphics.Imaging;
using Windows.Media.Capture;
using Windows.Media.Capture.Frames;
using Windows.Media.MediaProperties;

namespace ZsirRecorder;

internal sealed class VideoSource : IAsyncDisposable
{
    internal byte[]? Latest;
    internal long FirstTimestamp;
    internal int Width, Height;
    internal string Name = "";
    internal Exception? Error;
    readonly TaskCompletionSource ready = new(TaskCreationOptions.RunContinuationsAsynchronously);
    readonly SemaphoreSlim gate = new(1);
    bool disposed;
    IDirect3DDevice? device;
    Direct3D11CaptureFramePool? pool;
    GraphicsCaptureSession? session;
    MediaCapture? camera;
    MediaFrameReader? reader;

    internal static async Task<VideoSource> Screen(nint monitor)
    {
        var source = new VideoSource();
        try
        {
            if (!GraphicsCaptureSession.IsSupported()) throw new InvalidOperationException("SCREEN_UNAVAILABLE: 当前会话不支持屏幕捕获，请在已登录桌面运行。");
            var item = Native.Item(monitor);
            source.Name = item.DisplayName;
            source.Width = item.Size.Width; source.Height = item.Size.Height;
            item.Closed += (_, _) => source.Error = new IOException("SCREEN_LOST: 显示器已断开。");
            source.device = Native.CreateDevice();
            source.pool = Direct3D11CaptureFramePool.CreateFreeThreaded(source.device, DirectXPixelFormat.B8G8R8A8UIntNormalized, 2, item.Size);
            source.pool.FrameArrived += source.ScreenFrame;
            source.session = source.pool.CreateCaptureSession(item);
            if (OperatingSystem.IsWindowsVersionAtLeast(10, 0, 19041)) source.session.IsCursorCaptureEnabled = true;
            source.session.StartCapture();
            await source.ready.Task.WaitAsync(TimeSpan.FromSeconds(15));
            return source;
        }
        catch { await source.DisposeAsync(); throw; }
    }

    async void ScreenFrame(Direct3D11CaptureFramePool sender, object args)
    {
        if (!await gate.WaitAsync(0)) return;
        try
        {
            if (disposed) return;
            using var frame = sender.TryGetNextFrame();
            if (frame == null) return;
            if (frame.ContentSize.Width != Width || frame.ContentSize.Height != Height)
                throw new IOException("SCREEN_SIZE_CHANGED: 显示器分辨率改变，请停止后重新录制。");
            using var bitmap = await SoftwareBitmap.CreateCopyFromSurfaceAsync(frame.Surface);
            Store(bitmap);
        }
        catch (Exception ex) { Error = ex; ready.TrySetException(ex); }
        finally { gate.Release(); }
    }

    internal static async Task<VideoSource> Camera(string id, string name, string quality)
    {
        var source = new VideoSource { Name = name, camera = new MediaCapture() };
        try
        {
            await source.camera.InitializeAsync(new MediaCaptureInitializationSettings {
                VideoDeviceId = id, StreamingCaptureMode = StreamingCaptureMode.Video,
                MemoryPreference = MediaCaptureMemoryPreference.Cpu, SharingMode = MediaCaptureSharingMode.ExclusiveControl
            });
            var frameSource = source.camera.FrameSources.Values.FirstOrDefault(s => s.Info.SourceKind == MediaFrameSourceKind.Color)
                ?? throw new IOException("CAM_FORMAT: 摄像头没有可读取的彩色视频源。");
            int maxWidth = quality == "high" ? 3840 : 1920;
            int maxHeight = quality == "high" ? 2160 : 1080;
            var format = frameSource.SupportedFormats.Where(f => f.VideoFormat.Width <= maxWidth && f.VideoFormat.Height <= maxHeight && f.FrameRate.Denominator > 0
                && f.FrameRate.Numerator / (double)f.FrameRate.Denominator is >= 29 and <= 31)
                .OrderByDescending(f => (long)f.VideoFormat.Width * f.VideoFormat.Height).FirstOrDefault()
                ?? throw new IOException("CAM_FORMAT: 摄像头没有支持 30 fps 的合适格式。");
            await frameSource.SetFormatAsync(format);
            source.reader = await source.camera.CreateFrameReaderAsync(frameSource, MediaEncodingSubtypes.Bgra8);
            source.reader.FrameArrived += source.CameraFrame;
            var status = await source.reader.StartAsync();
            if (status != MediaFrameReaderStartStatus.Success) throw new IOException($"CAM_START: 摄像头启动失败 ({status})，请检查权限或占用。");
            await source.ready.Task.WaitAsync(TimeSpan.FromSeconds(15));
            return source;
        }
        catch { await source.DisposeAsync(); throw; }
    }

    void CameraFrame(MediaFrameReader sender, MediaFrameArrivedEventArgs args)
    {
        if (!gate.Wait(0)) return;
        try
        {
            if (disposed) return;
            using var frame = sender.TryAcquireLatestFrame();
            using var bitmap = frame?.VideoMediaFrame?.SoftwareBitmap;
            if (bitmap == null) return;
            if (Width != 0 && (Width != bitmap.PixelWidth || Height != bitmap.PixelHeight))
                throw new IOException("CAM_FORMAT_CHANGED: 摄像头格式改变，请重新录制。");
            Width = bitmap.PixelWidth; Height = bitmap.PixelHeight;
            if (bitmap.BitmapPixelFormat == BitmapPixelFormat.Bgra8) Store(bitmap);
            else { using var converted = SoftwareBitmap.Convert(bitmap, BitmapPixelFormat.Bgra8); Store(converted); }
        }
        catch (Exception ex) { Error = ex; ready.TrySetException(ex); }
        finally { gate.Release(); }
    }

    void Store(SoftwareBitmap bitmap)
    {
        var bytes = new byte[checked(Width * Height * 4)];
        bitmap.CopyToBuffer(bytes.AsBuffer());
        if (FirstTimestamp == 0) FirstTimestamp = Stopwatch.GetTimestamp();
        Volatile.Write(ref Latest, bytes);
        ready.TrySetResult();
    }

    public async ValueTask DisposeAsync()
    {
        await gate.WaitAsync();
        try { disposed = true; }
        finally { gate.Release(); }
        if (reader != null) { reader.FrameArrived -= CameraFrame; await reader.StopAsync(); reader.Dispose(); }
        if (pool != null) pool.FrameArrived -= ScreenFrame;
        session?.Dispose(); pool?.Dispose(); device?.Dispose(); camera?.Dispose();
    }
}
