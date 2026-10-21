using System.Diagnostics;
using System.Text.Json;
using System.Text;

namespace ZsirRecorder.App;

internal sealed class LocalState
{
    internal static readonly string Folder = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "ZsirInterview");
    internal static readonly string FileName = Path.Combine(Folder, "settings.json");
    public string Output { get; set; } = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "Videos", "庄Sir采访");
    public string? Camera { get; set; }
    public string? Mic { get; set; }
    public string? Display { get; set; }
    public string Quality { get; set; } = "recommended";
    public string Tracks { get; set; } = "cam,screen";
    public bool Onboarded { get; set; }
    public double? Left { get; set; }
    public double? Top { get; set; }
    public string? LastSession { get; set; }
    public int RecorderPid { get; set; }
    public long RecorderStarted { get; set; }
    internal static LocalState Load()
    {
        try { return JsonSerializer.Deserialize<LocalState>(File.ReadAllText(FileName)) ?? new(); }
        catch (Exception e) when (e is IOException or JsonException or UnauthorizedAccessException) { return new(); }
    }
    internal void Save()
    {
        Directory.CreateDirectory(Folder);
        File.WriteAllText(FileName + ".tmp", JsonSerializer.Serialize(this));
        File.Move(FileName + ".tmp", FileName, true);
    }
    internal IEnumerable<string> Selection()
    {
        foreach (var (key, value) in new[] { ("--camera", Camera), ("--mic", Mic), ("--display", Display) })
            if (!string.IsNullOrEmpty(value)) { yield return key; yield return value; }
    }
    internal Process? ExistingRecorder()
    {
        if (RecorderPid <= 0) return null;
        try { var p = Process.GetProcessById(RecorderPid); return p.StartTime.ToUniversalTime().Ticks == RecorderStarted && p.ProcessName == "zsir-recorder" ? p : null; }
        catch (ArgumentException) { return null; }
        catch (InvalidOperationException) { return null; }
        catch (System.ComponentModel.Win32Exception) { return null; }
    }
}

internal static class RecorderBridge
{
    internal static Process Start(IEnumerable<string> args)
    {
        var start = new ProcessStartInfo(Path.Combine(AppContext.BaseDirectory, "zsir-recorder.exe")) {
            UseShellExecute = false, CreateNoWindow = true, RedirectStandardInput = true,
            RedirectStandardOutput = true, RedirectStandardError = true, StandardOutputEncoding = Encoding.UTF8, StandardErrorEncoding = Encoding.UTF8
        };
        foreach (var arg in args) start.ArgumentList.Add(arg);
        return Process.Start(start) ?? throw new IOException("录制程序未能启动，请检查程序文件是否完整。");
    }
    internal static async Task<JsonElement> Query(IEnumerable<string> args)
    {
        using var p = Start(args);
        var error = p.StandardError.ReadToEndAsync();
        string result = await p.StandardOutput.ReadToEndAsync();
        await p.WaitForExitAsync();
        string diagnostic = await error;
        if (string.IsNullOrWhiteSpace(result)) throw new IOException("录制程序没有返回结果。" + diagnostic);
        return JsonDocument.Parse(result.Trim()).RootElement.Clone();
    }
}
