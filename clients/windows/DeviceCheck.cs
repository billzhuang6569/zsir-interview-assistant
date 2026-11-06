using System.Globalization;
using System.Text.Json;

namespace ZSirCapture;

internal static class DeviceCheck
{
    internal static async Task RunAsync(string tools, string directory)
    {
        Directory.CreateDirectory(directory);
        var report = new Dictionary<string, object?> {
            ["privacy"] = new[] { "webcam", "microphone" }.ToDictionary(c => c, c => new { value = CapturePrivacy.Value(c, false), desktopValue = CapturePrivacy.Value(c, true) }),
            ["startedAt"] = DateTimeOffset.UtcNow
        };
        var errors = new List<string>();
        var runner = new Recorder(tools);
        var cameras = new List<CameraDevice>();
        var formats = new Dictionary<string, List<CameraFormat>>();
        var microphones = new List<AudioDevice>();
        try { cameras = await CameraDevices.DiscoverAsync(tools); }
        catch (Exception ex) { errors.Add("摄像头检测：" + ex.Message); }
        foreach (var camera in cameras)
        {
            try { formats[camera.Id] = await CameraDevices.FormatsAsync(tools, camera); }
            catch (Exception ex) { errors.Add(camera.Name + "：" + ex.Message); }
        }
        report["cameras"] = cameras.Select(c => new { c.Id, c.Name, formats = formats.GetValueOrDefault(c.Id) }).ToArray();
        try { microphones = CoreAudio.Devices(1).Where(d => d.Id.Length != 0).ToList(); }
        catch (Exception ex) { errors.Add("话筒检测：" + ex.Message); }
        report["microphones"] = microphones;
        if (microphones.Count > 0)
        {
            var mic = new Loopback(); float peak = 0;
            try
            {
                CapturePrivacy.Check("microphone");
                await mic.StartAsync(Path.Combine(directory, "mic-check.wav"), "", microphone: true).WaitAsync(TimeSpan.FromSeconds(10));
                for (int i = 0; i < 60; i++) { await Task.Delay(50); peak = Math.Max(peak, mic.Peak); }
            }
            catch (Exception ex) { errors.Add("话筒采集：" + ex.Message); }
            finally
            {
                try { await mic.StopAsync(); } catch (Exception ex) { errors.Add(ex.Message); }
                report["microphoneCheck"] = new { peak, name = mic.DeviceName, mic.OriginUnix, error = mic.Failure?.Message };
            }
        }
        if (cameras.Count > 0 && formats.TryGetValue(cameras[0].Id, out var available))
        {
            try
            {
                CapturePrivacy.Check("webcam");
                var format = CameraDevices.ChooseFormat(available);
                string partial = Path.Combine(directory, "camera-check-partial.mp4");
                var result = await runner.RunAsync("ffmpeg.exe", ["-hide_banner", "-nostdin", "-n", ..CameraDevices.Input(cameras[0], format),
                    "-t", "3", "-an", "-c:v", "libx264", "-preset", "veryfast", "-threads", "2", "-b:v", "8000000",
                    "-vf", $"scale={format.Width / 2 * 2}:{format.Height / 2 * 2}", "-r", "30", "-fps_mode", "cfr", "-pix_fmt", "yuv420p",
                    "-movflags", "+frag_keyframe+empty_moov+default_base_moof", partial], TimeSpan.FromSeconds(20));
                await File.WriteAllTextAsync(Path.Combine(directory, "camera-check.log"), result.Error);
                if (result.Code != 0) throw new IOException(CameraDevices.Error(result.Error));
                var media = await runner.ProbeAsync(partial);
                double duration = double.Parse(media.GetProperty("format").GetProperty("duration").GetString()!, CultureInfo.InvariantCulture);
                if (Math.Abs(duration - 3) > 1) throw new IOException("摄像头检查时长异常");
                File.Move(partial, Path.Combine(directory, "camera-check.mp4")); report["cameraCheck"] = media;
            }
            catch (Exception ex) { errors.Add("摄像头采集：" + ex.Message); }
        }
        report["errors"] = errors; report["finishedAt"] = DateTimeOffset.UtcNow;
        await File.WriteAllTextAsync(Path.Combine(directory, "devices.json"), JsonSerializer.Serialize(report, new JsonSerializerOptions { WriteIndented = true }));
    }
}
