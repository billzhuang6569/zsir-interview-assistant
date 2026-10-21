using System.Diagnostics;
using System.IO.Pipes;

namespace ZsirRecorder;

internal record EncoderChoice(string Name, bool Software)
{
    internal string[] Args => Name == "h264_mf"
        ? ["-c:v", Name, "-hw_encoding", Software ? "0" : "1", "-profile:v", "100"]
        : ["-c:v", Name, "-profile:v", "high"];
}

internal sealed class Encoder : IAsyncDisposable
{
    internal static string Binary => Path.Combine(AppContext.BaseDirectory, "ffmpeg", "ffmpeg.exe");
    internal readonly NamedPipeServerStream Video, Audio;
    readonly Process process;
    readonly Task<string> stderr;
    internal readonly string PathName;
    internal long Frames, AudioSamples;
    internal static ProcessStartInfo Info(IEnumerable<string> args)
    {
        if (!File.Exists(Binary)) throw new FileNotFoundException("FFMPEG_NOT_FOUND: 请先运行 scripts/fetch-ffmpeg.ps1。", Binary);
        var info = new ProcessStartInfo(Binary) { UseShellExecute = false, CreateNoWindow = true, RedirectStandardError = true, RedirectStandardOutput = true };
        foreach (var arg in args) info.ArgumentList.Add(arg);
        return info;
    }

    internal static async Task<EncoderChoice> Probe((int Width, int Height, int Fps) hardware, (int Width, int Height, int Fps) software)
    {
        foreach (var choice in new[] { new EncoderChoice("h264_nvenc", false), new("h264_qsv", false), new("h264_amf", false), new("h264_mf", false), new("h264_mf", true) })
        {
            var size = choice.Software ? software : hardware;
            using var process = Process.Start(Info(new[] { "-hide_banner", "-loglevel", "error", "-f", "lavfi", "-i", $"color=size={size.Width}x{size.Height}:rate={size.Fps}", "-frames:v", "3" }
                .Concat(choice.Args).Concat(["-pix_fmt", "nv12", "-f", "null", "-"])))!;
            var error = process.StandardError.ReadToEndAsync();
            _ = process.StandardOutput.ReadToEndAsync();
            try { await process.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(20)); }
            catch (TimeoutException) { process.Kill(true); await process.WaitForExitAsync(); }
            if (process.ExitCode == 0) return choice;
            Console.Error.WriteLine($"编码器探测 {choice.Name} (software={choice.Software}): {(await error).Trim()}");
        }
        throw new IOException("ENCODER_UNAVAILABLE: 所有 H.264 编码器均不可用，请安装显卡驱动或 Windows 媒体功能包。");
    }

    internal Encoder(string path, VideoSource video, int width, int height, int fps, int kbps, EncoderChoice choice)
    {
        PathName = path;
        string id = "zsir_" + Guid.NewGuid().ToString("N");
        Video = new(id + "_v", PipeDirection.Out, 1, PipeTransmissionMode.Byte, PipeOptions.Asynchronous, 0, 65536);
        Audio = new(id + "_a", PipeDirection.Out, 1, PipeTransmissionMode.Byte, PipeOptions.Asynchronous, 0, 65536);
        var args = new[] { "-hide_banner", "-loglevel", "warning", "-nostdin", "-n",
            "-thread_queue_size", "8", "-f", "rawvideo", "-pixel_format", "bgra", "-video_size", $"{video.Width}x{video.Height}", "-framerate", fps.ToString(), "-probesize", "32", "-analyzeduration", "0", "-i", @"\\.\pipe\" + id + "_v",
            "-thread_queue_size", "32", "-f", "f32le", "-ar", "48000", "-ac", "2", "-probesize", "32", "-analyzeduration", "0", "-i", @"\\.\pipe\" + id + "_a",
            "-map", "0:v", "-map", "1:a", "-vf", $"scale={width}:{height},format=nv12" }
            .Concat(choice.Args).Concat(new[] { "-b:v", $"{kbps}k", "-g", (fps * 2).ToString(), "-bf", "0", "-c:a", "aac", "-b:a", "256k", "-movflags", "+frag_keyframe+empty_moov+default_base_moof", "-frag_duration", "2000000", "-flush_packets", "1", path });
        try
        {
            process = Process.Start(Info(args))!;
            stderr = process.StandardError.ReadToEndAsync();
            _ = process.StandardOutput.ReadToEndAsync();
        }
        catch { Video.Dispose(); Audio.Dispose(); throw; }
    }

    internal async Task WriteVideo(VideoSource source, long t0, Func<double> end, int fps, CancellationToken token)
    {
        await Video.WaitForConnectionAsync(token);
        for (long index = 0; ; index++)
        {
            double at = index / (double)fps;
            if (at >= end()) break;
            await Until(t0, at, token);
            if (at >= end()) break;
            if (source.Error != null) throw source.Error;
            await Video.WriteAsync(Volatile.Read(ref source.Latest)!, token);
            Interlocked.Increment(ref Frames);
        }
        Video.Dispose();
    }
    internal async Task WriteAudio(AudioSource source, long t0, Func<double> end, CancellationToken token)
    {
        await Audio.WaitForConnectionAsync(token);
        for (long index = 0; ; index += 960)
        {
            double at = index / 48000.0;
            if (at >= end()) break;
            // Allow WASAPI's callback to deliver the chunk before reading its QPC slot.
            await Until(t0, at + .15, token);
            int count = (int)Math.Min(960, Math.Max(0, Math.Round((end() - at) * 48000)));
            if (count == 0) break;
            if (source.Error != null) throw source.Error;
            await Audio.WriteAsync(source.Read(index, count), token);
            Interlocked.Increment(ref AudioSamples);
        }
        Audio.Dispose();
    }
    internal static async Task Until(long t0, double seconds, CancellationToken token)
    {
        while (true)
        {
            double remaining = seconds - Stopwatch.GetElapsedTime(t0).TotalSeconds;
            if (remaining <= 0) return;
            await Task.Delay(TimeSpan.FromSeconds(Math.Min(remaining, .02)), token);
        }
    }
    internal async Task Finish()
    {
        await process.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(10));
        var errors = await stderr;
        if (process.ExitCode != 0) throw new IOException($"ENCODER_FAILED ({process.ExitCode}): {errors}");
        if (!string.IsNullOrWhiteSpace(errors)) Console.Error.WriteLine(errors.Trim());
    }
    public ValueTask DisposeAsync()
    {
        Video.Dispose(); Audio.Dispose();
        if (!process.HasExited) process.Kill(true);
        process.Dispose();
        return ValueTask.CompletedTask;
    }
}
