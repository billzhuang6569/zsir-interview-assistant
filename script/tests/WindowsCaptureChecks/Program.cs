using System.Buffers;
using System.Diagnostics;
using System.IO.Pipes;
using System.Security.Cryptography;
using System.Text.Json;
using ZSirCapture;

static void Check(bool value, string message) { if (!value) throw new Exception(message); }
static byte[] Frame(CameraFramePipe pipe, byte value)
{
    var buffer = ArrayPool<byte>.Shared.Rent(pipe.FrameBytes);
    buffer.AsSpan(0, pipe.FrameBytes).Fill(value);
    return buffer;
}

var waiting = new CameraFramePipe(2, 2);
waiting.Offer(Frame(waiting, 1));
waiting.RequestStop();
await waiting.Completion.WaitAsync(TimeSpan.FromSeconds(2));
waiting.Offer(Frame(waiting, 2)); // A late callback must release its pooled buffer after stop.
var pipe = new CameraFramePipe(2, 2);
for (byte i = 0; i < 32; i++) pipe.Offer(Frame(pipe, i));
Check(pipe.DroppedFrames == 31, "Slow/disconnected encoder must retain only the latest pending frame");
using (var client = new NamedPipeClientStream(".", pipe.Path[(pipe.Path.LastIndexOf('\\') + 1)..], PipeDirection.In, PipeOptions.Asynchronous))
{
    await client.ConnectAsync().WaitAsync(TimeSpan.FromSeconds(2));
    var pixels = new byte[pipe.FrameBytes];
    await client.ReadExactlyAsync(pixels).AsTask().WaitAsync(TimeSpan.FromSeconds(2));
    Check(pixels.All(v => v == 31), "Named pipe returned a stale or partial frame");
    pipe.RequestStop();
    await pipe.Completion.WaitAsync(TimeSpan.FromSeconds(2));
    Check(await client.ReadAsync(pixels) == 0, "Stopping must close the encoder's input");
}
var blocked = new CameraFramePipe(320, 180);
using (var client = new NamedPipeClientStream(".", blocked.Path[(blocked.Path.LastIndexOf('\\') + 1)..], PipeDirection.In, PipeOptions.Asynchronous))
{
    await client.ConnectAsync().WaitAsync(TimeSpan.FromSeconds(2));
    blocked.Offer(Frame(blocked, 42));
    await Task.Delay(50); // The frame is larger than the pipe buffer and the client deliberately never reads.
    blocked.RequestStop();
    await blocked.Completion.WaitAsync(TimeSpan.FromSeconds(2));
}
Console.WriteLine("PASS shared-camera pipe: bounded latest frame, complete BGRA bytes, EOF, stop before connection, late callback");
if (args.Contains("--pipe-only")) return;

string root = Path.Combine(Path.GetTempPath(), "zsir-recovery-check-" + Guid.NewGuid().ToString("N"));
Directory.CreateDirectory(root);
try
{
    foreach (string name in new[] { "desktop-video.mp4", "camera-video.mp4", "system-audio.wav", "microphone.wav" })
        File.WriteAllBytes(Path.Combine(root, name), []);
    File.WriteAllText(Path.Combine(root, "report.json"), """{"mode":"both","videoStartUnix":101,"audioStartUnix":100,"tracks":{"desktop":{"videoStartUnix":100.25,"audioStartUnix":100},"camera":{"videoStartUnix":101.5,"audioStartUnix":101}}}""");
    var plans = RecoveryTrack.Find(root).ToArray();
    Check(plans.Length == 2 && plans[0].AudioOffset == .25 && plans[1].AudioOffset == .5, "Each legacy dual track must use its own clock");
    Check(plans[0].Audio.EndsWith("system-audio.wav") && plans[1].Audio.EndsWith("microphone.wav"), "Recovery crossed microphone/system audio");
    File.WriteAllText(Path.Combine(root, "camera-report.json"), """{"mode":"camera","videoStartUnix":102.75,"audioStartUnix":102}""");
    Check(RecoveryTrack.Find(root).Last().AudioOffset == .75, "Dedicated camera report must precede the parent's stale snapshot");
    foreach (string bad in new[] { "null", "[]", "broken", """{"mode":"camera","videoStartUnix":"bad","audioStartUnix":100}""", """{"mode":"camera","videoStartUnix":99,"audioStartUnix":100}""" })
    {
        File.WriteAllText(Path.Combine(root, "camera-report.json"), bad);
        File.WriteAllText(Path.Combine(root, "report.json"), bad);
        var camera = RecoveryTrack.Find(root).Last();
        Check(camera.AudioOffset == null && camera.AudioArguments().Contains("-an"), "Corrupt/missing/negative clocks must not invent audio alignment");
    }
    File.WriteAllText(Path.Combine(root, "report.json"), """{"mode":"camera","videoStartUnix":100.5,"audioStartUnix":100}""");
    Check(RecoveryTrack.Find(root).First().AudioOffset == null && RecoveryTrack.Find(root).Last().AudioOffset == .5, "Camera-only legacy report was reused as a desktop clock");
    File.WriteAllBytes(Path.Combine(root, "camera.mp4"), []);
    Check(RecoveryTrack.Find(root).Select(t => t.Name).SequenceEqual(["desktop"]), "Completed camera track must not be overwritten");
    File.Delete(Path.Combine(root, "camera.mp4"));
    File.Delete(Path.Combine(root, "camera-report.json"));
    Console.WriteLine("PASS recovery selection: camera-only/dual/legacy clocks, dedicated reports, audio isolation, corrupt metadata and completed-track protection");

    // Execute the production recovery mapping against two different audible fixtures.
    await Run("ffmpeg", ["-v", "error", "-y", "-f", "lavfi", "-i", "color=c=blue:s=64x64:r=30", "-t", "1", "-c:v", "libx264", "-movflags", "+frag_keyframe+empty_moov", Path.Combine(root, "camera-video.mp4")]);
    File.Copy(Path.Combine(root, "camera-video.mp4"), Path.Combine(root, "desktop-video.mp4"), true);
    foreach (var (name, frequency) in new[] { ("system-audio.wav", 440), ("microphone.wav", 880) })
        await Run("ffmpeg", ["-v", "error", "-y", "-f", "lavfi", "-i", $"sine=frequency={frequency}:sample_rate=48000", "-t", "2", Path.Combine(root, name)]);
    File.WriteAllText(Path.Combine(root, "report.json"), """{"mode":"both","tracks":{"desktop":{"videoStartUnix":100.25,"audioStartUnix":100},"camera":{"videoStartUnix":100.5,"audioStartUnix":100}}}""");
    var originals = Directory.GetFiles(root).ToDictionary(p => p, p => Convert.ToHexString(SHA256.HashData(File.ReadAllBytes(p))));
    foreach (var track in RecoveryTrack.Find(root))
    {
        string output = Path.Combine(root, track.Name + ".mp4");
        await Run("ffmpeg", ["-v", "error", "-n", "-i", track.Video, ..track.AudioArguments(), "-c:v", "copy", "-t", "1", output]);
        await Run("ffmpeg", ["-v", "error", "-xerror", "-i", output, "-f", "null", "-"]);
        string pcm = Path.Combine(root, track.Name + ".f32");
        await Run("ffmpeg", ["-v", "error", "-i", output, "-vn", "-ac", "1", "-ar", "48000", "-f", "f32le", pcm]);
        byte[] data = File.ReadAllBytes(pcm);
        double Energy(int frequency)
        {
            double re = 0, im = 0;
            for (int i = 0; i < data.Length / 4; i++)
            {
                double v = BitConverter.ToSingle(data, i * 4), angle = 2 * Math.PI * frequency * i / 48000;
                re += v * Math.Cos(angle); im += v * Math.Sin(angle);
            }
            return re * re + im * im;
        }
        int wanted = track.Name == "camera" ? 880 : 440;
        Check(data.Length > 100_000 && Energy(wanted) > Energy(wanted == 880 ? 440 : 880) * 100, "Recovered file contains the wrong sound source");
    }
    Check(originals.All(p => p.Value == Convert.ToHexString(SHA256.HashData(File.ReadAllBytes(p.Key)))), "Recovery changed source media or metadata");
    Console.WriteLine("PASS actual FFmpeg recovery mapping: desktop=440Hz system, camera=880Hz microphone; both decode; original SHA256 unchanged");
}
finally { Directory.Delete(root, true); }

static async Task Run(string name, string[] args)
{
    var info = new ProcessStartInfo(name) { UseShellExecute = false, RedirectStandardError = true, RedirectStandardOutput = true };
    foreach (string arg in args) info.ArgumentList.Add(arg);
    using var process = Process.Start(info)!;
    var errors = process.StandardError.ReadToEndAsync();
    var output = process.StandardOutput.ReadToEndAsync();
    try { await process.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(20)); }
    catch { process.Kill(true); throw; }
    await output;
    if (process.ExitCode != 0) throw new IOException(await errors);
}
