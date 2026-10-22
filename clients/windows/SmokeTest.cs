using System.Diagnostics;
using System.Globalization;
using System.Media;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace ZSirCapture;

internal static class SmokeTest
{
    public static async Task RunAsync(MainForm form, string tools, string root)
    {
        Directory.CreateDirectory(root);
        var report = new Dictionary<string, object?> { ["startedAt"] = DateTimeOffset.UtcNow, ["productClient"] = true, ["microphoneOpened"] = false };
        TestScene? scene = null;
        try
        {
            int duration = int.TryParse(Environment.GetEnvironmentVariable("ZSIR_SMOKE_SECONDS"), out int requested) ? Math.Clamp(requested, 18, 3600) : 18;
            int spacing = duration == 18 ? 5 : (duration - 8) / 2;
            var analysisTimeout = TimeSpan.FromSeconds(Math.Max(60, duration / 2));
            report["requestedSeconds"] = duration;
            CheckAudioFile(root);
            string missingTools = Path.Combine(root, "missing-tools");
            string untouchedOutput = Path.Combine(root, "missing-tools-output");
            foreach (string available in new[] { "ffmpeg.exe", "ffprobe.exe" })
            {
                Directory.CreateDirectory(missingTools);
                // A placeholder proves the other dependency is checked before any process starts.
                File.WriteAllText(Path.Combine(missingTools, available), "test");
                bool missingRejected = false;
                try { await new Recorder(missingTools).StartAsync(untouchedOutput, Screen.PrimaryScreen!.Bounds, ""); }
                catch (FileNotFoundException ex) { missingRejected = ex.Message.Contains("完整安装包") && !ex.Message.Contains(".cmd"); }
                File.Delete(Path.Combine(missingTools, available));
                if (!missingRejected || Directory.Exists(untouchedOutput)) throw new Exception("Missing tools must fail before creating a Take");
            }
            report["missingToolsRejectedWithoutTake"] = true;
            if (MainForm.FormatTimecode(3601) != "01:00:01" || MainForm.FormatTimecode(90_000) != "25:00:00") throw new Exception("Timecode wraps incorrectly");
            var toggle = (Button)form.Controls.Find("previewToggle", true).Single();
            int expandedHeight = form.Height;
            toggle.PerformClick();
            if (form.Height >= expandedHeight) throw new Exception("Preview collapse did not shrink window");
            CaptureWindow(form, Path.Combine(root, "client-collapsed.png"));
            toggle.PerformClick();
            if (form.Height != expandedHeight) throw new Exception("Preview expand changed original window height");
            CaptureWindow(form, Path.Combine(root, "client-ready.png"));
            report["previewLayoutPassed"] = true;
            form.SetTestOutput(root);
            scene = new TestScene(); scene.Show(); form.BringToFront();
            string tone = Path.Combine(root, "test-tone.wav"); WriteTone(tone);
            using var player = new SoundPlayer(tone); player.Load();
            await form.StartRecordingAsync();
            if (!form.IsRecording) throw form.LastError ?? new Exception("Client did not enter recording state");
            Recorder recorder = form.CurrentRecorder!;
            CaptureWindow(form, Path.Combine(root, "client-recording.png"));
            var clock = Stopwatch.StartNew(); int index = 0; double flashUntil = -1;
            while (clock.Elapsed.TotalSeconds < duration)
            {
                double now = clock.Elapsed.TotalSeconds;
                if (index < 3 && now >= 3 + index * spacing)
                {
                    scene.Flash = true; scene.Invalidate(); scene.Update(); player.Play(); flashUntil = now + .3; index++;
                }
                if (scene.Flash && now > flashUntil) { scene.Flash = false; scene.Invalidate(); }
                if (!form.IsRecording) throw form.LastError ?? new Exception("Recording stopped unexpectedly");
                await Task.Delay(20);
            }
            if (!form.Edge.IsDocked || form.Visible || !form.Edge.Excluded) throw new Exception("15-second idle docking failed");
            if (form.Timecode == "00:00:00") throw new Exception("Recording timecode did not advance");
            report["dockedTimecode"] = form.Timecode;
            using (var edgeImage = new Bitmap(form.Edge.Width, form.Edge.Height)) { form.Edge.DrawToBitmap(edgeImage, new Rectangle(Point.Empty, form.Edge.Size)); edgeImage.Save(Path.Combine(root, "edge-indicator.png")); }
            form.Edge.Reveal(true);
            await Task.Delay(700);
            if (!form.Visible || form.Edge.IsDocked || !form.IsRecording) throw new Exception("Edge reveal interrupted recording");
            CaptureWindow(form, Path.Combine(root, "client-recording.png"));
            report["edgeDockAndRevealPassed"] = true;
            long packets = recorder.AudioPackets;
            await form.StopRecordingAsync();
            if (form.LastError != null) throw form.LastError;
            if (form.Edge.IsDocked || !form.Visible) throw new Exception("Stop did not restore window");
            string take = form.LastFolder!, video = Path.Combine(take, "desktop.mp4");
            var info = await recorder.ProbeAsync(video);
            report["take"] = take; report["media"] = info; report["audioPackets"] = packets;
            var decode = await recorder.RunAsync("ffmpeg.exe", ["-v", "error", "-xerror", "-i", video, "-f", "null", "NUL"], analysisTimeout);
            if (decode.Code != 0) throw new Exception("Full decode failed: " + decode.Error);
            string pcm = Path.Combine(root, "audio-check.f32");
            var audio = await recorder.RunAsync("ffmpeg.exe", ["-v", "error", "-n", "-i", video, "-vn", "-ac", "1", "-ar", "48000", "-f", "f32le", pcm], analysisTimeout);
            if (audio.Code != 0) throw new Exception(audio.Error);
            var audioPeaks = ToneStarts(await File.ReadAllBytesAsync(pcm));
            var stats = await recorder.RunAsync("ffmpeg.exe", ["-hide_banner", "-nostats", "-i", video, "-an", "-vf", "scale=32:18,signalstats,metadata=print:key=lavfi.signalstats.YAVG", "-f", "null", "NUL"], analysisTimeout);
            if (stats.Code != 0) throw new Exception(stats.Error);
            var flashes = FlashStarts(stats.Error);
            report["audioToneStartsSeconds"] = audioPeaks; report["videoFlashStartsSeconds"] = flashes;
            if (audioPeaks.Count != 3 || flashes.Count != 3) throw new Exception($"Expected 3 audible tones and 3 video flashes; got {audioPeaks.Count}/{flashes.Count}");
            var offsets = audioPeaks.Zip(flashes, (a, v) => a - v).ToArray(); report["audioMinusVideoSeconds"] = offsets;
            if (offsets.Any(x => Math.Abs(x) > .25)) throw new Exception("Audio/video offset exceeds 250 ms");
            if (Math.Abs(audioPeaks[1] - audioPeaks[0] - spacing) > .2 || Math.Abs(audioPeaks[2] - audioPeaks[1] - spacing) > .2) throw new Exception("Silent gaps were not preserved");
            report["fullDecodePassed"] = true;
            // Repeat through the same UI path without test sound; a silent Take must still have an audio track.
            await form.StartRecordingAsync(); if (!form.IsRecording) throw form.LastError ?? new Exception("Second start failed");
            Recorder silent = form.CurrentRecorder!; await Task.Delay(16_000);
            if (!form.Edge.IsDocked) throw new Exception("Second take did not auto-hide");
            await form.StopRecordingAsync();
            if (!form.Visible || form.Edge.IsDocked) throw new Exception("Stop while docked did not restore");
            report["stopRestoresWindow"] = true;
            if (form.LastError != null) throw form.LastError;
            report["secondTake"] = form.LastFolder;
            report["secondMedia"] = await silent.ProbeAsync(Path.Combine(form.LastFolder!, "desktop.mp4"));
            using var bitmap = new Bitmap(form.Width, form.Height); form.DrawToBitmap(bitmap, new Rectangle(Point.Empty, form.Size));
            bitmap.Save(Path.Combine(root, "client-ui.png"));
            var invalid = new Recorder(tools);
            bool rejected = false;
            try { await invalid.StartAsync(root, Screen.PrimaryScreen!.Bounds, "zsir-nonexistent-output-device"); }
            catch { rejected = true; }
            if (!rejected) { await invalid.StopAsync(); throw new Exception("Missing device silently accepted"); }
            report["missingDeviceRejected"] = true;
            await form.StartRecordingAsync();
            if (!form.IsRecording) throw form.LastError ?? new Exception("Fault check could not start");
            var interrupted = form.CurrentRecorder!;
            await Task.Delay(16_000);
            if (!form.Edge.IsDocked) throw new Exception("Fault take did not auto-hide");
            interrupted.Encoder!.Kill(entireProcessTree: true);
            var wait = Stopwatch.StartNew();
            while (form.IsBusy && wait.Elapsed.TotalSeconds < 40) await Task.Delay(100);
            if (form.IsBusy || form.LastError == null) throw new Exception("Encoder interruption was not reported and stopped");
            if (!File.Exists(Path.Combine(form.LastFolder!, "desktop-video.mp4")) || !File.Exists(Path.Combine(form.LastFolder!, "system-audio.wav")))
                throw new Exception("Interrupted source media was not preserved");
            report["interruptedTake"] = form.LastFolder;
            var recovered = await interrupted.ProbeAsync(Path.Combine(form.LastFolder!, "desktop-video.mp4"));
            if (double.Parse(recovered.GetProperty("format").GetProperty("duration").GetString()!, CultureInfo.InvariantCulture) <= 0) throw new Exception("Interrupted video has no readable duration");
            report["interruptedVideoReadable"] = true;
            if (!form.Visible || form.Edge.IsDocked) throw new Exception("Encoder failure left window hidden");
            report["encoderInterruptionHandled"] = true;
            report["audioFileChecksPassed"] = true;
            report["state"] = "passed";
        }
        catch (Exception ex)
        {
            report["state"] = "failed"; report["error"] = ex.ToString(); Environment.ExitCode = 1;
            if (form.IsRecording) await form.StopRecordingAsync("自动测试中止");
        }
        finally
        {
            scene?.Dispose();
            report["finishedAt"] = DateTimeOffset.UtcNow;
            await File.WriteAllTextAsync(Path.Combine(root, "acceptance.json"), JsonSerializer.Serialize(report, new JsonSerializerOptions { WriteIndented = true }));
            form.Close();
        }
    }
    static void CaptureWindow(MainForm form, string path)
    {
        foreach (var button in Descendants(form).OfType<Button>().Where(x => x.Visible))
        {
            var bounds = form.RectangleToClient(button.RectangleToScreen(button.ClientRectangle));
            if (!form.ClientRectangle.Contains(bounds)) throw new Exception("Button clipped: " + button.Text);
        }
        using var bitmap = new Bitmap(form.Width, form.Height);
        form.DrawToBitmap(bitmap, new Rectangle(Point.Empty, form.Size)); bitmap.Save(path);
    }
    static IEnumerable<Control> Descendants(Control parent)
    {
        foreach (Control child in parent.Controls) { yield return child; foreach (var nested in Descendants(child)) yield return nested; }
    }
    static List<double> ToneStarts(byte[] pcm)
    {
        var result = new List<double>(); bool active = false;
        for (int offset = 0; offset + 480 * 4 <= pcm.Length; offset += 480 * 4)
        {
            double sin = 0, cos = 0;
            for (int i = 0; i < 480; i++) { float sample = BitConverter.ToSingle(pcm, offset + i * 4); double phase = 2 * Math.PI * 997 * i / 48000; sin += sample * Math.Sin(phase); cos += sample * Math.Cos(phase); }
            bool detected = 2 * Math.Sqrt(sin * sin + cos * cos) / 480 > .004;
            if (detected && !active) result.Add(offset / (48000.0 * 4));
            active = detected;
        }
        return result;
    }
    static List<double> FlashStarts(string metadata)
    {
        var result = new List<double>(); double time = 0; bool bright = false;
        foreach (string line in metadata.Split('\n'))
        {
            var frame = Regex.Match(line, @"pts_time:([0-9.]+)");
            if (frame.Success) time = double.Parse(frame.Groups[1].Value, CultureInfo.InvariantCulture);
            var value = Regex.Match(line, @"lavfi.signalstats.YAVG=([0-9.]+)");
            if (value.Success)
            {
                bool next = double.Parse(value.Groups[1].Value, CultureInfo.InvariantCulture) > 180;
                if (next && !bright) result.Add(time);
                bright = next;
            }
        }
        return result;
    }
    static void WriteTone(string path)
    {
        const int frames = 12_000;
        using var writer = new BinaryWriter(File.Open(path, FileMode.CreateNew));
        writer.Write("RIFF"u8); writer.Write(36 + frames * 2); writer.Write("WAVEfmt "u8); writer.Write(16);
        writer.Write((short)1); writer.Write((short)1); writer.Write(48_000); writer.Write(96_000); writer.Write((short)2); writer.Write((short)16);
        writer.Write("data"u8); writer.Write(frames * 2);
        for (int i = 0; i < frames; i++) { double ramp = Math.Min(1, Math.Min(i, frames - i - 1) / 480.0); writer.Write((short)(Math.Sin(i * 2 * Math.PI * 997 / 48000) * 32767 * .1 * ramp)); }
    }
    static void CheckAudioFile(string root)
    {
        byte[] format = new byte[18]; BitConverter.GetBytes((ushort)3).CopyTo(format, 0); BitConverter.GetBytes((ushort)1).CopyTo(format, 2);
        BitConverter.GetBytes(48000).CopyTo(format, 4); BitConverter.GetBytes(192000).CopyTo(format, 8);
        BitConverter.GetBytes((ushort)4).CopyTo(format, 12); BitConverter.GetBytes((ushort)32).CopyTo(format, 14);
        string path = Path.Combine(root, "timeline-check.wav");
        using (var file = new AudioFile(path, format, 4))
        {
            byte[] signal = Enumerable.Repeat(BitConverter.GetBytes(.5f), 10).SelectMany(x => x).ToArray();
            file.AppendAt(100, signal, 10); file.AppendAt(105, signal, 10); file.PadTo(150);
            if (file.Frames != 150) throw new Exception("Audio overlap/gap accounting failed");
        }
        byte[] bytes = File.ReadAllBytes(path);
        if (Encoding.ASCII.GetString(bytes, 0, 4) != "RF64" || BitConverter.ToInt64(bytes, 36) != 150) throw new Exception("RF64 header incorrect");
        int data = 48 + 8 + format.Length + 8;
        if (bytes.Skip(data).Take(400).Any(x => x != 0) || BitConverter.ToSingle(bytes, data + 400) != .5f || bytes.Length - data != 600)
            throw new Exception("Audio silent padding or payload incorrect");
    }
    sealed class TestScene : Form
    {
        public bool Flash;
        public TestScene() { Text = "庄Sir录制验收画面"; TopMost = true; FormBorderStyle = FormBorderStyle.None; Bounds = Screen.PrimaryScreen!.Bounds; StartPosition = FormStartPosition.Manual; DoubleBuffered = true; }
        protected override void OnPaint(PaintEventArgs e)
        {
            e.Graphics.Clear(Flash ? Color.White : Color.FromArgb(18, 36, 60));
            using var font = new Font("Microsoft YaHei UI", 28, FontStyle.Bold);
            e.Graphics.DrawString("庄Sir · Windows 桌面与系统声音测试", font, Flash ? Brushes.Black : Brushes.White, new PointF(80, 120));
            using var small = new Font("Microsoft YaHei UI", 16);
            e.Graphics.DrawString("测试完成后自动关闭此画面 · 不打开摄像头或话筒", small, Flash ? Brushes.Black : Brushes.LightBlue, new PointF(80, 190));
        }
    }
}
