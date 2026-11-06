using System.Globalization;
using System.Text.RegularExpressions;
using Microsoft.Win32;

namespace ZSirCapture;

internal sealed record CameraDevice(string Id, string Name)
{
    public override string ToString() => Name;
}
internal sealed record CameraFormat(string? Vcodec, string? PixelFormat, int Width, int Height, double Fps);

internal static class CameraDevices
{
    internal const string NoCamera = "未检测到摄像头，请连接摄像头后点击重新检测";
    internal static bool SmokeTestEnabled { get; set; }
    internal static bool Fake => SmokeTestEnabled && Environment.GetEnvironmentVariable("ZSIR_FAKE_CAMERA") == "1";
    // Match payloads without depending on FFmpeg log prefixes (dshow, in#0, or none).
    internal static List<CameraDevice> ParseDevices(string text)
    {
        var devices = new List<CameraDevice>();
        string? name = null;
        foreach (string line in text.Split('\n'))
        {
            var device = Regex.Match(line, "\\\"([^\\\"]+)\\\" \\(video\\)");
            if (device.Success) { name = device.Groups[1].Value; continue; }
            var alternative = Regex.Match(line, "Alternative name \\\"([^\\\"]+)\\\"");
            if (name != null && alternative.Success)
            {
                string id = alternative.Groups[1].Value;
                if (!devices.Any(d => d.Id == id)) devices.Add(new(id, name));
                name = null;
            }
            else if (line.Contains("(audio)")) name = null;
        }
        return devices;
    }
    internal static List<CameraFormat> ParseFormats(string text)
    {
        var formats = new List<CameraFormat>();
        foreach (string line in text.Split('\n'))
        {
            var codec = Regex.Match(line, @"\b(vcodec|pixel_format)=(\w+)");
            if (!codec.Success) continue;
            foreach (Match size in Regex.Matches(line, @"s=(\d+)x(\d+)\s+fps=([\d.]+)"))
            {
                if (!int.TryParse(size.Groups[1].Value, out int w) || !int.TryParse(size.Groups[2].Value, out int h) ||
                    !double.TryParse(size.Groups[3].Value, NumberStyles.Float, CultureInfo.InvariantCulture, out double fps) ||
                    w < 2 || h < 2 || w > 32768 || h > 32768 || !double.IsFinite(fps) || fps <= 0) continue;
                var format = new CameraFormat(codec.Groups[1].Value == "vcodec" ? codec.Groups[2].Value : null,
                    codec.Groups[1].Value == "pixel_format" ? codec.Groups[2].Value : null, w, h, fps);
                if (!formats.Contains(format)) formats.Add(format);
            }
        }
        return formats;
    }
    internal static CameraFormat ChooseFormat(IEnumerable<CameraFormat> formats)
    {
        var candidates = formats.Where(f => f.Width <= 1920 && f.Height <= 1080);
        int Rank(CameraFormat f) => f.Vcodec == "mjpeg" && f.Fps >= 30 && f.Width == 1920 && f.Height == 1080 ? 0 :
            f.Vcodec == "mjpeg" && f.Fps >= 30 && f.Width == 1280 && f.Height == 720 ? 1 : f.PixelFormat != null && f.Fps >= 30 ? 2 : 3;
        var best = candidates.OrderBy(Rank).ThenByDescending(f => (long)f.Width * f.Height).ThenByDescending(f => f.Fps).FirstOrDefault()
            ?? throw new InvalidOperationException("摄像头未提供可用的 1080p 以内格式，请更换摄像头或驱动后重新检测");
        return best with { Fps = Math.Min(30, best.Fps) };
    }
    internal static async Task<List<CameraDevice>> DiscoverAsync(string tools)
    {
        if (Fake) return [new("zsir-fake-camera", "测试摄像头")];
        var result = await new Recorder(tools).RunAsync("ffmpeg.exe", ["-hide_banner", "-list_devices", "true", "-f", "dshow", "-i", "dummy"], TimeSpan.FromSeconds(10));
        return ParseDevices(result.Error + "\n" + result.Output);
    }
    internal static async Task<List<CameraFormat>> FormatsAsync(string tools, CameraDevice device)
    {
        if (Fake && device.Id == "zsir-fake-camera") return [new("mjpeg", null, 1280, 720, 30)];
        var result = await new Recorder(tools).RunAsync("ffmpeg.exe", ["-hide_banner", "-list_options", "true", "-f", "dshow", "-i", "video=" + device.Id], TimeSpan.FromSeconds(10));
        if (ParseFormats(result.Error).Count == 0) throw new IOException(Error(result.Error));
        return ParseFormats(result.Error);
    }
    internal static async Task<CameraDevice> ResolveAsync(string tools, string id)
    {
        var devices = await DiscoverAsync(tools);
        if (devices.Count == 0) throw new InvalidOperationException(NoCamera);
        return (id.Length == 0 ? devices[0] : devices.FirstOrDefault(d => d.Id == id))
            ?? throw new InvalidOperationException("所选摄像头已断开，请连接原摄像头或在设置中重新选择");
    }
    internal static string[] Input(CameraDevice device, CameraFormat format) => Fake && device.Id == "zsir-fake-camera"
        // Keep native pacing and a fixed Unix epoch; zero burst selects FFmpeg's 0.5 s default.
        ? ["-re", "-readrate_initial_burst", "0.001", "-readrate_catchup", "1", "-f", "lavfi", "-i",
            "color=c=0x204060:size=1280x720:rate=30,setpts=PTS+ceil(RTCSTART/(TB*1000000))"]
        : ["-f", "dshow", "-rtbufsize", "512M", "-use_wallclock_as_timestamps", "1",
            ..(format.Vcodec != null ? new[] { "-vcodec", format.Vcodec } : new[] { "-pixel_format", format.PixelFormat! }),
            "-video_size", $"{format.Width}x{format.Height}", "-framerate", format.Fps.ToString(CultureInfo.InvariantCulture), "-i", "video=" + device.Id];
    internal static string Error(string log) => new[] { "Could not run graph", "I/O error", "Device or resource busy" }.Any(s => log.Contains(s, StringComparison.OrdinalIgnoreCase))
        ? "摄像头正被其他应用（如会议软件）占用" : "无法启动摄像头，请重新检测设备并检查 Windows 隐私设置；详情见 camera-capture.log";
}

internal static class CapturePrivacy
{
    internal static string? Value(string capability, bool desktop)
    {
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\" + capability + (desktop ? @"\NonPackaged" : ""));
            return key?.GetValue("Value") as string;
        }
        catch (Exception ex) when (ex is System.Security.SecurityException or UnauthorizedAccessException or IOException) { return "unknown"; }
    }
    internal static void Check(string capability)
    {
        if (new[] { Value(capability, false), Value(capability, true) }.Any(v => string.Equals(v, "Deny", StringComparison.OrdinalIgnoreCase)))
            throw new InvalidOperationException("Windows 隐私设置禁止桌面应用使用" + (capability == "webcam" ? "摄像头" : "麦克风"));
    }
}
