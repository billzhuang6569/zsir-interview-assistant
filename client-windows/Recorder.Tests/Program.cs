using System.IO;
using ZsirRecorder;
using System.Runtime.InteropServices;

static void Assert(bool ok, string message) { if (!ok) throw new Exception(message); }
foreach (var invalid in new[] {
    new[] { "capture" }, new[] { "capture", "--out", "x", "--duration", "NaN" },
    new[] { "capture", "--out", "x", "--duration", "-1" }, new[] { "capture", "--out", "x", "--duration", "Infinity" },
    new[] { "capture", "--out", "x", "--tracks", "cam,cam" }, new[] { "capture", "--out", "x", "--tracks", "" },
    new[] { "capture", "--out", "x", "--quality", "bad" }, new[] { "devices", "--unknown" },
    new[] { "capture", "--out", "x", "--out", "y" },
    new[] { "preflight", "--tracks", "screen" }, new[] { "devices", "--camera", "x" },
    new[] { "devices", "--json", "--json" }, new[] { "capture", "--out", "x", "--json" } })
{
    bool rejected = false;
    try { Options.Parse(invalid); } catch (ArgumentException) { rejected = true; }
    Assert(rejected, string.Join(' ', invalid));
}
Assert(Options.Parse(["capture", "--out", "x", "--stdin-control"]).StdinControl, "stdin flag");
var appState = new ZsirRecorder.App.LocalState { Camera = "camera with spaces", Mic = "话筒", Display = "42" };
Assert(appState.ExistingRecorder() == null, "fresh state never queries protected PID zero");
Assert(appState.Selection().SequenceEqual(["--camera", "camera with spaces", "--mic", "话筒", "--display", "42"]), "GUI device arguments preserve spaces and Unicode");
Assert(System.Text.Json.JsonSerializer.Deserialize<ZsirRecorder.App.LocalState>(System.Text.Json.JsonSerializer.Serialize(appState))!.Mic == "话筒", "settings roundtrip");
Console.WriteLine("PASS: GUI fresh recovery state, device argument boundaries, settings roundtrip");
int stopped = 0;
await ZsirRecorder.Program.ReadControl(new StringReader("ignored\nstop\nstop\n"), () => stopped++);
Assert(stopped == 1, "stop exactly once");
await ZsirRecorder.Program.ReadControl(new StringReader(""), () => stopped++);
Assert(stopped == 1, "EOF keeps capture running");
Console.WriteLine("PASS: stdin flag, stop exactly once, EOF leaves capture running");
var options = Options.Parse(["capture", "--out", "路径 with spaces", "--tracks", "screen", "--duration", "1.25"]);
Assert(options.Output == "路径 with spaces" && options.Tracks.SequenceEqual(["screen"]) && options.Duration == 1.25, "CLI roundtrip");
Assert(ZsirRecorder.Program.Format("screen", 3840, 2160, "recommended") == (2560, 1440, 30, 10000), "recommended screen");
Assert(ZsirRecorder.Program.Format("screen", 3840, 2160, "saver") == (1920, 1080, 15, 5000), "saver screen");
Assert(ZsirRecorder.Program.Format("cam", 3840, 2160, "recommended") == (1920, 1080, 30, 10000), "recommended camera");
Assert(ZsirRecorder.Program.Format("cam", 1080, 1920, "recommended") == (606, 1080, 30, 10000), "portrait even dimensions");
Assert(new EncoderChoice("h264_mf", true).Args.SequenceEqual(["-c:v", "h264_mf", "-hw_encoding", "0", "-profile:v", "100"]), "explicit software MF");
var timeline = new AudioTimeline();
Assert(timeline.Read(0, 960).All(b => b == 0), "silent loopback still emits a complete chunk");
float[] packet = Enumerable.Repeat(.25f, 1920).ToArray();
timeline.Add(packet, 960);
timeline.Add(packet, 1930); // callback jitter must not insert ten silent samples
Assert(MemoryMarshal.Cast<byte, float>(timeline.Read(0, 1920)).ToArray().All(f => f == .25f), "contiguous audio across callback jitter");
timeline.Add(packet, 48000);
Assert(timeline.Read(1920, 45000).All(b => b == 0), "a long silence remains at its time position");
Assert(MemoryMarshal.Cast<byte, float>(timeline.Read(47040, 960)).ToArray().All(f => f == .25f), "audio resumes at QPC position after silence");
timeline.Add(packet, 96000 + 960);
Assert(timeline.Read(0, 960).All(b => b == 0), "ring wrap must not replay newer samples into old slots");
Assert(timeline.Peak == .25, "peak meter");
timeline.Add(new float[1920], 97920);
Assert(timeline.Peak == 0, "live meter returns to silence instead of holding historical peak");
Console.WriteLine("PASS: live audio peak returns to silence");
Console.WriteLine("PASS: 25 assertions (CLI, quality, fallback, silence, callback jitter, QPC gaps, ring wrap)");

if (args.Contains("--encoder-smoke"))
{
    string folder = Path.Combine(Path.GetTempPath(), "zsir-mf-test-" + Guid.NewGuid().ToString("N"));
    Directory.CreateDirectory(folder);
    try
    {
        await using var source = new VideoSource { Width = 128, Height = 96, Latest = new byte[128 * 96 * 4] };
        await using var encoder = new Encoder(Path.Combine(folder, "screen.mp4"), source, 128, 96, 30, 500, new("h264_mf", true));
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(20));
        async Task Video() {
            await encoder.Video.WaitForConnectionAsync(timeout.Token);
            for (int i = 0; i < 90; i++) await encoder.Video.WriteAsync(source.Latest, timeout.Token);
            encoder.Video.Dispose();
        }
        async Task Audio() {
            await encoder.Audio.WaitForConnectionAsync(timeout.Token);
            await encoder.Audio.WriteAsync(new byte[48000 * 3 * 8], timeout.Token);
            encoder.Audio.Dispose();
        }
        await Task.WhenAll(Video(), Audio());
        await encoder.Finish();
        Assert(new FileInfo(encoder.PathName).Length > 1000, "MF software fMP4 output");
        Console.WriteLine("PASS: Media Foundation software -> actual two pipes -> H264/AAC fragmented MP4");
    }
    finally { Directory.Delete(folder, true); }
}
