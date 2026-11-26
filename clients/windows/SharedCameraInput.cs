using System.Buffers;
using System.Diagnostics;
using System.Runtime.InteropServices.WindowsRuntime;
using Windows.Graphics.Imaging;
using Windows.Media.Capture;
using Windows.Media.Capture.Frames;
using Windows.Media.MediaProperties;

namespace ZSirCapture;

internal sealed class SharedCameraInput
{
    readonly MediaCapture capture = new();
    readonly CameraDevice device;
    readonly CameraFormat format;
    readonly CameraFramePipe pipe;
    readonly CancellationTokenSource cancellation = new();
    readonly object gate = new();
    MediaFrameReader? reader;
    Task? startup, stop;
    Exception? failure;
    int reading;
    long capturedFrames, lastFrameQpc;
    public string PipePath => pipe.Path;
    public Task? StopCompletion { get { lock (gate) return stop; } }
    public Exception? Failure => failure ?? pipe.Failure;
    public long CapturedFrames => Interlocked.Read(ref capturedFrames);
    public long DroppedFrames => pipe.DroppedFrames;
    public double SourceIdleSeconds { get { long last = Interlocked.Read(ref lastFrameQpc); return last == 0 ? 0 : Stopwatch.GetElapsedTime(last).TotalSeconds; } }

    public SharedCameraInput(CameraDevice device, CameraFormat format)
    {
        this.device = device; this.format = format;
        pipe = new CameraFramePipe(format.Width, format.Height);
    }

    static MediaCaptureInitializationSettings Settings(CameraDevice device) => new() {
        VideoDeviceId = device.Id, StreamingCaptureMode = StreamingCaptureMode.Video,
        SharingMode = MediaCaptureSharingMode.SharedReadOnly, MemoryPreference = MediaCaptureMemoryPreference.Cpu
    };

    static MediaFrameSource Source(MediaCapture capture) => capture.FrameSources.Values
        .Where(s => s.Info.SourceKind == MediaFrameSourceKind.Color)
        .OrderBy(s => s.Info.MediaStreamType == MediaStreamType.VideoPreview ? 0 : 1).FirstOrDefault()
        ?? throw new IOException("此摄像头未提供可共享的彩色画面；请检查驱动或选择其他摄像头");

    internal static async Task<CameraFormat> ReadFormatAsync(CameraDevice device)
    {
        using var capture = new MediaCapture();
        await capture.InitializeAsync(Settings(device));
        var current = Source(capture).CurrentFormat;
        var size = RecordingOptions.OutputSize("balanced", checked((int)current.VideoFormat.Width), checked((int)current.VideoFormat.Height));
        return new(null, "bgra", size.Width, size.Height,
            current.FrameRate.Denominator == 0 ? 30 : (double)current.FrameRate.Numerator / current.FrameRate.Denominator);
    }

    public Task StartAsync() { lock (gate) return startup ??= StartCoreAsync(); }

    async Task StartCoreAsync()
    {
        try
        {
            cancellation.Token.ThrowIfCancellationRequested();
            capture.Failed += CaptureFailed;
            await capture.InitializeAsync(Settings(device));
            cancellation.Token.ThrowIfCancellationRequested();
            // Conversion affects this reader only. Never call SetFormatAsync on the shared device.
            reader = await capture.CreateFrameReaderAsync(Source(capture), MediaEncodingSubtypes.Argb32,
                new BitmapSize { Width = (uint)format.Width, Height = (uint)format.Height });
            cancellation.Token.ThrowIfCancellationRequested();
            reader.AcquisitionMode = MediaFrameReaderAcquisitionMode.Realtime;
            reader.FrameArrived += FrameArrived;
            var status = await reader.StartAsync();
            if (status != MediaFrameReaderStartStatus.Success) throw new IOException("无法读取共享摄像头画面：" + status);
        }
        catch (Exception ex) { failure = ex; pipe.RequestStop(); throw; }
    }

    void CaptureFailed(MediaCapture sender, MediaCaptureFailedEventArgs args)
    {
        failure = new IOException($"共享摄像头中断：{args.Message} (0x{args.Code:X8})");
        pipe.RequestStop();
    }

    void FrameArrived(MediaFrameReader sender, MediaFrameArrivedEventArgs args)
    {
        if (cancellation.IsCancellationRequested || Interlocked.Exchange(ref reading, 1) != 0) return;
        byte[]? buffer = null;
        try
        {
            using var frame = sender.TryAcquireLatestFrame();
            using var bitmap = frame?.VideoMediaFrame?.SoftwareBitmap;
            if (bitmap == null) return;
            if (bitmap.PixelWidth != format.Width || bitmap.PixelHeight != format.Height || bitmap.BitmapPixelFormat != BitmapPixelFormat.Bgra8)
                throw new IOException("共享摄像头转换后的画面格式发生变化，已保留原始素材");
            buffer = ArrayPool<byte>.Shared.Rent(pipe.FrameBytes);
            bitmap.CopyToBuffer(buffer.AsBuffer(0, pipe.FrameBytes));
            Interlocked.Increment(ref capturedFrames);
            Interlocked.Exchange(ref lastFrameQpc, Stopwatch.GetTimestamp());
            var owned = buffer; buffer = null; pipe.Offer(owned);
        }
        catch (Exception ex) { failure = ex; pipe.RequestStop(); }
        finally { if (buffer != null) ArrayPool<byte>.Shared.Return(buffer); Volatile.Write(ref reading, 0); }
    }

    public Task StopAsync()
    {
        lock (gate)
        {
            cancellation.Cancel(); pipe.RequestStop();
            return stop ??= StopCoreAsync();
        }
    }

    async Task StopCoreAsync()
    {
        try
        {
            // A late initialization must settle before disposal, so it cannot reopen the camera.
            if (startup != null) try { await startup; } catch { }
            if (reader != null) { reader.FrameArrived -= FrameArrived; await reader.StopAsync(); }
        }
        finally
        {
            while (Volatile.Read(ref reading) != 0) await Task.Delay(1);
            try { reader?.Dispose(); }
            finally
            {
                capture.Failed -= CaptureFailed;
                try { capture.Dispose(); }
                finally { await pipe.Completion; }
            }
        }
    }
}
