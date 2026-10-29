using System.Diagnostics;
using System.Globalization;

namespace ZSirCapture;

// Owns the desktop source only while the recorder is idle. StopAsync completes
// before recording starts, so preview never creates a second recording source.
internal sealed class IdlePreview : IDisposable
{
    readonly Process process;
    readonly Task frames;
    readonly Task errors;
    public Rectangle Bounds { get; }
    public bool HasExited => process.HasExited;

    public IdlePreview(string tools, Rectangle bounds, Action<byte[]> frame)
    {
        Bounds = bounds;
        var info = new ProcessStartInfo(Path.Combine(tools, "ffmpeg.exe")) {
            UseShellExecute = false, CreateNoWindow = true, RedirectStandardInput = true,
            RedirectStandardOutput = true, RedirectStandardError = true
        };
        string[] args = ["-hide_banner", "-loglevel", "error", "-f", "gdigrab", "-framerate", "5",
            "-offset_x", bounds.X.ToString(CultureInfo.InvariantCulture), "-offset_y", bounds.Y.ToString(CultureInfo.InvariantCulture),
            "-video_size", $"{bounds.Width}x{bounds.Height}", "-i", "desktop", "-an", "-vf", "scale=320:-2",
            "-c:v", "mjpeg", "-threads", "1", "-q:v", "5", "-f", "image2pipe", "pipe:1"];
        foreach (string argument in args) info.ArgumentList.Add(argument);
        process = new Process { StartInfo = info };
        try { process.Start(); }
        catch { process.Dispose(); throw; }
        frames = ReadFramesAsync(process.StandardOutput.BaseStream, frame);
        errors = DrainAsync(process.StandardError.BaseStream);
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

    public async Task StopAsync()
    {
        if (!process.HasExited) process.Kill(entireProcessTree: true);
        // Never hand the source to Recorder until the old process has exited.
        await process.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(5));
        await Task.WhenAll(frames, errors).WaitAsync(TimeSpan.FromSeconds(3));
    }

    public void Dispose()
    {
        try { if (!process.HasExited) { process.Kill(entireProcessTree: true); process.WaitForExit(2000); } }
        catch (InvalidOperationException) { }
        finally { process.Dispose(); }
    }
}
