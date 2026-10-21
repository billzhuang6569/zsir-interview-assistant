using System.Diagnostics;
using System.Globalization;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace ZSirCapture;

internal sealed class Recorder
{
    readonly string tools;
    readonly Loopback audio = new();
    readonly TaskCompletionSource videoReady = new(TaskCreationOptions.RunContinuationsAsynchronously);
    Process? process;
    Task? previewTask;
    StreamWriter? log;
    FileStream? lease;
    double? videoStartUnix;
    double clockOffset;
    bool stopping;
    public string? Folder { get; private set; }
    public string? Failure { get; private set; }
    public float Peak => audio.Peak;
    public long AudioPackets => audio.Packets;
    public int AudioDiscontinuities => audio.Discontinuities;
    public double Seconds { get; private set; }
    public bool PreviewEnabled { get; set; } = true;
    public Action<byte[]>? Preview;
    public string DeviceName => audio.DeviceName;
    internal Process? Encoder => process;
    public Recorder(string toolsDirectory) { tools = toolsDirectory; }

    public async Task StartAsync(string root, Rectangle bounds, string audioDevice)
    {
        if (Folder != null) throw new InvalidOperationException("每个录制实例只能使用一次");
        foreach (string tool in new[] { "ffmpeg.exe", "ffprobe.exe" })
            if (!File.Exists(Path.Combine(tools, tool))) throw new FileNotFoundException("缺少编码工具，请先运行 Install-RecordingTools.cmd，再重新开始录制", tool);
        Directory.CreateDirectory(root);
        CheckSpace(root, 10_000_000_000);
        Folder = Path.Combine(root, "Take-" + DateTime.Now.ToString("yyyyMMdd-HHmmss") + "-" + Guid.NewGuid().ToString("N")[..8]);
        Directory.CreateDirectory(Folder);
        lease = new(Path.Combine(Folder, ".recording.lock"), FileMode.CreateNew, FileAccess.ReadWrite, FileShare.None);
        try
        {
            Report("preparing");
            await audio.StartAsync(Path.Combine(Folder, "system-audio.wav"), audioDevice).WaitAsync(TimeSpan.FromSeconds(10));
            clockOffset = Clock.Unix - Clock.Qpc;
            int width = bounds.Width / 2 * 2, height = bounds.Height / 2 * 2;
            int rate = (int)Math.Max(12_000_000, 12_000_000.0 * width * height / (1920 * 1080));
            log = new StreamWriter(Path.Combine(Folder, "capture.log"), false) { AutoFlush = true };
            process = new Process { StartInfo = StartInfo("ffmpeg.exe", [
                "-hide_banner", "-n", "-nostats", "-stats_period", "1", "-progress", "pipe:2",
                "-f", "gdigrab", "-framerate", "30", "-offset_x", N(bounds.X), "-offset_y", N(bounds.Y),
                "-video_size", $"{width}x{height}", "-i", "desktop",
                "-filter_complex", "[0:v]split=2[v][p];[p]fps=10,scale=320:-2[pv]",
                "-map", "[v]", "-an", "-c:v", "libx264", "-preset", "veryfast", "-b:v", N(rate), "-g", "60", "-bf", "0",
                "-pix_fmt", "yuv420p", "-flush_packets", "1", "-movflags", "+frag_keyframe+empty_moov+default_base_moof",
                Path.Combine(Folder, "desktop-video.mp4"),
                "-map", "[pv]", "-an", "-c:v", "mjpeg", "-q:v", "5", "-f", "image2pipe", "pipe:1"
            ]) };
            process.StartInfo.RedirectStandardInput = true;
            process.ErrorDataReceived += (_, e) =>
            {
                if (e.Data == null) return;
                string line = e.Data;
                try { log.WriteLine(line); }
                catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { Failure ??= "录制日志写入失败：" + ex.Message; }
                var match = Regex.Match(line, @"Duration: N/A, start: ([0-9]+\.[0-9]+)");
                if (match.Success) videoStartUnix = double.Parse(match.Groups[1].Value, CultureInfo.InvariantCulture);
                if (line.StartsWith("out_time_us=") && long.TryParse(line[12..], out long us)) Seconds = us / 1_000_000.0;
                if (line.StartsWith("frame=") && int.TryParse(line[6..].Trim(), out int frames) && frames > 0) videoReady.TrySetResult();
            };
            process.Start(); process.BeginErrorReadLine();
            previewTask = ReadPreviewAsync(process.StandardOutput.BaseStream);
            var exited = process.WaitForExitAsync();
            var first = await Task.WhenAny(videoReady.Task, exited, Task.Delay(15_000));
            if (first != videoReady.Task || !videoStartUnix.HasValue) throw new InvalidOperationException("未能启动桌面采集，请查看 capture.log");
            Report("recording", new { bounds, audio.Rate, audio.Channels, videoStartUnix, audioStartUnix = audio.OriginUnix });
        }
        catch (Exception ex)
        {
            Failure = ex.Message;
            await StopInputsAsync();
            Report("start_failed", new { error = Failure });
            lease?.Dispose(); lease = null;
            throw;
        }
    }

    public void CheckHealth()
    {
        if (stopping) return;
        if (Failure != null) throw new IOException(Failure);
        if (audio.Failure != null) throw new InvalidOperationException("系统声音采集中断：" + audio.Failure.Message);
        if (process?.HasExited == true) throw new InvalidOperationException("桌面编码进程已退出，原始素材已保留");
        if (Math.Abs(Clock.Unix - Clock.Qpc - clockOffset) > .25) throw new InvalidOperationException("系统时间发生跳变，已停止以避免音画错位");
        if (Folder != null)
        {
            string video = Path.Combine(Folder, "desktop-video.mp4");
            long reserve = (File.Exists(video) ? new FileInfo(video).Length : 0) + (long)Math.Max(0, Seconds) * 24_000;
            CheckSpace(Folder, 2_000_000_000 + reserve);
        }
    }

    public async Task<string> StopAsync(string? reason = null)
    {
        if (stopping || Folder == null) throw new InvalidOperationException("没有可停止的录制");
        stopping = true;
        Failure ??= reason;
        try
        {
            await StopInputsAsync();
            if (videoStartUnix == null) throw new InvalidOperationException("缺少视频起始时间，保留分离素材以供检查");
            var videoInfo = await ProbeAsync(Path.Combine(Folder, "desktop-video.mp4"));
            double duration = double.Parse(videoInfo.GetProperty("format").GetProperty("duration").GetString()!, CultureInfo.InvariantCulture);
            if (!double.IsFinite(duration) || duration <= 0) throw new InvalidOperationException("桌面文件时长无效");
            double offset = videoStartUnix.Value - audio.OriginUnix;
            if (offset < 0 || offset > 30) throw new InvalidOperationException("音画起始偏移异常，保留原素材");
            CheckSpace(Folder, new FileInfo(Path.Combine(Folder, "desktop-video.mp4")).Length + (long)(duration * 24_000) + 512_000_000);
            string partial = Path.Combine(Folder, "desktop-partial.mp4");
            Report("finalizing", new { duration, offset, reason });
            var result = await RunAsync("ffmpeg.exe", ["-hide_banner", "-nostdin", "-n", "-ss", N(offset), "-i", Path.Combine(Folder, "system-audio.wav"),
                "-i", Path.Combine(Folder, "desktop-video.mp4"), "-map", "1:v:0", "-map", "0:a:0", "-c:v", "copy",
                "-c:a", "aac", "-b:a", "192k", "-ar", "48000", "-ac", "2", "-af", "apad", "-t", N(duration),
                "-movflags", "+faststart", partial], TimeSpan.FromHours(2));
            await File.WriteAllTextAsync(Path.Combine(Folder, "finalize.log"), result.Error);
            if (result.Code != 0) throw new InvalidOperationException("音画合成失败，原视频和系统声音均已保留");
            var final = await ProbeAsync(partial);
            var streams = final.GetProperty("streams").EnumerateArray().ToArray();
            if (!streams.Any(x => x.GetProperty("codec_type").GetString() == "video") || !streams.Any(x => x.GetProperty("codec_type").GetString() == "audio"))
                throw new InvalidOperationException("输出缺少音频或视频轨道");
            string output = Path.Combine(Folder, "desktop.mp4");
            File.Move(partial, output);
            Failure ??= audio.Failure?.Message;
            if (audio.Discontinuities > 0) Failure ??= "系统声音发生不连续，请检查音轨";
            Report(Failure == null ? "finalized_unverified" : "needs_review", new { duration, offset, audio.Packets, audio.Discontinuities, error = Failure, output = "desktop.mp4" });
            return output;
        }
        catch (Exception ex) { Failure = ex.Message; Report("needs_review", new { error = Failure }); throw; }
        finally { lease?.Dispose(); lease = null; }
    }

    async Task StopInputsAsync()
    {
        try
        {
        if (process != null)
        {
            try
            {
                if (!process.HasExited)
                {
                    await process.StandardInput.WriteLineAsync("q"); await process.StandardInput.FlushAsync();
                    try { await process.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(20)); }
                    catch (TimeoutException) { process.Kill(entireProcessTree: true); await process.WaitForExitAsync(); Failure ??= "编码进程未及时结束，已保留碎片文件"; }
                }
                process.WaitForExit();
                if (process.ExitCode != 0) Failure ??= "桌面采集异常退出";
            }
            catch (InvalidOperationException) { /* Process.Start can fail before a process exists. */ }
            catch (IOException) { Failure ??= "无法正常通知编码器停止"; if (!process.HasExited) { process.Kill(true); await process.WaitForExitAsync(); } }
            finally
            {
                if (previewTask != null) await previewTask;
                process.Dispose(); process = null; log?.Dispose(); log = null;
            }
        }
        }
        finally { await audio.StopAsync(); }
    }

    async Task ReadPreviewAsync(Stream source)
    {
        byte[] chunk = new byte[16384]; using var jpeg = new MemoryStream(); int previous = -1; bool inside = false;
        try
        {
            int count;
            while ((count = await source.ReadAsync(chunk)) > 0)
                for (int i = 0; i < count; i++)
                {
                    int value = chunk[i];
                    if (!inside && previous == 255 && value == 216) { jpeg.SetLength(0); jpeg.WriteByte(255); inside = true; }
                    if (inside) jpeg.WriteByte((byte)value);
                    if (inside && previous == 255 && value == 217)
                    { if (PreviewEnabled) Preview?.Invoke(jpeg.ToArray()); inside = false; }
                    if (jpeg.Length > 2_000_000) { inside = false; jpeg.SetLength(0); }
                    previous = value;
                }
        }
        catch (IOException) { /* EOF during a failed encoder is handled by its exit status. */ }
    }

    public async Task<JsonElement> ProbeAsync(string path)
    {
        var result = await RunAsync("ffprobe.exe", ["-v", "error", "-show_streams", "-show_format", "-of", "json", path], TimeSpan.FromSeconds(30));
        if (result.Code != 0) throw new InvalidOperationException("无法读取媒体文件：" + result.Error);
        using var json = JsonDocument.Parse(result.Output); return json.RootElement.Clone();
    }
    public async Task<(int Code, string Output, string Error)> RunAsync(string name, IEnumerable<string> args, TimeSpan timeout)
    {
        using var command = new Process { StartInfo = StartInfo(name, args) };
        command.Start();
        var output = command.StandardOutput.ReadToEndAsync(); var error = command.StandardError.ReadToEndAsync();
        try { await command.WaitForExitAsync().WaitAsync(timeout); }
        catch { if (!command.HasExited) { command.Kill(true); await command.WaitForExitAsync(); } throw; }
        return (command.ExitCode, await output, await error);
    }
    ProcessStartInfo StartInfo(string name, IEnumerable<string> args)
    {
        var info = new ProcessStartInfo(Path.Combine(tools, name)) { UseShellExecute = false, CreateNoWindow = true, RedirectStandardError = true, RedirectStandardOutput = true };
        foreach (string arg in args) info.ArgumentList.Add(arg);
        return info;
    }
    void Report(string state, object? details = null)
    {
        if (Folder == null) return;
        string path = Path.Combine(Folder, "report.json"), temporary = path + ".tmp";
        File.WriteAllText(temporary, JsonSerializer.Serialize(new { state, platform = "windows", mode = "desktop", device = audio.DeviceName, details, updatedAt = DateTimeOffset.UtcNow }, new JsonSerializerOptions { WriteIndented = true }));
        File.Move(temporary, path, true);
    }
    static string N(object value) => Convert.ToString(value, CultureInfo.InvariantCulture)!;
    public static void CheckSpace(string path, long minimum)
    {
        var drive = new DriveInfo(Path.GetPathRoot(Path.GetFullPath(path))!);
        if (drive.AvailableFreeSpace < minimum) throw new IOException($"磁盘可用空间不足 {minimum / 1_000_000_000} GB");
    }
}
