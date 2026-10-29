using ZSirCapture;

static void Check(bool value, string description)
{
    if (!value) throw new Exception(description);
}
// Run with XDG_DATA_HOME set to a throwaway directory; never alter user settings.
var root = Environment.GetEnvironmentVariable("XDG_DATA_HOME");
Check(!string.IsNullOrEmpty(root) && Path.IsPathFullyQualified(root), "Set XDG_DATA_HOME to an absolute temporary directory");
root = Path.Combine(Path.GetFullPath(root!), "zsir-options-check-" + Guid.NewGuid().ToString("N"));
Directory.CreateDirectory(root);
Environment.SetEnvironmentVariable("XDG_DATA_HOME", root);
Check(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData) == root, "This harness requires Linux XDG isolation");
var settings = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "ZSirCapture", "recording-settings.json");
Directory.CreateDirectory(Path.GetDirectoryName(settings)!);
Check(!File.Exists(settings), "unique test directory must not contain existing settings");
Check(RecordingOptions.Load().OutputProfile == "balanced", "fresh install defaults balanced");
File.WriteAllText(settings, "{\"Quality\":\"high\",\"SystemAudio\":false}");
var migrated = RecordingOptions.Load();
Check(migrated.OutputProfile == "native" && migrated.Quality == "high" && !migrated.SystemAudio, "legacy settings preserve native resolution and preferences");
migrated.OutputProfile = "detailed";
migrated.Save();
Check(RecordingOptions.Load().OutputProfile == "detailed", "explicit profile roundtrip");
File.WriteAllText(settings, "invalid json");
Check(RecordingOptions.Load().OutputProfile == "balanced", "corrupt settings recover to defaults");
foreach (var dimensions in new[] { (3840, 2160), (2160, 3840), (5120, 1440), (1365, 767), (2, 2) })
{
    foreach (var profile in new[] { "balanced", "detailed", "native" })
    {
        var (width, height) = RecordingOptions.OutputSize(profile, dimensions.Item1, dimensions.Item2);
        Check(width % 2 == 0 && height % 2 == 0, "encoder dimensions are even");
        Check(width <= dimensions.Item1 && height <= dimensions.Item2, "never upscale");
        var cap = profile == "balanced" ? 1920 : profile == "detailed" ? 2560 : 32768;
        Check(Math.Max(width, height) <= cap, "longest edge cap includes portrait");
    }
}
Check(RecordingOptions.OutputSize("balanced", 3840, 2160) == (1920, 1080), "balanced 4K");
Check(RecordingOptions.OutputSize("detailed", 3840, 2160) == (2560, 1440), "detailed 4K");
Check(RecordingOptions.OutputSize("native", 1365, 767) == (1364, 766), "native rounds down even");
Check(RecordingOptions.BitRate("standard", 1920, 1080) == 12_000_000, "standard baseline");
Check(RecordingOptions.BitRate("high", 3840, 2160) == 72_000_000, "high 4K scales by pixel count");
foreach (var size in new[] { (0, 100), (100, 1), (32769, 100) })
{
    try { RecordingOptions.OutputSize("balanced", size.Item1, size.Item2); throw new Exception("invalid dimensions accepted"); }
    catch (ArgumentOutOfRangeException) { }
}
try { RecordingOptions.BitRate("high", 32768, 32768); throw new Exception("overflowing bitrate accepted"); }
catch (ArgumentOutOfRangeException) { }
Directory.Delete(root, recursive: true);
Console.WriteLine("PASS: profiles, portrait/ultrawide sizing, even pixels, bitrate, migration, persistence, invalid inputs");
