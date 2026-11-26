using System.Globalization;
using System.Text.Json;

namespace ZSirCapture;

internal sealed record RecoveryTrack(string Name, string Video, string Audio, double? AudioOffset)
{
    public static IEnumerable<RecoveryTrack> Find(string take)
    {
        foreach (string name in new[] { "desktop", "camera" })
        {
            string video = Path.Combine(take, name + "-video.mp4");
            if (!File.Exists(video) || File.Exists(Path.Combine(take, name + ".mp4"))) continue;
            string audio = Path.Combine(take, name == "camera" ? "microphone.wav" : "system-audio.wav");
            double? offset = null;
            foreach (string report in name == "camera" ? new[] { "camera-report.json", "report.json" } : new[] { "report.json" })
            {
                string path = Path.Combine(take, report);
                if (!File.Exists(path)) continue;
                try
                {
                    using var json = JsonDocument.Parse(File.ReadAllText(path));
                    var data = json.RootElement;
                    if (data.ValueKind != JsonValueKind.Object) continue;
                    if (data.TryGetProperty("tracks", out var tracks) && tracks.ValueKind == JsonValueKind.Object &&
                        tracks.TryGetProperty(name, out var track) && track.ValueKind == JsonValueKind.Object)
                        offset = Offset(track);
                    else
                    {
                        string? mode = data.TryGetProperty("mode", out var value) && value.ValueKind == JsonValueKind.String ? value.GetString() : null;
                        if (name == "camera" ? mode == "camera" : mode is null or "desktop" or "both") offset = Offset(data);
                    }
                }
                catch (JsonException) { /* Preserve corrupt metadata; a video-only copy must not guess audio alignment. */ }
                if (offset.HasValue) break;
            }
            yield return new(name, video, audio, File.Exists(audio) ? offset : null);
        }
    }

    static double? Offset(JsonElement data)
    {
        if (!data.TryGetProperty("videoStartUnix", out var video) || video.ValueKind != JsonValueKind.Number || !video.TryGetDouble(out double v) ||
            !data.TryGetProperty("audioStartUnix", out var audio) || audio.ValueKind != JsonValueKind.Number || !audio.TryGetDouble(out double a)) return null;
        double offset = v - a;
        return double.IsFinite(offset) && offset >= 0 && offset <= 30 ? offset : null;
    }

    internal string[] AudioArguments() => AudioOffset is double offset
        ? ["-ss", offset.ToString("0.#########", CultureInfo.InvariantCulture), "-i", Audio,
            "-map", "0:v:0", "-map", "1:a:0", "-c:a", "aac", "-b:a", "192k", "-af", "apad"]
        : ["-map", "0:v:0", "-an"];
}
