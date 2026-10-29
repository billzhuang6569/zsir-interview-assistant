using System.Diagnostics;
using System.Globalization;
using System.Text.Json;
using System.Text.RegularExpressions;
using System.Threading.Channels;

namespace ZSirCapture;

internal sealed class Recorder
{
    readonly string tools;
    readonly Loopback audio = new();
    readonly TaskCompletionSource videoReady = new(TaskCreationOptions.RunContinuationsAsynchronously);
    Process? process;
    Task? previewTask;
    Task? processExitTask;
    Task? copyTask;
    Task? finalizerExitTask;
    object? finalizationPolicy;
    internal bool CleanupPending => stopping && (audio.IsActive || new[] { processExitTask, previewTask, logTask, copyTask, finalizerExitTask }.Any(task => task != null && !task.IsCompleted));
    StreamWriter? log;
    readonly Channel<string> logLines = Channel.CreateBounded<string>(new BoundedChannelOptions(256) { SingleReader = true, FullMode = BoundedChannelFullMode.Wait });
    Task? logTask;
    long droppedLogLines;
    FileStream? lease;
    double? videoStartUnix;
    double clockOffset;
    volatile bool stopping;
    Task<string>? stopTask;
    readonly object stopGate = new();
    readonly object processGate = new();
    long startupCommitBudget;
    internal Task<string>? Completion { get { lock (stopGate) return stopTask; } }
    CancellationTokenSource? watchdogCancellation;
    Task? watchdogTask;
    long writtenFrames;
    long previewFrames;
    internal long PreviewFrames => Interlocked.Read(ref previewFrames);
    long duplicatedFrames;
    long droppedFrames;
    long lastProgress = Stopwatch.GetTimestamp();
    string outputProfile = "native";
    (int Width, int Height) outputSize;
    readonly int encoderThreads = Math.Clamp(Environment.ProcessorCount / 2, 1, 4);
    bool systemAudio = true;
    string quality = "standard";
    int targetVideoBitRate;
    Rectangle captureBounds;
    public string? Folder { get; private set; }
    public string? Failure { get; private set; }
    public float Peak => audio.Peak;
    public long AudioPackets => audio.Packets;
    public int AudioDiscontinuities => audio.Discontinuities;
    public double Seconds { get; private set; }
    volatile bool previewEnabled = true;
    bool previewGateSupported;
    int previewGateState = -1;
    readonly SemaphoreSlim inputGate = new(1, 1);
    string captureBackend = "gdigrab";
    string captureProbe = "not probed";
    string encoder = "libx264";
    string encoderProbe = "not probed";
    public bool PreviewEnabled { get => previewEnabled; set => previewEnabled = value; }
    public Action<byte[]>? Preview;
    public string DeviceName => audio.DeviceName;
    internal Process? Encoder => process;
    public Recorder(string toolsDirectory) { tools = toolsDirectory; }

    public async Task StartAsync(string root, Rectangle bounds, string audioDevice, string quality = "standard", bool systemAudio = true, string outputProfile = "native")
    {
        this.quality = quality; this.systemAudio = systemAudio; captureBounds = bounds;
        this.outputProfile = outputProfile;
        outputSize = RecordingOptions.OutputSize(outputProfile, bounds.Width, bounds.Height);
        targetVideoBitRate = RecordingOptions.BitRate(quality, outputSize.Width, outputSize.Height);
        startupCommitBudget = ResourceBudget.EstimateStartup(bounds.Width, bounds.Height, outputSize.Width, outputSize.Height, encoderThreads);
        ResourceBudget.Check(startupCommitBudget);
        if (Folder != null) throw new InvalidOperationException("每个录制实例只能使用一次");
        foreach (string tool in new[] { "ffmpeg.exe", "ffprobe.exe" })
            if (!File.Exists(Path.Combine(tools, tool))) throw new FileNotFoundException("录制组件缺失，请重新下载完整安装包并完整解压后打开；不要只复制 EXE。已有录制素材不会受影响", tool);
        Directory.CreateDirectory(root);
        CheckSpace(root, 10_000_000_000);
        Folder = Path.Combine(root, "Take-" + DateTime.Now.ToString("yyyyMMdd-HHmmss") + "-" + Guid.NewGuid().ToString("N")[..8]);
        Directory.CreateDirectory(Folder);
        lease = new(Path.Combine(Folder, ".recording.lock"), FileMode.CreateNew, FileAccess.ReadWrite, FileShare.None);
        try
        {
            var gate = await RunAsync("ffmpeg.exe", ["-hide_banner", "-h", "filter=select"], TimeSpan.FromSeconds(5));
            previewGateSupported = (gate.Output + gate.Error).Contains("ZSir preview gate v1.");
            if (!previewGateSupported) throw new InvalidOperationException("录制组件缺少按需预览能力，请使用 0.4.0 配套工具包");
            await ProbeCaptureAsync(bounds);
            await ProbeEncoderAsync();
            Report("preparing");
            if (systemAudio) await audio.StartAsync(Path.Combine(Folder, "system-audio.wav"), audioDevice).WaitAsync(TimeSpan.FromSeconds(10));
            clockOffset = Clock.Unix - Clock.Qpc;
            int width = bounds.Width / 2 * 2, height = bounds.Height / 2 * 2;
            int rate = targetVideoBitRate;
            log = new StreamWriter(Path.Combine(Folder, "capture.log"), false) { AutoFlush = true };
            logTask = Task.Run(WriteLogAsync);
            process = new Process { StartInfo = StartInfo("ffmpeg.exe", [
                "-hide_banner", "-n", "-nostats", "-stats_period", "1", "-progress", "pipe:2",
                "-filter_complex_threads", "1", "-thread_queue_size", "3",
                ..(captureBackend == "ddagrab" ? new[] { "-f", "lavfi", "-use_wallclock_as_timestamps", "1", "-i", $"ddagrab=output_idx=0:framerate=30:video_size={width}x{height}" } :
                    new[] { "-f", "gdigrab", "-framerate", "30", "-offset_x", N(bounds.X), "-offset_y", N(bounds.Y), "-video_size", $"{width}x{height}", "-i", "desktop" }),
                "-filter_complex",  $"[0:v]{(captureBackend == "ddagrab" ? "hwdownload,format=bgra," : "")}split=2[raw][p];[raw]scale={outputSize.Width}:{outputSize.Height}[v];[p]fps=10,select@preview=1,scale=320:-2[pv]",
                "-map", "[v]", "-an", "-c:v", encoder,
                ..(encoder == "libx264" ? new[] { "-preset", "veryfast", "-x264-params", $"rc-lookahead=10:sync-lookahead=0:threads={encoderThreads}" } : new[] { "-hw_encoding", "1", "-scenario", "camera_record", "-rate_control", "cbr" }), "-b:v", N(rate), "-g", "60", "-bf", "0",
                "-threads:v", N(encoderThreads),
                "-r:v", N(RecordingOptions.FramesPerSecond), "-fps_mode:v", "cfr",
                "-pix_fmt", "yuv420p", "-flush_packets", "1", "-movflags", "+frag_keyframe+empty_moov+default_base_moof",
                Path.Combine(Folder, "desktop-video.mp4"),
                "-map", "[pv]", "-an", "-c:v", "mjpeg", "-fps_mode:v", "passthrough", "-q:v", "5", "-f", "image2pipe", "pipe:1"
            ]) };
            process.StartInfo.RedirectStandardInput = true;
            process.ErrorDataReceived += (_, e) =>
            {
                if (e.Data == null) return;
                string line = e.Data;
                if (!logLines.Writer.TryWrite(line)) Interlocked.Increment(ref droppedLogLines);
                var match = Regex.Match(line, @"Duration: N/A, start: ([0-9]+\.[0-9]+)");
                if (match.Success) videoStartUnix = double.Parse(match.Groups[1].Value, CultureInfo.InvariantCulture);
                if (line.StartsWith("out_time_us=") && long.TryParse(line[12..], out long us)) Seconds = us / 1_000_000.0;
                if (line.StartsWith("dup_frames=") && long.TryParse(line[11..], out long duplicates)) Interlocked.Exchange(ref duplicatedFrames, duplicates);
                if (line.StartsWith("drop_frames=") && long.TryParse(line[12..], out long drops)) Interlocked.Exchange(ref droppedFrames, drops);
                if (line.StartsWith("frame=") && long.TryParse(line[6..].Trim(), out long frames) && frames > Interlocked.Read(ref writtenFrames))
                {
                    Interlocked.Exchange(ref writtenFrames, frames);
                    Interlocked.Exchange(ref lastProgress, Stopwatch.GetTimestamp());
                    videoReady.TrySetResult();
                }
            };
            process.Start(); process.BeginErrorReadLine();
            processExitTask = process.WaitForExitAsync();
            previewGateState = 1;
            Stream previewStream = process.StandardOutput.BaseStream;
            previewTask = Task.Run(() => ReadPreviewAsync(previewStream));
            var exited = process.WaitForExitAsync();
            var first = await Task.WhenAny(videoReady.Task, exited, Task.Delay(15_000));
            if (first != videoReady.Task || !videoStartUnix.HasValue) throw new InvalidOperationException("未能启动桌面采集，请查看 capture.log");
            watchdogCancellation = new();
            watchdogTask = Task.Run(() => WatchHealthAsync(watchdogCancellation.Token));
            Report("recording", new { bounds, audio.Rate, audio.Channels, videoStartUnix, audioStartUnix = audio.OriginUnix });
        }
        catch (Exception ex)
        {
            Failure ??= ex.Message;
            stopping = true;
            watchdogCancellation?.Cancel();
            string? cleanupError = null;
            try
            {
                try { await StopInputsAsync(); }
                catch (Exception cleanup) { cleanupError = cleanup.Message; }
                try { Report("start_failed", new { error = Failure, cleanupError }); }
                catch (Exception reportError) when (reportError is IOException or UnauthorizedAccessException)
                { /* Preserve the primary startup failure even if the report disk is unavailable. */ }
            }
            finally { ReleaseLeaseAfterCleanup(); }
            throw;
        }
    }

    public void CheckHealth()
    {
        if (Failure != null) throw new IOException(Failure);
        if (stopping) return;
        ResourceBudget.Check();
        if (Stopwatch.GetElapsedTime(Interlocked.Read(ref lastProgress)).TotalSeconds > 15)
            throw new IOException("编码器超过 15 秒没有写入进度，原始素材已保留");
        if (Failure != null) throw new IOException(Failure);
        if (systemAudio && audio.Failure != null) throw new InvalidOperationException("系统声音采集中断：" + audio.Failure.Message);
        lock (processGate)
        {
            if (stopping) return;
            if (process?.HasExited == true) throw new InvalidOperationException("桌面编码进程已退出，原始素材已保留");
        }
        if (Math.Abs(Clock.Unix - Clock.Qpc - clockOffset) > .25) throw new InvalidOperationException("系统时间发生跳变，已停止以避免音画错位");
        if (Folder != null)
        {
            string video = Path.Combine(Folder, "desktop-video.mp4");
            long reserve = (File.Exists(video) ? new FileInfo(video).Length : 0) + (long)Math.Max(0, Seconds) * 24_000;
            CheckSpace(Folder, 2_000_000_000 + reserve);
        }
    }

    public Task<string> StopAsync(string? reason = null)
    {
        lock (stopGate) return stopTask ??= StopCoreAsync(reason);
    }

    async Task<string> StopCoreAsync(string? reason)
    {
        if (Folder == null) throw new InvalidOperationException("没有可停止的录制");
        stopping = true;
        watchdogCancellation?.Cancel();
        Failure ??= reason;
        try
        {
            await StopInputsAsync();
            if (videoStartUnix == null) throw new InvalidOperationException("缺少视频起始时间，保留分离素材以供检查");
            var videoInfo = await ProbeAsync(Path.Combine(Folder, "desktop-video.mp4"));
            double duration = double.Parse(videoInfo.GetProperty("format").GetProperty("duration").GetString()!, CultureInfo.InvariantCulture);
            if (!double.IsFinite(duration) || duration <= 0) throw new InvalidOperationException("桌面文件时长无效");
            if (!systemAudio) {
                string silentOutput = Path.Combine(Folder, "desktop.mp4");
                CheckSpace(Folder, new FileInfo(Path.Combine(Folder, "desktop-video.mp4")).Length + 512_000_000);
                if (!videoInfo.GetProperty("streams").EnumerateArray().Any(x => x.GetProperty("codec_type").GetString() == "video")) throw new InvalidOperationException("输出缺少视频轨道");
                string copyPartial = Path.Combine(Folder, "desktop-partial.mp4");
                var copyBudget = FinalizationBudget.Calculate(new FileInfo(Path.Combine(Folder, "desktop-video.mp4")).Length, duration, false, false);
                finalizationPolicy = FinalizationBudget.Describe(copyBudget);
                Report("finalizing", new { duration, finalizationPolicy });
                using var copyCancellation = new CancellationTokenSource();
                long copiedBytes = 0;
                var copy = copyTask = Task.Run(async () => {
                    await using var source = new FileStream(Path.Combine(Folder, "desktop-video.mp4"), FileMode.Open, FileAccess.Read, FileShare.Read, 65536, FileOptions.Asynchronous);
                    await using var destination = new FileStream(copyPartial, FileMode.CreateNew, FileAccess.Write, FileShare.None, 65536, FileOptions.Asynchronous);
                    byte[] buffer = new byte[65536]; int count;
                    while ((count = await source.ReadAsync(buffer, copyCancellation.Token)) > 0)
                    {
                        await destination.WriteAsync(buffer.AsMemory(0, count), copyCancellation.Token);
                        Interlocked.Add(ref copiedBytes, count);
                    }
                    await destination.FlushAsync(copyCancellation.Token);
                });
                try { await FinalizationBudget.WaitAsync(copy, () => (ulong)Interlocked.Read(ref copiedBytes), copyBudget); }
                catch
                {
                    copyCancellation.Cancel();
                    _ = copy.ContinueWith(faulted => { _ = faulted.Exception; }, TaskContinuationOptions.OnlyOnFaulted);
                    throw;
                }
                File.Move(copyPartial, silentOutput);
                Report(Failure == null ? "finalized_unverified" : "needs_review", new { duration, error = Failure, output = "desktop.mp4" });
                return silentOutput;
            }
            double offset = videoStartUnix.Value - audio.OriginUnix;
            if (offset < 0 || offset > 30) throw new InvalidOperationException("音画起始偏移异常，保留原素材");
            CheckSpace(Folder, new FileInfo(Path.Combine(Folder, "desktop-video.mp4")).Length + (long)(duration * 24_000) + 512_000_000);
            string partial = Path.Combine(Folder, "desktop-partial.mp4");
            var muxBudget = FinalizationBudget.Calculate(checked(new FileInfo(Path.Combine(Folder, "desktop-video.mp4")).Length + new FileInfo(Path.Combine(Folder, "system-audio.wav")).Length), duration, true, true);
            finalizationPolicy = FinalizationBudget.Describe(muxBudget);
            Report("finalizing", new { duration, offset, reason, finalizationPolicy });
            var result = await RunAsync("ffmpeg.exe", ["-hide_banner", "-nostdin", "-n", "-ss", N(offset), "-i", Path.Combine(Folder, "system-audio.wav"),
                "-i", Path.Combine(Folder, "desktop-video.mp4"), "-map", "1:v:0", "-map", "0:a:0", "-c:v", "copy",
                "-c:a", "aac", "-b:a", "192k", "-ar", "48000", "-ac", "2", "-af", "apad", "-t", N(duration),
                "-movflags", "+faststart", partial], muxBudget, monitorIo: true);
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
        catch (Exception ex) { Failure ??= ex.Message; Report("needs_review", new { error = Failure }); throw; }
        finally { ReleaseLeaseAfterCleanup(); }
    }

    void ReleaseLeaseAfterCleanup()
    {
        var ownedLease = lease;
        if (ownedLease == null) return;
        lease = null;
        if (!CleanupPending) { ownedLease.Dispose(); return; }
        // A timed-out writer still owns the Take. Keep its exclusion lease until
        // actual worker completion, even after the UI leaves the saving state.
        var workers = new[] { audio.Cleanup, processExitTask, previewTask, logTask, copyTask, finalizerExitTask }
            .Where(task => task != null).Cast<Task>().ToArray();
        _ = ReleaseCleanupLeaseAsync(ownedLease, workers);
    }

    internal static async Task ReleaseCleanupLeaseAsync(FileStream ownedLease, Task[] workers)
    {
        foreach (var worker in workers)
            try { await worker; } catch { /* Completion, not success, releases ownership. */ }
        ownedLease.Dispose();
    }

    async Task ProbeCaptureAsync(Rectangle bounds)
    {
        // DXGI output indices are adapter-local, not Screen.AllScreens indices.
        // Only the unambiguous single-output case is admitted until multi-adapter
        // mapping has native acceptance; all other layouts retain explicit GDI fallback.
        if (Screen.AllScreens.Length != 1 || Screen.AllScreens[0].Bounds != bounds)
        { captureProbe = "multiple/changed displays require GDI fallback; DXGI mapping not accepted"; return; }
        try
        {
            var result = await RunAsync("ffmpeg.exe", ["-hide_banner", "-nostdin", "-f", "lavfi", "-i",
                $"ddagrab=output_idx=0:framerate=30:video_size={bounds.Width / 2 * 2}x{bounds.Height / 2 * 2}",
                "-vf", "hwdownload,format=bgra", "-frames:v", "3", "-an", "-c:v", "wrapped_avframe", "-f", "null", "NUL"], TimeSpan.FromSeconds(8));
            if (result.Code == 0) { captureBackend = "ddagrab"; captureProbe = "Desktop Duplication delivered 3 frames; CPU download retained for shared preview/scaling"; }
            else captureProbe = "Desktop Duplication initialization failed; GDI fallback";
        }
        catch (Exception ex) when (ex is IOException or InvalidOperationException or TimeoutException)
        { captureProbe = "Desktop Duplication unavailable; GDI fallback: " + ex.Message; }
    }

    async Task ProbeEncoderAsync()
    {
        string probe = Path.Combine(Folder!, "encoder-probe.mp4");
        try
        {
            var result = await RunAsync("ffmpeg.exe", ["-hide_banner", "-nostdin", "-n", "-f", "lavfi", "-i",
                $"color=size={outputSize.Width}x{outputSize.Height}:rate=30", "-frames:v", "12", "-an",
                "-c:v", "h264_mf", "-hw_encoding", "1", "-scenario", "camera_record", "-rate_control", "cbr",
                "-b:v", N(targetVideoBitRate), "-pix_fmt", "yuv420p", probe], TimeSpan.FromSeconds(12));
            if (result.Code != 0) { encoderProbe = "MediaFoundation hardware initialization failed; bounded libx264 fallback"; return; }
            var media = await ProbeAsync(probe);
            if (media.GetProperty("streams").EnumerateArray().Any(x => x.GetProperty("codec_type").GetString() == "video" &&
                x.GetProperty("codec_name").GetString() == "h264" && x.TryGetProperty("nb_frames", out var frames) && frames.GetString() == "12"))
            { encoder = "h264_mf"; encoderProbe = "hardware-only MediaFoundation initialized and encoded 12 frames at requested dimensions; not a throughput guarantee"; }
            else encoderProbe = "MediaFoundation probe output validation failed; bounded libx264 fallback";
        }
        catch (Exception ex) when (ex is IOException or InvalidOperationException or TimeoutException)
        { encoderProbe = "MediaFoundation probe unavailable: " + ex.Message; }
        finally { if (File.Exists(probe)) File.Delete(probe); }
    }

    async Task SendInputAsync(string command)
    {
        if (!await inputGate.WaitAsync(TimeSpan.FromSeconds(2))) throw new TimeoutException("编码器控制通道繁忙");
        try
        {
            var current = process;
            if (current == null || current.HasExited) return;
            await current.StandardInput.WriteAsync(command).WaitAsync(TimeSpan.FromSeconds(2));
            await current.StandardInput.FlushAsync().WaitAsync(TimeSpan.FromSeconds(2));
        }
        finally { inputGate.Release(); }
    }

    async Task UpdatePreviewGateAsync()
    {
        int wanted = PreviewEnabled ? 1 : 0;
        if (stopping || wanted == previewGateState) return;
        await SendInputAsync($"cselect@preview -1 expr {wanted}\n");
        previewGateState = wanted;
    }

    async Task WatchHealthAsync(CancellationToken token)
    {
        try
        {
            var healthInterval = Stopwatch.StartNew();
            while (true)
            {
                await Task.Delay(TimeSpan.FromMilliseconds(200), token);
                try
                {
                    await UpdatePreviewGateAsync();
                    if (healthInterval.Elapsed.TotalSeconds < 2) continue;
                    healthInterval.Restart();
                    CheckHealth();
                }
                catch (Exception ex)
                {
                    Failure ??= ex.Message;
                    try { await StopAsync(Failure); } catch { /* StopCore persists the recoverable failure. */ }
                    return;
                }
            }
        }
        catch (OperationCanceledException) when (token.IsCancellationRequested) { }
    }

    async Task StopInputsAsync()
    {
        // Establish the audio stop boundary immediately, before waiting for encoder drain.
        Task audioStop = systemAudio ? audio.StopAsync() : Task.CompletedTask;
        try
        {
        if (process != null)
        {
            try
            {
                if (!process.HasExited)
                {
                    await SendInputAsync("q\n");
                    try { await process.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(20)); }
                    catch (TimeoutException) { process.Kill(entireProcessTree: true); await process.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(5)); Failure ??= "编码进程未及时结束，已保留碎片文件"; }
                }
                await process.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(5));
                if (process.ExitCode != 0) Failure ??= "桌面采集异常退出";
            }
            catch (InvalidOperationException) { /* Process.Start can fail before a process exists. */ }
            catch (Exception ex) when (ex is IOException or TimeoutException) { Failure ??= "无法正常通知编码器停止"; if (!process.HasExited) { process.Kill(true); await process.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(5)); } }
            finally
            {
                if (previewTask != null)
                {
                    try { await previewTask.WaitAsync(TimeSpan.FromSeconds(3)); }
                    catch (TimeoutException) { process.StandardOutput.Close(); Failure ??= "预览管道未及时结束"; }
                }
                lock (processGate)
                {
                    var ownedProcess = process;
                    process = null;
                    if (processExitTask?.IsCompleted == false)
                        _ = processExitTask.ContinueWith(_ => ownedProcess.Dispose());
                    else ownedProcess.Dispose();
                }
                logLines.Writer.TryComplete();
                if (logTask != null)
                {
                    try { await logTask.WaitAsync(TimeSpan.FromSeconds(3)); }
                    catch (TimeoutException) { Failure ??= "日志写入未及时结束"; }
                }
                // The log worker owns disposal, including after a timed-out disk write.
                log = null;
            }
        }
        }
        finally { await audioStop; }
    }

    async Task WriteLogAsync()
    {
        using var writer = log!;
        try
        {
            await foreach (string line in logLines.Reader.ReadAllAsync()) await writer.WriteLineAsync(line);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or ObjectDisposedException)
        { Failure ??= "录制日志写入失败：" + ex.Message; }
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
                    {
                        Interlocked.Increment(ref previewFrames);
                        if (PreviewEnabled)
                        {
                            try { Preview?.Invoke(jpeg.ToArray()); }
                            catch (Exception) { /* A preview subscriber must not terminate stdout draining or recording. */ }
                        }
                        inside = false;
                    }
                    if (jpeg.Length > 2_000_000) { inside = false; jpeg.SetLength(0); }
                    previous = value;
                }
        }
        catch (Exception ex) when (ex is IOException or ObjectDisposedException) { /* Closed during bounded encoder teardown. */ }
    }

    public async Task<string[]> RecoverUnfinishedAsync(string root)
    {
        stopping = true; // Recovery also retains ownership if its finalizer cannot exit.
        var outputs = new List<string>();
        if (!Directory.Exists(root)) return [];
        foreach (string take in Directory.EnumerateDirectories(root, "Take-*"))
        {
            string video = Path.Combine(take, "desktop-video.mp4");
            if (!File.Exists(video) || File.Exists(Path.Combine(take, "desktop.mp4"))) continue;
            FileStream? held = null;
            try
            {
                // Never recover an active take, including one owned by another app instance.
                string lockFile = Path.Combine(take, ".recording.lock");
                if (File.Exists(lockFile)) held = new FileStream(lockFile, FileMode.Open, FileAccess.Read, FileShare.None);
                using var source = new FileStream(video, FileMode.Open, FileAccess.Read, FileShare.Read);
                var media = await ProbeAsync(video);
                double duration = double.Parse(media.GetProperty("format").GetProperty("duration").GetString()!, CultureInfo.InvariantCulture);
                if (!double.IsFinite(duration) || duration <= 0) continue;
                CheckSpace(take, source.Length + (long)(duration * 24_000) + 512_000_000);
                var args = new List<string> { "-hide_banner", "-nostdin", "-n", "-i", video };
                bool withAudio = false;
                string reportPath = Path.Combine(take, "report.json");
                if (File.Exists(reportPath) && File.Exists(Path.Combine(take, "system-audio.wav")))
                {
                    using var report = JsonDocument.Parse(await File.ReadAllTextAsync(reportPath));
                    var data = report.RootElement;
                    if (data.TryGetProperty("videoStartUnix", out var start) && start.ValueKind == JsonValueKind.Number &&
                        data.TryGetProperty("audioStartUnix", out var audioStart) && audioStart.ValueKind == JsonValueKind.Number)
                    {
                        double offset = start.GetDouble() - audioStart.GetDouble();
                        if (offset >= 0 && offset <= 30)
                        {
                            args.AddRange(["-ss", N(offset), "-i", Path.Combine(take, "system-audio.wav"), "-map", "0:v:0", "-map", "1:a:0",
                                "-c:a", "aac", "-b:a", "192k", "-af", "apad"]);
                            withAudio = true;
                        }
                    }
                }
                if (!withAudio) args.AddRange(["-map", "0:v:0", "-an"]);
                string recovered = Path.Combine(take, "Recovery-" + DateTime.UtcNow.ToString("yyyyMMdd-HHmmss") + "-" + Guid.NewGuid().ToString("N")[..8]);
                Directory.CreateDirectory(recovered);
                string partial = Path.Combine(recovered, "desktop-partial.mp4");
                args.AddRange(["-c:v", "copy", "-t", N(duration), "-movflags", "+faststart", partial]);
                long recoveryBytes = checked(source.Length + (withAudio ? new FileInfo(Path.Combine(take, "system-audio.wav")).Length : 0));
                var recoveryBudget = FinalizationBudget.Calculate(recoveryBytes, duration, withAudio, true);
                await File.WriteAllTextAsync(Path.Combine(recovered, "report.json"), JsonSerializer.Serialize(new {
                    state = "recovering", source = take, finalizationPolicy = FinalizationBudget.Describe(recoveryBudget) }));
                var result = await RunAsync("ffmpeg.exe", args, recoveryBudget, monitorIo: true);
                await File.WriteAllTextAsync(Path.Combine(recovered, "recovery.log"), result.Error);
                if (result.Code != 0) throw new IOException("恢复副本失败，原素材未修改：" + take);
                var final = await ProbeAsync(partial);
                if (!final.GetProperty("streams").EnumerateArray().Any(x => x.GetProperty("codec_type").GetString() == "video"))
                    throw new IOException("恢复副本缺少视频轨道：" + take);
                string output = Path.Combine(recovered, "desktop.mp4");
                File.Move(partial, output);
                await File.WriteAllTextAsync(Path.Combine(recovered, "report.json"), JsonSerializer.Serialize(new {
                    state = "needs_review", source = take, output, withAudio, finalizationPolicy = FinalizationBudget.Describe(recoveryBudget),
                    note = withAudio ? "恢复副本，请核对音画和末尾" : "仅恢复视频；原音频保留，无法确认起点时不猜测同步",
                    updatedAt = DateTimeOffset.UtcNow }));
                outputs.Add(output);
            }
            catch (IOException ex) when (held == null && (ex.HResult & 0xffff) is 32 or 33)
            { /* An active take retains its exclusive lease. */ }
            finally
            {
                if (held != null && finalizerExitTask?.IsCompleted == false)
                    _ = ReleaseCleanupLeaseAsync(held, [finalizerExitTask]);
                else held?.Dispose();
            }
        }
        return outputs.ToArray();
    }

    public async Task<JsonElement> ProbeAsync(string path)
    {
        var result = await RunAsync("ffprobe.exe", ["-v", "error", "-show_streams", "-show_format", "-of", "json", path], TimeSpan.FromSeconds(30));
        if (result.Code != 0) throw new InvalidOperationException("无法读取媒体文件：" + result.Error);
        using var json = JsonDocument.Parse(result.Output); return json.RootElement.Clone();
    }
    public async Task<(int Code, string Output, string Error)> RunAsync(string name, IEnumerable<string> args, TimeSpan timeout, string? workingDirectory = null, bool monitorIo = false)
    {
        var command = new Process { StartInfo = StartInfo(name, monitorIo ? new[] { "-nostats", "-loglevel", "error" }.Concat(args) : args) };
        Task? exited = null;
        try
        {
            if (workingDirectory != null) command.StartInfo.WorkingDirectory = workingDirectory;
            command.Start();
            exited = command.WaitForExitAsync();
            if (monitorIo) finalizerExitTask = exited;
            var output = ReadBoundedTextAsync(command.StandardOutput); var error = ReadBoundedTextAsync(command.StandardError);
            try
            {
                if (monitorIo) await FinalizationBudget.WaitAsync(exited, () => ProcessIoBytes(command), timeout);
                else await exited.WaitAsync(timeout);
            }
            catch
            {
                if (!command.HasExited) { command.Kill(true); await exited.WaitAsync(TimeSpan.FromSeconds(5)); }
                throw;
            }
            return (command.ExitCode, await output, await error);
        }
        finally
        {
            if (exited?.IsCompleted == false) _ = exited.ContinueWith(_ => command.Dispose());
            else command.Dispose();
        }
    }

    static ulong ProcessIoBytes(Process command)
    {
        if (command.HasExited) return 0;
        if (!GetProcessIoCounters(command.Handle, out var io))
        {
            if (command.HasExited) return 0;
            throw new IOException("无法读取素材处理进度，停止并保留原素材");
        }
        return io.ReadTransferCount + io.WriteTransferCount;
    }
    [System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)]
    struct IoCounters
    {
        public ulong ReadOperationCount, WriteOperationCount, OtherOperationCount;
        public ulong ReadTransferCount, WriteTransferCount, OtherTransferCount;
    }
    [System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError = true)]
    [return: System.Runtime.InteropServices.MarshalAs(System.Runtime.InteropServices.UnmanagedType.Bool)]
    static extern bool GetProcessIoCounters(IntPtr process, out IoCounters counters);

    static async Task<string> ReadBoundedTextAsync(StreamReader reader)
    {
        const int limit = 1_000_000;
        var text = new System.Text.StringBuilder();
        char[] buffer = new char[4096]; int count;
        bool truncated = false;
        while ((count = await reader.ReadAsync(buffer)) > 0)
        {
            int keep = Math.Min(count, limit - text.Length);
            if (keep > 0) text.Append(buffer, 0, keep);
            if (keep < count) truncated = true;
        }
        if (truncated) text.Append("\n[diagnostic output truncated at 1 MB]\n");
        return text.ToString();
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
        File.WriteAllText(temporary, JsonSerializer.Serialize(new { state, platform = "windows", mode = "desktop", videoStartUnix, audioStartUnix = audio.OriginUnix, quality, qualityVersion = 1, systemAudio, outputProfile, outputWidth = outputSize.Width, outputHeight = outputSize.Height, framesPerSecond = 30, captureBackend, captureProbe, encoder, encoderProbe, previewGateSupported, previewGateState, encoderThreads, resourcePolicy = "experimental unmeasured caps; startup estimate is conservative admission heuristic, not a measured peak guarantee", startupCommitBudgetBytes = startupCommitBudget, runtimeCommitSafetyFloorBytes = ResourceBudget.SafetyFloor, filterThreads = 1, inputQueuePackets = 3, lookaheadFrames = 10, diagnostics = new { droppedLogLines = Interlocked.Read(ref droppedLogLines), writtenFrames = Interlocked.Read(ref writtenFrames), encoderDuplicatedFrames = Interlocked.Read(ref duplicatedFrames), encoderDroppedFrames = Interlocked.Read(ref droppedFrames), capturedFrames = (long?)null, scheduledFrames = (long?)null, note = "FFmpeg output progress only; source admission and queue counters unavailable for the selected FFmpeg capture backend" }, targetVideoBitRate, captureBounds, finalizationPolicy, cleanupPending = CleanupPending, device = audio.DeviceName, details, updatedAt = DateTimeOffset.UtcNow }, new JsonSerializerOptions { WriteIndented = true }));
        File.Move(temporary, path, true);
    }
    static string N(object value) => Convert.ToString(value, CultureInfo.InvariantCulture)!;
    public static void CheckSpace(string path, long minimum)
    {
        var drive = new DriveInfo(Path.GetPathRoot(Path.GetFullPath(path))!);
        if (drive.AvailableFreeSpace < minimum) throw new IOException($"磁盘可用空间不足 {minimum / 1_000_000_000} GB");
    }
}
