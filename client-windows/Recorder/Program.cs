using System.Diagnostics;
using System.Globalization;
using System.Text.Json;
using System.Text.Encodings.Web;
using NAudio.CoreAudioApi;
using Windows.Devices.Enumeration;
using ZsirRecorder.Shared;

namespace ZsirRecorder;

internal record RecorderError(string code, string message, string? track = null, string level = "error");
internal record Device(string id, string name);
internal record Display(string id, string name, int width, int height);
internal record Devices(Device[] cameras, Device[] mics, Display[] displays);
internal sealed record Options(string Command, string Output, string[] Tracks, string? Camera, string? Mic, string? Display, double Duration, string Quality, bool StdinControl = false)
{
    internal static Options Parse(string[] args)
    {
        if (args.Length == 0 || !new[] { "devices", "preflight", "capture" }.Contains(args[0]))
            throw new ArgumentException("USAGE: devices --json | preflight --json [--camera id --mic id --display id] | capture --out <dir> [--tracks cam,screen --duration seconds --quality saver|recommended|high]");
        var values = new Dictionary<string, string>();
        var seen = new HashSet<string>();
        for (int i = 1; i < args.Length; i++)
        {
            string key = args[i];
            if (!seen.Add(key)) throw new ArgumentException("ARGUMENT_INVALID: 重复参数: " + key);
            if (key == "--stdin-control" && args[0] == "capture") continue;
            if (key == "--json" && args[0] != "capture") continue;
            string[] allowed = args[0] == "devices" ? [] : args[0] == "preflight" ? ["--camera", "--mic", "--display"] : ["--out", "--tracks", "--camera", "--mic", "--display", "--duration", "--quality"];
            if (!allowed.Contains(key) || ++i >= args.Length || !values.TryAdd(key, args[i]))
                throw new ArgumentException("ARGUMENT_INVALID: 未知、重复或缺少值的参数: " + key);
        }
        var tracks = values.GetValueOrDefault("--tracks", "cam,screen").Split(',');
        if (tracks.Length == 0 || tracks.Distinct().Count() != tracks.Length || tracks.Any(t => t != "cam" && t != "screen")) throw new ArgumentException("TRACKS_INVALID: 使用 cam、screen 或 cam,screen。");
        string quality = values.GetValueOrDefault("--quality", "recommended");
        if (!new[] { "saver", "recommended", "high" }.Contains(quality)) throw new ArgumentException("QUALITY_INVALID: 使用 saver、recommended 或 high。");
        double duration = double.PositiveInfinity;
        if (values.TryGetValue("--duration", out var text) && (!double.TryParse(text, NumberStyles.Float, CultureInfo.InvariantCulture, out duration) || !double.IsFinite(duration) || duration <= 0)) throw new ArgumentException("DURATION_INVALID: 时长须为有限正数。");
        if (args[0] == "capture" && !values.ContainsKey("--out")) throw new ArgumentException("OUTPUT_REQUIRED: capture 需要 --out <dir>。");
        return new(args[0], values.GetValueOrDefault("--out", ""), tracks, values.GetValueOrDefault("--camera"), values.GetValueOrDefault("--mic"), values.GetValueOrDefault("--display"), duration, quality, seen.Contains("--stdin-control"));
    }
}

internal sealed class Track : IAsyncDisposable
{
    internal required string Name;
    internal required VideoSource Video;
    internal required AudioSource Audio;
    internal Encoder? Encoder;
    internal EncoderChoice? Choice;
    internal int Width, Height, Fps, Kbps;
    public async ValueTask DisposeAsync()
    {
        if (Encoder != null) await Encoder.DisposeAsync();
        Audio.Dispose(); await Video.DisposeAsync();
    }
}

internal sealed class DetachedWriter(TextWriter inner) : TextWriter
{
    public override System.Text.Encoding Encoding => inner.Encoding;
    public override void WriteLine(string? value) { try { inner.WriteLine(value); } catch (IOException) { } }
}

internal static class Program
{
    static readonly JsonSerializerOptions Json = new() { PropertyNamingPolicy = JsonNamingPolicy.CamelCase, Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping };
    internal static void Print(object value)
    {
        // A detached GUI closes its pipe; status output must never stop capture.
        try { Console.WriteLine(JsonSerializer.Serialize(value, Json)); } catch (IOException) { }
    }
    internal static async Task<bool> ReadControl(TextReader input, Action stop)
    {
        try { while (await input.ReadLineAsync() is { } line) if (line.Trim() == "stop") { stop(); return true; } }
        catch (IOException) { } // Parent exit/EOF leaves capture running during the grace period.
        return false;
    }
    static async Task<Devices> GetDevices()
    {
        var cameras = (await DeviceInformation.FindAllAsync(DeviceClass.VideoCapture)).Select(d => new Device(d.Id, d.Name)).ToArray();
        using var enumerator = new MMDeviceEnumerator();
        var mics = new List<Device>();
        foreach (var endpoint in enumerator.EnumerateAudioEndPoints(DataFlow.Capture, DeviceState.Active))
        { using (endpoint) mics.Add(new(endpoint.ID, endpoint.FriendlyName)); }
        var displays = new List<Display>();
        Native.EnumDisplayMonitors(0, 0, (nint monitor, nint dc, ref Native.Rect rect, nint data) =>
        { displays.Add(new(monitor.ToInt64().ToString(CultureInfo.InvariantCulture), $"显示器 {displays.Count + 1}", rect.Right - rect.Left, rect.Bottom - rect.Top)); return true; }, 0);
        return new(cameras, mics.ToArray(), displays.ToArray());
    }
    static Device Select(Device[] values, string? id, string code, string help) =>
        (id == null ? values.FirstOrDefault() : values.FirstOrDefault(d => d.id == id)) ?? throw new IOException($"{code}: {help}");

    static async Task<Track> Open(string name, Options options, Devices devices)
    {
        VideoSource? video = null;
        AudioSource? audio = null;
        try
        {
            if (name == "cam")
            {
                var cam = Select(devices.cameras, options.Camera, "CAM_NOT_FOUND", "未找到摄像头，请连接摄像头后重试。");
                if (devices.mics.Length == 0) throw new IOException("MIC_NOT_FOUND: 未找到话筒，请连接话筒后重试。");
                if (options.Mic != null) Select(devices.mics, options.Mic, "MIC_NOT_FOUND", "所选话筒已不可用。");
                video = await VideoSource.Camera(cam.id, cam.name, options.Quality);
                audio = new(false, options.Mic);
            }
            else
            {
                if (Process.GetCurrentProcess().SessionId == 0)
                    throw new IOException("INTERACTIVE_SESSION_REQUIRED: 屏幕录制须在已登录桌面运行。SSH 会话请使用交互式计划任务，不能直接录制服务桌面。");
                var display = (options.Display == null ? devices.displays.FirstOrDefault() : devices.displays.FirstOrDefault(d => d.id == options.Display))
                    ?? throw new IOException("DISPLAY_NOT_FOUND: 当前会话没有所选显示器，请在已登录桌面运行。");
                video = await VideoSource.Screen((nint)long.Parse(display.id, CultureInfo.InvariantCulture));
                audio = new(true, null);
            }
            audio.Start();
            return new Track { Name = name, Video = video, Audio = audio };
        }
        catch { audio?.Dispose(); if (video != null) await video.DisposeAsync(); throw; }
    }

    internal static (int Width, int Height, int Fps, int Kbps) Format(string track, int width, int height, string quality)
    {
        int maxWidth = track == "cam" ? (quality == "high" ? 3840 : 1920) : quality == "high" ? width : quality == "saver" ? 1920 : 2560;
        double scale = Math.Min(1, maxWidth / (double)width);
        if (track == "cam") scale = Math.Min(scale, (quality == "high" ? 2160 : 1080) / (double)height);
        return (Math.Max(2, (int)(width * scale) / 2 * 2), Math.Max(2, (int)(height * scale) / 2 * 2), track == "screen" && quality == "saver" ? 15 : 30,
            quality == "high" ? track == "cam" ? 20000 : 16000 : quality == "saver" ? track == "cam" ? 6000 : 5000 : 10000);
    }

    static string ErrorText(RecorderError error) => error.message.StartsWith(error.code + ":") ? error.message : error.code + ": " + error.message;
    static object TrackInfo(Track t, double elapsed, long t0) => new {
        ok = t.Encoder!.Frames > 0 && t.Video.Error == null && t.Audio.Error == null,
        width = t.Width, height = t.Height, fps = t.Encoder.Frames / Math.Max(.001, elapsed), targetFPS = t.Fps,
        bytes = File.Exists(t.Encoder.PathName) ? new FileInfo(t.Encoder.PathName).Length : 0,
        levelDb = t.Audio.LevelDb, audioSamples = t.Encoder.AudioSamples, droppedSamples = 0,
        firstPTS = t.Encoder.Frames > 0 ? (double?)(t0 / (double)Stopwatch.Frequency) : null,
        firstFrameOffsetMs = t.Encoder.Frames > 0 ? (double?)0 : null
    };
    static object Status(List<Track> tracks, double elapsed, long t0) => new {
        t = elapsed, tracks = tracks.ToDictionary(t => t.Name, t => TrackInfo(t, elapsed, t0)),
        levels = tracks.ToDictionary(t => t.Name, t => t.Audio.LevelDb)
    };
    static async Task WriteSession(string output, List<Track> tracks, Options options, long t0, DateTimeOffset startedAt, string state, double elapsed, string? error = null)
    {
        var devices = new Dictionary<string, string>();
        foreach (var track in tracks) {
            devices[track.Name == "cam" ? "camera" : "display"] = track.Video.Name;
            devices[track.Name == "cam" ? "mic" : "systemAudio"] = track.Audio.Name;
        }
        var session = new {
            version = VersionInfo.Version, state, startedAt, clock = "QueryPerformanceCounter", hostTimeT0 = t0 / (double)Stopwatch.Frequency,
            quality = options.Quality, encoder = string.Join(", ", tracks.Select(t => t.Choice!.Name + (t.Choice.Software ? " (software)" : " (hardware)")).Distinct()),
            devices, t = elapsed, tracks = tracks.ToDictionary(t => t.Name, t => TrackInfo(t, elapsed, t0)), levels = tracks.ToDictionary(t => t.Name, t => t.Audio.LevelDb), error
        };
        string temporary = Path.Combine(output, ".session.json.tmp");
        await File.WriteAllTextAsync(temporary, JsonSerializer.Serialize(session, Json));
        File.Move(temporary, Path.Combine(output, "session.json"), true);
    }
    static long FreeBytes(string path) => new DriveInfo(Path.GetPathRoot(Path.GetFullPath(path))!).AvailableFreeSpace;
    static RecorderError Failure(Exception ex, string? track = null)
    {
        string message = ex.Message;
        int colon = message.IndexOf(':');
        string code = colon > 0 && message[..colon].All(c => char.IsAsciiLetterUpper(c) || c == '_') ? message[..colon] : "CAPTURE_FAILED";
        return new(code, message, track);
    }

    static async Task<int> Main(string[] args)
    {
        Console.OutputEncoding = System.Text.Encoding.UTF8;
        Console.SetError(new DetachedWriter(Console.Error));
        try
        {
            var options = Options.Parse(args);
            var devices = await GetDevices();
            if (options.Command == "devices") { Print(devices); return 0; }
            bool preflight = options.Command == "preflight";
            string output = preflight ? Path.Combine(Path.GetTempPath(), "zsir-preflight-" + Guid.NewGuid().ToString("N")) : Path.GetFullPath(options.Output);
            Directory.CreateDirectory(output);
            // CreateNew prevents two recorders from racing into the same session or replacing evidence.
            using var reservation = new FileStream(Path.Combine(output, ".recording.lock"), FileMode.CreateNew, FileAccess.Write, FileShare.None, 1, FileOptions.DeleteOnClose);
            if (new[] { "cam.mp4", "screen.mp4", "session.json" }.Any(f => File.Exists(Path.Combine(output, f)))) throw new IOException("OUTPUT_EXISTS: 目录已有录制文件，请使用新目录。");
            var tracks = new List<Track>();
            var errors = new List<RecorderError>();
            try
            {
                if (FreeBytes(output) < 2L * 1024 * 1024 * 1024) throw new IOException("DISK_CRITICAL: 剩余空间不足 2 GB，未开始录制。");
                foreach (var name in preflight ? new[] { "cam", "screen" } : options.Tracks)
                {
                    try { tracks.Add(await Open(name, options, devices)); }
                    catch (Exception ex) { if (!preflight) throw; errors.Add(Failure(ex, name)); }
                }
                bool exclusion = Native.TestWindowExclusion();
                if (!exclusion) Console.Error.WriteLine("WINDOW_EXCLUSION_UNAVAILABLE: 本系统或会话未通过隐藏测试窗口的排除 API 检查。");
                foreach (var track in tracks.ToArray())
                {
                    try
                    {
                        (track.Width, track.Height, track.Fps, track.Kbps) = Format(track.Name, track.Video.Width, track.Video.Height, options.Quality);
                        var fallback = Format(track.Name, track.Video.Width, track.Video.Height, options.Quality == "high" ? "recommended" : "saver");
                        track.Choice = await Encoder.Probe((track.Width, track.Height, track.Fps), (fallback.Width, fallback.Height, fallback.Fps));
                        if (track.Choice.Software)
                        {
                            errors.Add(new("ENCODER_FALLBACK", "硬件编码不可用，使用 Media Foundation 软件 H.264。", track.Name, "warn"));
                            Console.Error.WriteLine("ENCODER_FALLBACK: 使用 Media Foundation 软件 H.264。");
                            (track.Width, track.Height, track.Fps, track.Kbps) = fallback;
                        }
                        track.Encoder = new(Path.Combine(output, track.Name + ".mp4"), track.Video, track.Width, track.Height, track.Fps, track.Kbps, track.Choice);
                    }
                    catch (Exception ex)
                    {
                        if (!preflight) throw;
                        errors.Add(Failure(ex, track.Name)); await track.DisposeAsync(); tracks.Remove(track);
                    }
                }
                bool recordingSucceeded = false;
                long t0 = Stopwatch.GetTimestamp();
                var startedAt = DateTimeOffset.UtcNow;
                double end = preflight ? 3 : options.Duration;
                using var abort = new CancellationTokenSource();
                using var power = new Native.PowerRequest();
                var cancelHandler = new ConsoleCancelEventHandler((_, e) => { e.Cancel = true; end = Math.Min(end, Stopwatch.GetElapsedTime(t0).TotalSeconds); });
                Console.CancelKeyPress += cancelHandler;
                if (options.StdinControl) _ = Task.Run(async () => {
                    void Stop() => end = Math.Min(end, Stopwatch.GetElapsedTime(t0).TotalSeconds);
                    if (!await ReadControl(Console.In, Stop)) { await Task.Delay(TimeSpan.FromSeconds(60)); Stop(); }
                });
                await WriteSession(output, tracks, options, t0, startedAt, "recording", 0);
                try
                {
                    var workers = tracks.SelectMany(t => {
                        t.Audio.Begin(t0);
                        return new[] { t.Encoder!.WriteVideo(t.Video, t0, () => end, t.Fps, abort.Token), t.Encoder.WriteAudio(t.Audio, t0, () => end, abort.Token) };
                    }).ToArray();
                    var all = Task.WhenAll(workers);
                    while (!all.IsCompleted)
                    {
                        await Task.WhenAny(all, Task.Delay(1000));
                        var failed = workers.FirstOrDefault(w => w.IsFaulted);
                        if (failed != null) { abort.Cancel(); try { await all; } catch { } await failed; }
                        double elapsed = Stopwatch.GetElapsedTime(t0).TotalSeconds;
                        if (tracks.Any(t => elapsed - t.Encoder!.Frames / (double)t.Fps > 15) || elapsed > end + 15) { abort.Cancel(); throw new TimeoutException("ENCODER_STALLED: 编码管道未能及时完成。"); }
                        if (FreeBytes(output) < 2L * 1024 * 1024 * 1024) { end = Math.Min(end, elapsed); if (!errors.Any(e => e.code == "DISK_CRITICAL")) { errors.Add(new("DISK_CRITICAL", "剩余空间不足 2 GB，已安全停止。")); Console.Error.WriteLine("DISK_CRITICAL: 剩余空间不足 2 GB，已安全停止。"); } }
                        if (!preflight) Print(Status(tracks, Math.Min(end, elapsed), t0));
                        await WriteSession(output, tracks, options, t0, startedAt, "recording", Math.Min(end, elapsed));
                    }
                    await all;
                    foreach (var t in tracks) await t.Encoder!.Finish();
                    recordingSucceeded = true;
                    await WriteSession(output, tracks, options, t0, startedAt, errors.Any(e => e.level == "error" && e.code != "CAM_NOT_FOUND") ? "failed" : "finished", Math.Min(end, Stopwatch.GetElapsedTime(t0).TotalSeconds), errors.FirstOrDefault(e => e.level == "error") is { } issue ? ErrorText(issue) : null);
                }
                catch (Exception ex) {
                    await WriteSession(output, tracks, options, t0, startedAt, "failed", Math.Min(end, Stopwatch.GetElapsedTime(t0).TotalSeconds), ex.Message);
                    if (!preflight) throw;
                    errors.Add(Failure(ex));
                }
                finally { abort.Cancel(); Console.CancelKeyPress -= cancelHandler; }
                if (preflight)
                {
                    object Summary(string name) {
                        var track = tracks.FirstOrDefault(t => t.Name == name);
                        return track == null || !recordingSucceeded ? new { ok = false } : TrackInfo(track, 3, t0);
                    }
                    Print(new { cam = Summary("cam"), screen = Summary("screen"), systemAudio = new { ok = recordingSucceeded && tracks.Any(t => t.Name == "screen" && t.Audio.Error == null) }, encoder = tracks.FirstOrDefault()?.Choice?.Name ?? "unverified", diskFreeBytes = FreeBytes(output), errors = errors.Select(ErrorText).ToArray(), windowExclusionApi = exclusion });
                }
                return errors.Any(e => e.level == "error") ? 1 : 0;
            }
            finally
            {
                foreach (var track in tracks) await track.DisposeAsync();
                reservation.Dispose();
                if (preflight) Directory.Delete(output, true);
            }
        }
        catch (Exception ex) {
            string[] errors = [ErrorText(Failure(ex))];
            if (args.FirstOrDefault() == "preflight") Print(new { cam = new { ok = false }, screen = new { ok = false }, systemAudio = new { ok = false }, encoder = "unverified", diskFreeBytes = FreeBytes(Path.GetTempPath()), errors });
            else Print(new { errors });
            return 1;
        }
    }
}
