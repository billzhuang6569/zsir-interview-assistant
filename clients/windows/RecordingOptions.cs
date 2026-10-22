using System.Text.Json;

namespace ZSirCapture;
internal sealed class RecordingOptions
{
    public string ScreenId { get; set; } = "";
    public string AudioId { get; set; } = "";
    public string Quality { get; set; } = "standard";
    public bool SystemAudio { get; set; } = true;
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
        try { return JsonSerializer.Deserialize<RecordingOptions>(File.ReadAllText(PathName)) ?? new(); }
        catch (JsonException) { return new(); }
    }
    internal void Save()
    {
        Directory.CreateDirectory(Path.GetDirectoryName(PathName)!);
        File.WriteAllText(PathName + ".tmp", JsonSerializer.Serialize(this));
        File.Move(PathName + ".tmp", PathName, true);
    }
}
