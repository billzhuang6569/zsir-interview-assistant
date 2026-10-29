using System.Text.Json;

namespace ZSirCapture;
internal sealed class RecordingOptions
{
    public string ScreenId { get; set; } = "";
    public string AudioId { get; set; } = "";
    public string Quality { get; set; } = "standard";
    public string OutputProfile { get; set; } = "balanced";
    public bool SystemAudio { get; set; } = true;
    internal const int FramesPerSecond = 30;
    internal static (int Width, int Height) OutputSize(string profile, int width, int height)
    {
        if (width < 2 || height < 2 || width > 32768 || height > 32768) throw new ArgumentOutOfRangeException(nameof(width));
        int longestEdge = profile switch { "balanced" => 1920, "detailed" => 2560, _ => Math.Max(width, height) };
        double scale = Math.Min(1, (double)longestEdge / Math.Max(width, height));
        return (Math.Max(2, (int)(width * scale) / 2 * 2), Math.Max(2, (int)(height * scale) / 2 * 2));
    }
    internal static int BitRate(string quality, int width, int height)
    {
        if (width < 2 || height < 2 || width > 32768 || height > 32768) throw new ArgumentOutOfRangeException(nameof(width));
        double basis = quality switch { "compact" => 6_000_000, "high" => 18_000_000, _ => 12_000_000 };
        double rate = basis * Math.Max(1, (double)(width / 2 * 2) * (height / 2 * 2) / 2_073_600);
        if (!double.IsFinite(rate) || rate > int.MaxValue) throw new ArgumentOutOfRangeException(nameof(quality));
        return (int)rate;
    }
    static string PathName => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "ZSirCapture", "recording-settings.json");
    internal static RecordingOptions Load()
    {
        if (!File.Exists(PathName)) return new();
        try
        {
            string json = File.ReadAllText(PathName);
            var result = JsonSerializer.Deserialize<RecordingOptions>(json) ?? new();
            using var document = JsonDocument.Parse(json);
            if (document.RootElement.ValueKind == JsonValueKind.Object && !document.RootElement.TryGetProperty(nameof(OutputProfile), out _))
                result.OutputProfile = "native";
            return result;
        }
        catch (JsonException) { return new(); }
    }
    internal void Save()
    {
        Directory.CreateDirectory(Path.GetDirectoryName(PathName)!);
        File.WriteAllText(PathName + ".tmp", JsonSerializer.Serialize(this));
        File.Move(PathName + ".tmp", PathName, true);
    }
}
