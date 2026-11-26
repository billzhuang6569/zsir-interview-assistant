using System.Diagnostics;
using System.Globalization;
using System.Text;

namespace ZSirCapture;

// Owns one idle source. StopAsync completes before recording starts, including
// late native initialization, so preview cannot reopen the camera afterward.
internal sealed class IdlePreview : IDisposable
{
    readonly Process process;
    readonly SharedCameraInput? cameraInput;
    Task? stopTask;
    readonly Task frames;
    readonly Task errors;
    public Rectangle Bounds { get; }
    public Exception? Failure => cameraInput?.Failure;
    public bool HasExited => process.HasExited || cameraInput?.Failure != null;

    public IdlePreview(string tools, Rectangle bounds, Action<byte[]> frame, CameraDevice? camera = null, CameraFormat? format = null)
    {
        Bounds = bounds;
        if (camera != null && !CameraDevices.Fake) cameraInput = new SharedCameraInput(camera, format!);
        var info = new ProcessStartInfo(Path.Combine(tools, "ffmpeg.exe")) {
            UseShellExecute = false, CreateNoWindow = true, RedirectStandardInput = true,
            RedirectStandardOutput = true, RedirectStandardError = true,
            StandardOutputEncoding = new UTF8Encoding(false), StandardErrorEncoding = new UTF8Encoding(false)
        };
        string[] args = ["-hide_banner", "-loglevel", "error", "-f", "gdigrab", "-framerate", "5",
            "-offset_x", bounds.X.ToString(CultureInfo.InvariantCulture), "-offset_y", bounds.Y.ToString(CultureInfo.InvariantCulture),
            "-video_size", $"{bounds.Width}x{bounds.Height}", "-i", "desktop", "-an", "-vf", "scale=320:-2",
            "-c:v", "mjpeg", "-threads", "1", "-q:v", "5", "-f", "image2pipe", "pipe:1"];
        if (camera != null) args = ["-hide_banner", "-loglevel", "error", ..CameraDevices.Input(camera, format!, cameraInput?.PipePath),
            "-an", "-vf", "fps=10,scale=320:-2", "-c:v", "mjpeg", "-threads", "1", "-q:v", "5", "-f", "image2pipe", "pipe:1"];
        foreach (string argument in args) info.ArgumentList.Add(argument);
        process = new Process { StartInfo = info };
        try { process.Start(); }
        catch { process.Dispose(); _ = cameraInput?.StopAsync(); throw; }
        frames = ReadFramesAsync(process.StandardOutput.BaseStream, frame);
        errors = DrainAsync(process.StandardError.BaseStream);
        if (cameraInput != null)
            _ = cameraInput.StartAsync().ContinueWith(faulted => { _ = faulted.Exception; }, TaskContinuationOptions.OnlyOnFaulted);
    }

    static async Task DrainAsync(Stream stream)
    {
        byte[] buffer = new byte[4096];
        try { while (await stream.ReadAsync(buffer) > 0) { } }
        catch (IOException) { }
        catch (ObjectDisposedException) { }
    }

    static async Task ReadFramesAsync(Stream stream, Action<byte[]> frame)
    {
        byte[] buffer = new byte[16384];
        using var jpeg = new MemoryStream();
        int previous = -1; bool inside = false;
        try
        {
            int count;
            while ((count = await stream.ReadAsync(buffer)) > 0)
                for (int i = 0; i < count; i++)
                {
                    int value = buffer[i];
                    if (!inside && previous == 255 && value == 216) { jpeg.SetLength(0); jpeg.WriteByte(255); inside = true; }
                    if (inside) jpeg.WriteByte((byte)value);
                    if (inside && previous == 255 && value == 217) { frame(jpeg.ToArray()); inside = false; }
                    if (jpeg.Length > 2_000_000) { inside = false; jpeg.SetLength(0); }
                    previous = value;
                }
        }
        catch (IOException) { }
        catch (ObjectDisposedException) { }
    }

    public Task StopAsync() => (stopTask ??= StopCoreAsync()).WaitAsync(TimeSpan.FromSeconds(8));

    async Task StopCoreAsync()
    {
        var cameraStop = cameraInput?.StopAsync() ?? Task.CompletedTask;
        if (!process.HasExited) process.Kill(entireProcessTree: true);
        await Task.WhenAll(process.WaitForExitAsync(), frames, errors, cameraStop);
    }

    public void Dispose()
    {
        // Retain native ownership after a public timeout until late initialization/stop really settles.
        _ = (stopTask ??= StopCoreAsync()).ContinueWith(done => { _ = done.Exception; process.Dispose(); });
    }
}
