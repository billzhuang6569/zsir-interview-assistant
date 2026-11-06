using System.Windows;
using System.Windows.Controls;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using System.Diagnostics;
using System.Globalization;
using System.Media;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace ZSirCapture;

internal static class SmokeTest
{
    [DllImport("user32.dll")] static extern bool GetWindowDisplayAffinity(IntPtr window, out uint affinity);

    public static async Task RunAsync(MainWindow window, string tools, string root)
    {
        var form = window.Controller;
        Directory.CreateDirectory(root);
        var report = new Dictionary<string, object?> { ["startedAt"] = DateTimeOffset.UtcNow, ["productClient"] = true, ["microphoneOpened"] = false };
        var stageNames = new[] { "desktop", "camera", "both", "noCamera" };
        var stages = new Dictionary<string, object?>();
        foreach (string name in stageNames) stages[name] = new { passed = false, error = "Stage did not run" };
        report["stages"] = stages;
        var errors = new List<string>();
        var layoutFailures = new Dictionary<string, List<string>>();
        report["layoutFailures"] = layoutFailures;
        var standaloneRecorders = new List<Recorder>();
        TestScene? scene = null;
        string originalMode = form.Options.Mode;
        string originalCamera = form.Options.CameraId, originalMic = form.Options.MicrophoneId;
        string? originalFake = Environment.GetEnvironmentVariable("ZSIR_FAKE_CAMERA");
        form.SetTestOutput(root);
        try
        {
            await RunStageAsync("desktop", async () =>
            {
                form.SetMode("desktop", persist: false);
                CheckCameraParsers(); report["cameraParsersPassed"] = true;
                int duration = int.TryParse(Environment.GetEnvironmentVariable("ZSIR_SMOKE_SECONDS"), out int requested) ? Math.Clamp(requested, 18, 7200) : 18;
                int spacing = duration == 18 ? 5 : (duration - 8) / 2;
                var analysisTimeout = TimeSpan.FromSeconds(Math.Max(60, duration / 2));
                report["requestedSeconds"] = duration;
                if (!new RecordingOptions().StealthInCapture || !JsonSerializer.Deserialize<RecordingOptions>("{}")!.StealthInCapture) throw new Exception("Stealth must default to true, including old settings");
                bool originalStealth = form.StealthInCapture;
                try
                {
                    form.SetStealthInCapture(false, persist: false);
                    if (!GetWindowDisplayAffinity(window.Handle, out uint visibleAffinity) || visibleAffinity != 0 ||
                        !GetWindowDisplayAffinity(window.Edge.Handle, out uint visibleEdgeAffinity) || visibleEdgeAffinity != 0) throw new Exception("Stealth off did not clear window affinity");
                    form.SetStealthInCapture(true, persist: false);
                    if (!GetWindowDisplayAffinity(window.Handle, out uint hiddenAffinity) || hiddenAffinity != 0x11 ||
                        !GetWindowDisplayAffinity(window.Edge.Handle, out uint hiddenEdgeAffinity) || hiddenEdgeAffinity != 0x11) throw new Exception("Stealth on did not restore window affinity");
                    report["captureVisibilityPassed"] = true;
                }
                finally { form.SetStealthInCapture(originalStealth, persist: false); }
                DisplayNames.CheckNativeLayout();
                var fallbackName = DisplayNames.Caption(Screen.PrimaryScreen!, 0, new Dictionary<string, string>());
                if (!fallbackName.StartsWith("显示器 1（主）") || fallbackName.Contains(@"\\.\DISPLAY")) throw new Exception("Display caption fallback failed");
                var friendlyNames = new Dictionary<string, string> { [Screen.PrimaryScreen!.DeviceName] = "BenQ EX2780Q" };
                if (DisplayNames.Caption(Screen.PrimaryScreen!, 0, friendlyNames) != "BenQ EX2780Q\n" + fallbackName)
                    throw new Exception("Display caption must separate friendly name from index and intact resolution");
                friendlyNames[Screen.PrimaryScreen!.DeviceName] = "Long\r\nmonitor name";
                if (DisplayNames.Caption(Screen.PrimaryScreen!, 0, friendlyNames) != "Long monitor name\n" + fallbackName)
                    throw new Exception("Display caption must not exceed two lines");
                CheckLayoutFixtures(tools, root, layoutFailures);
                report["scaledLayoutFixturesPassed"] = layoutFailures.Count == 0 ? new[] { 1f, 1.25f, 1.5f, 2f } : Array.Empty<float>();
                CheckAudioFile(root);
                var blockedWriter = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
                string pendingLeasePath = Path.Combine(root, "pending-cleanup.lock");
                var pendingLease = new FileStream(pendingLeasePath, FileMode.CreateNew, FileAccess.ReadWrite, FileShare.None);
                var release = Recorder.ReleaseCleanupLeaseAsync(pendingLease, [blockedWriter.Task]);
                bool locked = false;
                try { using var competing = new FileStream(pendingLeasePath, FileMode.Open, FileAccess.Read, FileShare.None); }
                catch (IOException) { locked = true; }
                if (!locked || release.IsCompleted) throw new Exception("Pending cleanup released its Take lease");
                blockedWriter.SetException(new IOException("Injected writer completion failure"));
                await release.WaitAsync(TimeSpan.FromSeconds(2));
                using (var completedLease = new FileStream(pendingLeasePath, FileMode.Open, FileAccess.Read, FileShare.None)) { }
                report["pendingCleanupLeasePassed"] = true;
                string missingTools = Path.Combine(root, "missing-tools");
                string untouchedOutput = Path.Combine(root, "missing-tools-output");
                foreach (string available in new[] { "ffmpeg.exe", "ffprobe.exe" })
                {
                    Directory.CreateDirectory(missingTools);
                    // A placeholder proves the other dependency is checked before any process starts.
                    File.WriteAllText(Path.Combine(missingTools, available), "test");
                    bool missingRejected = false;
                    try { await NewRecorder(missingTools).StartAsync(untouchedOutput, Screen.PrimaryScreen!.Bounds, ""); }
                    catch (FileNotFoundException ex) { missingRejected = ex.Message.Contains("完整安装包") && !ex.Message.Contains(".cmd"); }
                    File.Delete(Path.Combine(missingTools, available));
                    if (!missingRejected || Directory.Exists(untouchedOutput)) throw new Exception("Missing tools must fail before creating a Take");
                }
                report["missingToolsRejectedWithoutTake"] = true;
                if (RecordingController.FormatTimecode(3601) != "01:00:01" || RecordingController.FormatTimecode(90_000) != "25:00:00") throw new Exception("Timecode wraps incorrectly");
                Action toggle = form.TogglePreview;
                FlushLayout(window);
                double expandedHeight = window.ActualHeight;
                toggle(); FlushLayout(window);
                RecordLayout(layoutFailures, "client-collapsed", () => { if (window.ActualHeight >= expandedHeight) throw new Exception("Preview collapse did not shrink window"); });
                CaptureWindow(window, Path.Combine(root, "client-collapsed.png"), layoutFailures);
                toggle(); FlushLayout(window);
                RecordLayout(layoutFailures, "client-ready", () => { if (Math.Abs(window.ActualHeight - expandedHeight) > .5) throw new Exception("Preview expand changed original window height"); });
                CaptureWindow(window, Path.Combine(root, "client-ready.png"), layoutFailures);
                report["previewLayoutPassed"] = !layoutFailures.Keys.Any(key => key.StartsWith("client-"));
                scene = new TestScene(); scene.Show(); window.Activate();
                string tone = Path.Combine(root, "test-tone.wav"); WriteTone(tone);
                using var player = new SoundPlayer(tone); player.Load();
                await form.StartRecordingAsync();
                if (!form.IsRecording) throw form.LastError ?? new Exception("Client did not enter recording state");
                Recorder recorder = form.CurrentRecorder!;
                CaptureWindow(window, Path.Combine(root, "client-recording.png"), layoutFailures);
                var clock = Stopwatch.StartNew(); int index = 0; double flashUntil = -1;
                while (clock.Elapsed.TotalSeconds < duration)
                {
                    double now = clock.Elapsed.TotalSeconds;
                    if (index < 3 && now >= 3 + index * spacing)
                    {
                        scene.Flash = true; scene.UpdateLayout(); player.Play(); flashUntil = now + .3; index++;
                    }
                    if (scene.Flash && now > flashUntil) { scene.Flash = false; scene.UpdateLayout(); }
                    if (!form.IsRecording) throw form.LastError ?? new Exception("Recording stopped unexpectedly");
                    await Task.Delay(20);
                }
                if (!window.Edge.IsDocked || window.IsVisible || !window.Edge.Excluded) throw new Exception("15-second idle docking failed");
                if (form.Timecode == "00:00:00") throw new Exception("Recording timecode did not advance");
                report["dockedTimecode"] = form.Timecode;
                CaptureWindow(window.Edge, Path.Combine(root, "edge-indicator.png"), layoutFailures);
                window.Edge.Reveal(true);
                await Task.Delay(700);
                if (!window.IsVisible || window.Edge.IsDocked || !form.IsRecording) throw new Exception("Edge reveal interrupted recording");
                CaptureWindow(window, Path.Combine(root, "client-recording.png"), layoutFailures);
                report["edgeDockAndRevealPassed"] = true;
                long packets = recorder.AudioPackets;
                await form.StopRecordingAsync();
                if (form.LastError != null) throw form.LastError;
                if (window.Edge.IsDocked || !window.IsVisible) throw new Exception("Stop did not restore window");
                string take = form.LastFolder!, video = Path.Combine(take, "desktop.mp4");
                using (var takeReport = JsonDocument.Parse(File.ReadAllText(Path.Combine(take, "report.json"))))
                    if (takeReport.RootElement.GetProperty("stealthInCapture").GetBoolean() != form.StealthInCapture) throw new Exception("Report stealth state does not match recording");
                var info = await recorder.ProbeAsync(video);
                report["take"] = take; report["media"] = info; report["audioPackets"] = packets;
                var decode = await recorder.RunAsync("ffmpeg.exe", ["-v", "error", "-xerror", "-i", video, "-f", "null", "NUL"], analysisTimeout);
                if (decode.Code != 0) throw new Exception("Full decode failed: " + decode.Error);
                string pcm = Path.Combine(root, "audio-check.f32");
                var audio = await recorder.RunAsync("ffmpeg.exe", ["-v", "error", "-n", "-i", video, "-vn", "-ac", "1", "-ar", "48000", "-f", "f32le", pcm], analysisTimeout);
                if (audio.Code != 0) throw new Exception(audio.Error);
                var audioPeaks = await Task.Run(() => ToneStarts(pcm));
                var stats = await recorder.RunAsync("ffmpeg.exe", ["-hide_banner", "-nostats", "-i", video, "-an", "-vf", "scale=32:18,signalstats,metadata=print:key=lavfi.signalstats.YAVG:file=video-flashes.txt", "-f", "null", "NUL"], analysisTimeout, root);
                if (stats.Code != 0) throw new Exception(stats.Error);
                string flashMetadata = Path.Combine(root, "video-flashes.txt");
                if (new FileInfo(flashMetadata).Length > 128 * 1024 * 1024) throw new Exception("Video analysis exceeded 128 MB disk budget");
                var flashes = FlashStarts(File.ReadLines(flashMetadata));
                report["audioToneStartsSeconds"] = audioPeaks; report["videoFlashStartsSeconds"] = flashes;
                if (audioPeaks.Count != 3 || flashes.Count != 3) throw new Exception($"Expected 3 audible tones and 3 video flashes; got {audioPeaks.Count}/{flashes.Count}");
                var offsets = audioPeaks.Zip(flashes, (a, v) => a - v).ToArray(); report["audioMinusVideoSeconds"] = offsets;
                if (offsets.Any(x => Math.Abs(x) > .1)) throw new Exception("Audio/video offset exceeds 100 ms");
                if (Math.Abs(audioPeaks[1] - audioPeaks[0] - spacing) > .2 || Math.Abs(audioPeaks[2] - audioPeaks[1] - spacing) > .2) throw new Exception("Silent gaps were not preserved");
                report["fullDecodePassed"] = true;
                // Repeat through the same UI path without test sound; a silent Take must still have an audio track.
                await form.StartRecordingAsync(); if (!form.IsRecording) throw form.LastError ?? new Exception("Second start failed");
                Recorder silent = form.CurrentRecorder!; await Task.Delay(16_000);
                if (!window.Edge.IsDocked) throw new Exception("Second take did not auto-hide");
                await form.StopRecordingAsync();
                if (!window.IsVisible || window.Edge.IsDocked) throw new Exception("Stop while docked did not restore");
                report["stopRestoresWindow"] = true;
                if (form.LastError != null) throw form.LastError;
                report["secondTake"] = form.LastFolder;
                report["secondMedia"] = await silent.ProbeAsync(Path.Combine(form.LastFolder!, "desktop.mp4"));
                CaptureWindow(window, Path.Combine(root, "client-ui.png"), layoutFailures);
                var invalid = NewRecorder(tools);
                bool rejected = false;
                try { await invalid.StartAsync(root, Screen.PrimaryScreen!.Bounds, "zsir-nonexistent-output-device"); }
                catch { rejected = true; }
                if (!rejected) { await invalid.StopAsync(); throw new Exception("Missing device silently accepted"); }
                report["missingDeviceRejected"] = true;
                await form.StartRecordingAsync();
                if (!form.IsRecording) throw form.LastError ?? new Exception("Fault check could not start");
                var interrupted = form.CurrentRecorder!;
                await Task.Delay(16_000);
                if (!window.Edge.IsDocked) throw new Exception("Fault take did not auto-hide");
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
                if (!window.IsVisible || window.Edge.IsDocked) throw new Exception("Encoder failure left window hidden");
                report["encoderInterruptionHandled"] = true;
                string recoveryRoot = Path.Combine(root, "recovery-check");
                string recoveryTake = Path.Combine(recoveryRoot, "Take-fixture");
                Directory.CreateDirectory(recoveryTake);
                foreach (string file in new[] { "desktop-video.mp4", "system-audio.wav", "report.json" })
                    File.Copy(Path.Combine(form.LastFolder!, file), Path.Combine(recoveryTake, file));
                string originalVideo = Path.Combine(recoveryTake, "desktop-video.mp4");
                string beforeHash = Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(await File.ReadAllBytesAsync(originalVideo)));
                using (var activeLease = new FileStream(Path.Combine(recoveryTake, ".recording.lock"), FileMode.CreateNew, FileAccess.ReadWrite, FileShare.None))
                    if ((await NewRecorder(tools).RecoverUnfinishedAsync(recoveryRoot)).Length != 0) throw new Exception("Active take was recovered");
                var recoveredCopies = await NewRecorder(tools).RecoverUnfinishedAsync(recoveryRoot);
                if (recoveredCopies.Length != 1 || beforeHash != Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(await File.ReadAllBytesAsync(originalVideo))))
                    throw new Exception("Recovery failed or modified the original video");
                var recoveryDecode = await interrupted.RunAsync("ffmpeg.exe", ["-v", "error", "-xerror", "-i", recoveredCopies[0], "-f", "null", "NUL"], analysisTimeout);
                if (recoveryDecode.Code != 0) throw new Exception("Recovery copy cannot decode");
                report["recoveryOriginalHashUnchanged"] = beforeHash;
                report["recoveryCopy"] = recoveredCopies[0];
                report["audioFileChecksPassed"] = true;
                if (int.TryParse(Environment.GetEnvironmentVariable("ZSIR_SMOKE_CYCLES"), out int cycles))
                {
                    cycles = Math.Clamp(cycles, 1, 20);
                    var cycleMedia = new List<object>();
                    for (int cycle = 0; cycle < cycles; cycle++)
                    {
                        await form.StartRecordingAsync();
                        if (!form.IsRecording) throw form.LastError ?? new Exception("Cycle start failed");
                        var session = form.CurrentRecorder!;
                        await Task.Delay(2500);
                        if (cycle == 0)
                        {
                            long visible = session.PreviewFrames;
                            if (visible == 0) throw new Exception("Preview producer emitted no frames");
                            toggle(); FlushLayout(window);
                            await Task.Delay(2000); // Allow the finite encoder/pipe in-flight frames to drain.
                            long hidden = session.PreviewFrames;
                            double before = session.Seconds;
                            await Task.Delay(2500);
                            if (session.PreviewFrames != hidden || session.Seconds <= before)
                                throw new Exception("Hidden preview producer did not stop or video stopped");
                            toggle(); FlushLayout(window);
                            await Task.Delay(2000);
                            if (session.PreviewFrames <= hidden) throw new Exception("Preview producer failed to resume");
                            report["previewProducerGatePassed"] = true;
                        }
                        await form.StopRecordingAsync();
                        if (form.LastError != null) throw form.LastError;
                        string clip = Path.Combine(form.LastFolder!, "desktop.mp4");
                        var cycleInfo = await session.ProbeAsync(clip);
                        var cycleDecode = await session.RunAsync("ffmpeg.exe", ["-v", "error", "-xerror", "-i", clip, "-f", "null", "NUL"], TimeSpan.FromSeconds(30));
                        if (cycleDecode.Code != 0) throw new Exception("Cycle output decode failed: " + cycleDecode.Error);
                        cycleMedia.Add(new { cycle = cycle + 1, folder = form.LastFolder, media = cycleInfo });
                    }
                    report["repeatCycles"] = cycleMedia;
                }
            });
            var cameraTests = new List<object>();
            report["cameraTests"] = cameraTests;
            foreach (string mode in new[] { "camera", "both" })
            {
                await RunStageAsync(mode, async () =>
                {
                    if (!CameraDevices.Fake)
                    {
                        report["cameraTestsSkipped"] = "设置 ZSIR_FAKE_CAMERA=1 运行无硬件合成摄像头测试";
                        throw new InvalidOperationException((string)report["cameraTestsSkipped"]!);
                    }
                    form.Options.CameraId = ""; form.Options.MicrophoneId = "";
                    if (mode == "camera")
                    {
                        string missingCameraRoot = Path.Combine(root, "missing-camera");
                        var missingCamera = NewRecorder(tools); bool missingCameraRefused = false;
                        try { await missingCamera.StartAsync(missingCameraRoot, Screen.PrimaryScreen!.Bounds, "", mode: "camera", cameraId: "unplugged-camera-id"); }
                        catch (InvalidOperationException ex) { missingCameraRefused = ex.Message.Contains("所选摄像头已断开"); }
                        if (!missingCameraRefused || missingCamera.Folder != null || Directory.Exists(missingCameraRoot)) throw new Exception("Selected camera was silently replaced");
                        report["missingCameraNotReplaced"] = true;
                    }
                    form.SetMode(mode, persist: false);
                    await form.StartRecordingAsync();
                    if (!form.IsRecording) throw form.LastError ?? new Exception("Camera smoke start failed: " + mode);
                    var session = form.CurrentRecorder!;
                    await Task.Delay(8000);
                    session.CheckHealth();
                    await form.StopRecordingAsync();
                    if (form.LastError != null) throw form.LastError;
                    string folder = form.LastFolder!;
                    using var takeReport = JsonDocument.Parse(File.ReadAllText(Path.Combine(folder, "report.json")));
                    var data = takeReport.RootElement;
                    var trackDurations = new Dictionary<string, double>();
                    foreach (string track in mode == "both" ? new[] { "camera", "desktop" } : new[] { "camera" })
                    {
                        var media = await session.ProbeAsync(Path.Combine(folder, track + ".mp4"));
                        var streams = media.GetProperty("streams").EnumerateArray().ToArray();
                        if (!streams.Any(v => v.GetProperty("codec_type").GetString() == "video" && v.GetProperty("codec_name").GetString() == "h264") ||
                            (track == "camera" || form.Options.SystemAudio) && !streams.Any(a => a.GetProperty("codec_type").GetString() == "audio" && a.GetProperty("codec_name").GetString() == "aac"))
                            throw new Exception("Camera smoke codecs invalid: " + track);
                        double seconds = double.Parse(media.GetProperty("format").GetProperty("duration").GetString()!, CultureInfo.InvariantCulture);
                        if (seconds < 7 || seconds > 11) throw new Exception("Camera smoke duration invalid: " + seconds);
                        trackDurations[track] = seconds;
                        var rawVideo = await session.ProbeAsync(Path.Combine(folder, track + "-video.mp4"));
                        double rawVideoSeconds = double.Parse(rawVideo.GetProperty("format").GetProperty("duration").GetString()!, CultureInfo.InvariantCulture);
                        if (rawVideoSeconds < 7 || rawVideoSeconds > 11) throw new Exception("Raw video duration invalid: " + rawVideoSeconds);
                        double? alignedAudioSeconds = null;
                        if (track == "camera" || form.Options.SystemAudio)
                        {
                            var rawAudio = await session.ProbeAsync(Path.Combine(folder, track == "camera" ? "microphone.wav" : "system-audio.wav"));
                            double rawAudioSeconds = double.Parse(rawAudio.GetProperty("format").GetProperty("duration").GetString()!, CultureInfo.InvariantCulture);
                            var starts = data.GetProperty("tracks").GetProperty(track);
                            double offset = starts.GetProperty("videoStartUnix").GetDouble() - starts.GetProperty("audioStartUnix").GetDouble();
                            alignedAudioSeconds = rawAudioSeconds - offset;
                            if (Math.Abs(rawVideoSeconds - alignedAudioSeconds.Value) > .3)
                                throw new Exception($"{track} raw video/audio duration mismatch: video={rawVideoSeconds:0.000}, aligned audio={alignedAudioSeconds:0.000}, offset={offset:0.000}");
                        }
                        var decoded = await session.RunAsync("ffmpeg.exe", ["-v", "error", "-xerror", "-i", Path.Combine(folder, track + ".mp4"), "-f", "null", "NUL"], TimeSpan.FromSeconds(30));
                        if (decoded.Code != 0) throw new Exception("Camera decode failed: " + decoded.Error);
                        cameraTests.Add(new { mode, track, folder, media, rawVideoSeconds, alignedAudioSeconds });
                    }
                    if (mode == "both" && Math.Abs(trackDurations["camera"] - trackDurations["desktop"]) > .5)
                        throw new Exception("Camera/desktop duration mismatch exceeds 0.5 seconds");
                    if (data.GetProperty("mode").GetString() != mode || data.GetProperty("camera").GetProperty("name").GetString() != "测试摄像头" ||
                        data.GetProperty("camera").GetProperty("id").GetString() != "zsir-fake-camera" ||
                        data.GetProperty("camera").GetProperty("width").GetInt32() != 1280 ||
                        data.GetProperty("camera").GetProperty("height").GetInt32() != 720 ||
                        data.GetProperty("camera").GetProperty("fps").GetDouble() != 30 ||
                        data.GetProperty("tracks").GetProperty("camera").GetProperty("videoStartUnix").GetDouble() <= 0 ||
                        !data.GetProperty("outputFiles").EnumerateArray().Any(f => f.GetString() == "camera.mp4"))
                        throw new Exception("Camera report invalid");
                    if (mode == "both")
                    {
                        form.SetMode("both", persist: false);
                        await form.StartRecordingAsync();
                        if (!form.IsRecording) throw form.LastError ?? new Exception("Dual-track failure fixture did not start");
                        var failedCamera = form.CurrentRecorder!;
                        await Task.Delay(2000);
                        failedCamera.CameraEncoder!.Kill(entireProcessTree: true);
                        for (int i = 0; i < 200 && form.IsBusy; i++) await Task.Delay(200);
                        if (form.IsRecording) await form.StopRecordingAsync("摄像头异常测试");
                        if (form.IsBusy || form.LastError == null || failedCamera.CleanupPending) throw new Exception("Camera failure did not stop the whole Take");
                        foreach (string raw in new[] { "desktop-video.mp4", "system-audio.wav", "camera-video.mp4", "microphone.wav" })
                            if ((raw != "system-audio.wav" || form.Options.SystemAudio) && !File.Exists(Path.Combine(failedCamera.Folder!, raw))) throw new Exception("Camera failure lost raw track: " + raw);
                        using (var failedReport = JsonDocument.Parse(File.ReadAllText(Path.Combine(failedCamera.Folder!, "report.json"))))
                            if (failedReport.RootElement.GetProperty("state").GetString() != "needs_review") throw new Exception("Camera failure was reported as success");
                        report["cameraFailureStopsBothAndPreservesRaw"] = true;
                    }
                });
            }
            await RunStageAsync("noCamera", async () =>
            {
                Environment.SetEnvironmentVariable("ZSIR_FAKE_CAMERA", null);
                try
                {
                    form.SetMode("desktop", persist: false);
                    await form.ReleaseIdleForSettingsAsync();
                    if ((await CameraDevices.DiscoverAsync(tools)).Count == 0)
                    {
                        string emptyRoot = Path.Combine(root, "no-camera");
                        var absent = NewRecorder(tools); bool refused = false;
                        try { await absent.StartAsync(emptyRoot, Screen.PrimaryScreen!.Bounds, "", mode: "camera"); }
                        catch (InvalidOperationException ex) { refused = ex.Message == CameraDevices.NoCamera; }
                        if (!refused || absent.Folder != null || Directory.Exists(emptyRoot)) throw new Exception("No camera must refuse before creating a Take");
                        report["noCameraRejectedWithoutTake"] = true;
                    }
                    else report["noCameraCheckSkipped"] = "此机器有真实摄像头";
                }
                finally { Environment.SetEnvironmentVariable("ZSIR_FAKE_CAMERA", originalFake); }
            });
        }
        catch (Exception ex) { errors.Add("smoke: " + ex); }
        finally
        {
            try { await ResetStageAsync(); }
            catch (Exception ex) { errors.Add("final cleanup: " + ex); }
            scene?.Close();
            Environment.SetEnvironmentVariable("ZSIR_FAKE_CAMERA", originalFake);
            form.Options.CameraId = originalCamera; form.Options.MicrophoneId = originalMic;
            form.SetMode(originalMode, persist: false);
            report["state"] = errors.Count == 0 ? "passed" : "failed";
            if (errors.Count > 0) { report["error"] = string.Join(Environment.NewLine, errors); Environment.ExitCode = 1; }
            report["finishedAt"] = DateTimeOffset.UtcNow;
            await File.WriteAllTextAsync(Path.Combine(root, "acceptance.json"), JsonSerializer.Serialize(report, new JsonSerializerOptions { WriteIndented = true }));
            window.Close();
        }

        async Task RunStageAsync(string name, Func<Task> run)
        {
            string? error = null;
            int layoutCount = layoutFailures.Values.Sum(items => items.Count);
            try
            {
                await ResetStageAsync();
                await run();
            }
            catch (Exception ex) { error = ex.ToString(); }
            finally
            {
                try { await ResetStageAsync(); }
                catch (Exception ex) { error = (error == null ? "" : error + Environment.NewLine) + "Cleanup: " + ex; }
            }
            int newLayoutFailures = layoutFailures.Values.Sum(items => items.Count) - layoutCount;
            if (newLayoutFailures > 0)
                error = (error == null ? "" : error + Environment.NewLine) + $"{newLayoutFailures} layout/screenshot checks failed; see layoutFailures by surface.";
            stages[name] = new { passed = error == null, error };
            if (error != null) errors.Add(name + ": " + error);
        }

        Recorder NewRecorder(string directory)
        {
            var recorder = new Recorder(directory);
            standaloneRecorders.Add(recorder);
            return recorder;
        }

        async Task ResetStageAsync()
        {
            var current = form.CurrentRecorder;
            if (form.IsRecording)
                await form.StopRecordingAsync("自动测试阶段清理").WaitAsync(TimeSpan.FromMinutes(3));
            foreach (var recorder in standaloneRecorders)
                if (recorder.Encoder != null && recorder.Completion == null)
                    await recorder.StopAsync("自动测试阶段清理").WaitAsync(TimeSpan.FromMinutes(3));
            var wait = Stopwatch.StartNew();
            while (standaloneRecorders.Any(recorder => recorder.CleanupPending || recorder.Completion?.IsCompleted == false) || form.IsBusy || form.CurrentRecorder?.CleanupPending == true || current?.CleanupPending == true || current?.Completion?.IsCompleted == false)
            {
                if (wait.Elapsed.TotalMinutes >= 3) throw new TimeoutException("上一测试阶段仍在保存或释放资源，不能开始新的录制");
                await Task.Delay(100);
            }
            scene?.Close(); scene = null;
            window.Edge.Reveal(true);
            if (window.WindowState == WindowState.Minimized) window.WindowState = WindowState.Normal;
            window.Show();
            form.SetMode("desktop", persist: false);
            if (!form.ViewModel.PreviewVisible) form.TogglePreview(); window.UpdateLayout();
            await form.ReleaseIdleForSettingsAsync();
        }
    }
    internal static void CheckCameraParsers()
    {
        CheckLayoutDiagnostics();
        const string devices = """
            [dshow @ 0000] "集成摄像头" (video)
            [dshow @ 0000]   Alternative name "@device_pnp_\\?\usb#one"
            [dshow @ 0001] "集成摄像头" (video)
            [dshow @ 0001]   Alternative name "@device_pnp_\\?\usb#two"
            [dshow @ 0000] "话筒" (audio)
            [dshow @ 0000]   Alternative name "@device_cm_audio"
            """;
        var parsed = CameraDevices.ParseDevices(devices);
        if (parsed.Count != 2 || parsed[0].Name != "集成摄像头" || parsed[0].Id == parsed[1].Id || !parsed[0].Id.EndsWith("usb#one") ||
            CameraDevices.ParseDevices("Could not enumerate video devices").Count != 0) throw new Exception("Camera device parser failed");
        const string noVideoDevices = """
            [in#0 @ 000002d8e85324c0] Could not enumerate video devices (or none found).
            [in#0 @ 000002d8e85324c0] "麦克风 (ROG DELTA II (2.4GHz))" (audio)
            [in#0 @ 000002d8e85324c0]   Alternative name "@device_cm_{33D9A762-90C8-11D0-BD43-00A0C911CE86}\wave_{4272CCDA-E64B-4ABB-B36C-33E587B4EE86}"
            Error opening input file dummy.
            """;
        if (CameraDevices.ParseDevices(noVideoDevices).Count != 0) throw new Exception("Audio-only in#0 output must return no cameras");
        const string videoDevice = """
            [in#0 @ 000002d8e85324c0] "测试摄像头" (video)
            [in#0 @ 000002d8e85324c0]   Alternative name "@device_pnp_\\?\usb#camera"
            """;
        var inDevice = CameraDevices.ParseDevices(videoDevice);
        if (inDevice.Count != 1 || inDevice[0] != new CameraDevice(@"@device_pnp_\\?\usb#camera", "测试摄像头"))
            throw new Exception("in#0 video device parser failed");
        const string options = """
            [dshow @ 0000] vcodec=mjpeg  min s=1920x1080 fps=15 max s=1920x1080 fps=60
            [dshow @ 0000] vcodec=mjpeg  min s=1280x720 fps=30 max s=1280x720 fps=30
            [dshow @ 0000] pixel_format=yuyv422  min s=640x480 fps=5 max s=1920x1080 fps=30
            [dshow @ 0000] vcodec=mjpeg min s=3840x2160 fps=30 max s=3840x2160 fps=30
            """;
        var formats = CameraDevices.ParseFormats(options);
        foreach (string prefix in new[] { "", "[in#0 @ 000002d8e85324c0] ", "[backend @ 0x1234] " })
        {
            string WithPrefix(string fixture) => Regex.Replace(fixture, @"^\[[^\]]+\]\s*", prefix, RegexOptions.Multiline);
            if (!CameraDevices.ParseDevices(WithPrefix(devices)).SequenceEqual(parsed) ||
                !CameraDevices.ParseFormats(WithPrefix(options)).SequenceEqual(formats))
                throw new Exception("Device and format parsers must ignore log prefixes: " + prefix);
        }
        var chosen = CameraDevices.ChooseFormat(formats);
        if (chosen.Vcodec != "mjpeg" || chosen.Width != 1920 || chosen.Fps != 30) throw new Exception("1080 MJPEG preference failed");
        chosen = CameraDevices.ChooseFormat(formats.Where(f => f.Vcodec != "mjpeg" || f.Width != 1920));
        if (chosen.Width != 1280 || chosen.Vcodec != "mjpeg") throw new Exception("720 MJPEG preference failed");
        chosen = CameraDevices.ChooseFormat(formats.Where(f => f.PixelFormat != null));
        if (chosen.Width != 1920 || chosen.PixelFormat != "yuyv422" || chosen.Fps != 30) throw new Exception("Raw preference failed");
        chosen = CameraDevices.ChooseFormat([new(null, "nv12", 640, 480, 15), new("mjpeg", null, 1280, 720, 10)]);
        if (chosen.Width != 1280 || chosen.Fps != 10) throw new Exception("Low FPS fallback failed");
        if (CameraDevices.ParseFormats("pixel_format=yuyv422 min s=0x1080 fps=30 max s=999999999999x1080 fps=NaN").Count != 0)
            throw new Exception("Invalid camera formats accepted");
        bool rejected = false;
        try { CameraDevices.ChooseFormat([]); } catch (InvalidOperationException) { rejected = true; }
        if (!rejected || new[] { "Could not run graph", "I/O error", "Device or resource busy" }.Any(message => !CameraDevices.Error(message).Contains("占用"))) throw new Exception("Camera failure mapping failed");
        Recorder.ValidateTrackDurations(8, 8.2, .2, camera: true);
        Recorder.ValidateTrackDurations(8.5, 8, 0, camera: true);
        foreach (bool camera in new[] { true, false })
        {
            bool durationRejected = false;
            try { Recorder.ValidateTrackDurations(10.166667, 9.236, .004722, camera); }
            catch (InvalidOperationException ex) { durationRejected = ex.Message.Contains(camera ? "摄像头画面与话筒时长相差" : "桌面画面与系统声音时长相差"); }
            if (!durationRejected) throw new Exception("Raw duration mismatch must refuse padded muxing");
        }
        bool invalidDurationRejected = false;
        try { Recorder.ValidateTrackDurations(double.NaN, 8, 0, camera: true); }
        catch (InvalidOperationException) { invalidDurationRejected = true; }
        if (!invalidDurationRejected) throw new Exception("Non-finite raw duration accepted");
        if (new RecordingOptions().Mode != "desktop" || JsonSerializer.Deserialize<RecordingOptions>("{}")!.Mode != "desktop")
            throw new Exception("Old settings must default to desktop");
    }

    static void CheckLayoutFixtures(string tools, string root, Dictionary<string, List<string>> failures)
    {
        foreach (double scale in new[] { 1.0, 1.25, 1.5, 2.0 })
        foreach (string mode in new[] { "desktop", "camera", "both" })
        {
            string prefix = $"{mode}@{scale:0.##}/";
            void Check(string surface, Action check) => RecordLayout(failures, prefix + surface, check);
            void Capture(Window window, string file) => CaptureWindow(window, Path.Combine(root, file), failures, prefix + file);
            var fixture = new MainWindow(tools, automation: true, layoutOnly: true);
            try
            {
                var controller = fixture.Controller;
                controller.SetMode(mode, persist: false); fixture.Show(); fixture.ScaleForLayoutTest(scale);
                Check("ready-empty", () => CheckLayout(fixture));
                var frame = BitmapSource.Create(32, 18, 96, 96, PixelFormats.Bgr32, null, new byte[32 * 18 * 4], 32 * 4); frame.Freeze();
                controller.ViewModel.CameraImage = controller.ViewModel.DesktopImage = frame;
                Check("ready", () =>
                {
                    CheckLayout(fixture);
                    var tiles = new[] { fixture.CameraTile, fixture.DesktopTile }.Where(tile => tile.IsVisible).ToArray();
                    if (tiles.Length != (mode == "both" ? 2 : 1)) throw new Exception("Preview tile count does not match mode");
                    foreach (var tile in tiles)
                    {
                        var picture = (AspectBorder)tile.FindName("Picture");
                        if (Math.Abs(picture.ActualWidth / picture.ActualHeight - (mode == "both" ? 1.6 : 16.0 / 9)) > .03)
                            throw new Exception("Preview tile aspect ratio does not match mode");
                        if (tile.Margin != new Thickness(0) || Math.Abs(tile.ActualHeight - fixture.PreviewRow.ActualHeight) > 1)
                            throw new Exception("Preview tiles must fit the container height without inner margins");
                    }
                    if (mode == "both")
                    {
                        var left = tiles[0].TransformToAncestor(fixture.PreviewRow).TransformBounds(new Rect(tiles[0].RenderSize));
                        var right = tiles[1].TransformToAncestor(fixture.PreviewRow).TransformBounds(new Rect(tiles[1].RenderSize));
                        if (Math.Abs(left.Left) > 1 || Math.Abs(right.Right - fixture.PreviewRow.ActualWidth) > 1 ||
                            Math.Abs(right.Left - left.Right - 8) > 1 || Math.Abs(left.Width - right.Width) > 1)
                            throw new Exception("Dual preview must use equal widths separated by a scaled gap");
                    }
                    else if (Math.Abs(tiles[0].ActualWidth - fixture.PreviewRow.ActualWidth) > 1) throw new Exception("Single preview must fill its container");
                });
                if (scale == 1 && mode == "desktop") Capture(fixture, "client-ready.png");
                controller.TogglePreview(); Check("collapsed", () => CheckLayout(fixture));
                if (scale == 1 && mode == "desktop") Capture(fixture, "client-collapsed.png");
                controller.TogglePreview(); controller.SetRecordingLayoutForTest(true); Check("recording", () => CheckLayout(fixture));
                if (scale == 1 && mode == "both") Capture(fixture, "client-recording.png");
                controller.SetRecordingLayoutForTest(false);
                if (mode == "both")
                {
                    controller.SetNoCameraLayoutForTest();
                    Check("no-camera", () =>
                    {
                        CheckLayout(fixture);
                        if (controller.ViewModel.CanStart || controller.ViewModel.PreviewState != "摄像头不可用") throw new Exception("No camera UI must explain the failure and disable recording");
                    });
                    if (scale == 1) Capture(fixture, "client-nocamera.png");
                }
                var settings = fixture.CreateSettingsWindow();
                try
                {
                    settings.Show(); settings.ScaleForLayoutTest(scale);
                    if (scale == 1) Capture(settings, mode == "both" ? "settings-main.png" : "settings-" + mode + "-main.png");
                    Check("settings-main", () =>
                    {
                        CheckLayout(settings);
                        if (settings.ResizeMode != ResizeMode.NoResize || settings.ShowInTaskbar || settings.Owner != fixture ||
                            Descendants(settings).OfType<Button>().Any(c => System.Windows.Automation.AutomationProperties.GetName(c) == "关闭设置"))
                            throw new Exception("Settings must use only the native close button and stay out of the taskbar");
                        CheckScrollablePage(settings);
                    });
                    Check("settings-affinity", () => CheckSettingsAffinity(settings, fixture));
                    settings.ShowAdvanced(true);
                    if (scale == 1 && mode == "desktop") Capture(settings, "settings-advanced.png");
                    Check("settings-advanced", () =>
                    {
                        CheckLayout(settings); CheckScrollablePage(settings);
                        if (Descendants(settings).OfType<TextBlock>().Count(l => l.IsVisible && l.Text.StartsWith("版本 ")) != 1)
                            throw new Exception("Advanced settings must show the version exactly once");
                    });
                    settings.ShowAdvanced(false); Check("settings-back", () => CheckLayout(settings));
                }
                finally { settings.Close(); }
            }
            catch (Exception ex) { RecordLayout(failures, prefix + "fixture", () => throw new Exception("Fixture failed", ex)); }
            finally { fixture.Close(); }
        }
    }
    static void CheckSettingsAffinity(SettingsWindow settings, MainWindow fixture)
    {
        bool original = fixture.Controller.StealthInCapture;
        try
        {
            foreach (bool stealth in new[] { false, true })
            {
                fixture.Controller.SetStealthInCapture(stealth, persist: false);
                foreach (IntPtr handle in new[] { fixture.Handle, fixture.Edge.Handle, settings.Handle })
                    if (!GetWindowDisplayAffinity(handle, out uint affinity) || affinity != (stealth ? 0x11u : 0u))
                        throw new Exception("Settings/main/edge capture affinity mismatch");
            }
        }
        finally { fixture.Controller.SetStealthInCapture(original, persist: false); }
    }
    static void CheckScrollablePage(SettingsWindow settings)
    {
        foreach (var control in Descendants(settings.Root).OfType<Control>().Where(c => c.IsVisible && c.Focusable && c.IsEnabled).ToArray())
        {
            control.BringIntoView(); FlushLayout(settings);
            var bounds = PixelBounds(control, settings.Viewport);
            var area = PixelBounds(settings.Viewport, settings.Viewport);
            if (!FitsLayout(bounds, area)) throw new Exception($"Settings control cannot scroll fully into view: {Describe(control)} {bounds} outside {area}; parents: {ParentChain(control)}");
            CheckLayout(settings);
        }
        settings.Viewport.ScrollToHome(); settings.UpdateLayout();
    }
    static void FlushLayout(FrameworkElement root)
    {
        root.UpdateLayout();
        root.Dispatcher.Invoke(DispatcherPriority.ContextIdle, new Action(root.UpdateLayout));
    }
    static Rect PixelBounds(FrameworkElement element, FrameworkElement root)
    {
        var bounds = new Rect(element.RenderSize);
        if (element != root) bounds = element.TransformToAncestor(root).TransformBounds(bounds);
        var dpi = VisualTreeHelper.GetDpi(root);
        bounds.Scale(dpi.DpiScaleX, dpi.DpiScaleY);
        return bounds;
    }
    // Compare device pixels after layout/DPI transforms, allowing only half a pixel of rounding.
    static bool FitsLayout(Rect bounds, Rect area) =>
        bounds.Left >= area.Left - .500001 && bounds.Top >= area.Top - .500001 &&
        bounds.Right <= area.Right + .500001 && bounds.Bottom <= area.Bottom + .500001;
    static string Describe(FrameworkElement element)
    {
        string text = element is TextBlock block ? block.Text : element is ContentControl control ? control.Content?.ToString() ?? "" : "";
        return $"{element.GetType().Name} Name='{element.Name}' Text='{text.ReplaceLineEndings(" ")}'";
    }
    static string ParentChain(FrameworkElement element)
    {
        var chain = new List<string>();
        for (DependencyObject? current = element; current != null; current = VisualTreeHelper.GetParent(current))
            if (current is FrameworkElement item) chain.Add(Describe(item));
        return string.Join(" <- ", chain);
    }
    static void CheckLayout(FrameworkElement root)
    {
        FlushLayout(root);
        Visit(root);
        void Visit(DependencyObject parent)
        {
            var children = Enumerable.Range(0, VisualTreeHelper.GetChildrenCount(parent)).Select(i => VisualTreeHelper.GetChild(parent, i)).ToArray();
            foreach (var child in children)
            {
                if (child is FrameworkElement element && !element.IsVisible) continue;
                if (parent is FrameworkElement container && child is FrameworkElement item && item.ActualWidth > 0 && item.ActualHeight > 0)
                {
                    var bounds = PixelBounds(item, root);
                    var area = PixelBounds(container, root);
                    // The scroll presenter owns a canvas larger than its viewport; inspect that canvas recursively.
                    if (container is not ScrollContentPresenter && !FitsLayout(bounds, area))
                        throw new Exception($"Control clipped: {Describe(item)} {bounds} outside {Describe(container)} {area} (device pixels, tolerance 0.5); parents: {ParentChain(item)}");
                }
                Visit(child);
            }
            if (parent is not Panel panel || Equals(panel.Tag, "overlay")) return;
            var siblings = children.OfType<FrameworkElement>().Where(c => c.IsVisible && !Equals(c.Tag, "overlay") && c.ActualWidth > 0 && c.ActualHeight > 0).ToArray();
            for (int i = 0; i < siblings.Length; i++)
            for (int j = i + 1; j < siblings.Length; j++)
            {
                var overlap = PixelBounds(siblings[i], root);
                overlap.Intersect(PixelBounds(siblings[j], root));
                if (!overlap.IsEmpty && overlap.Width > .500001 && overlap.Height > .500001)
                    throw new Exception($"Sibling controls overlap: {Describe(siblings[i])} / {Describe(siblings[j])}, {overlap} (device pixels); parents: {ParentChain(siblings[i])}");
            }
        }
    }
    static void RecordLayout(Dictionary<string, List<string>> failures, string surface, Action check)
    {
        try { check(); }
        catch (Exception ex)
        {
            if (!failures.TryGetValue(surface, out var errors)) failures[surface] = errors = [];
            errors.Add(ex.ToString());
        }
    }
    static void CaptureWindow(Window window, string path, Dictionary<string, List<string>> failures, string? surface = null)
    {
        surface ??= Path.GetFileName(path);
        RecordLayout(failures, surface, () => CheckLayout(window));
        RecordLayout(failures, surface + "/screenshot", () =>
        {
            var content = (FrameworkElement)window.Content;
            var dpi = VisualTreeHelper.GetDpi(window);
            var area = new Rect(content.RenderSize);
            var visual = new DrawingVisual();
            using (var drawing = visual.RenderOpen())
            {
                drawing.DrawRectangle(window.Background, null, area);
                drawing.DrawRectangle(new VisualBrush(content) { Stretch = Stretch.Fill }, null, area);
            }
            var bitmap = new RenderTargetBitmap(Math.Max(1, (int)Math.Ceiling(area.Width * dpi.DpiScaleX)), Math.Max(1, (int)Math.Ceiling(area.Height * dpi.DpiScaleY)), dpi.PixelsPerInchX, dpi.PixelsPerInchY, PixelFormats.Pbgra32);
            bitmap.Render(visual);
            var encoder = new PngBitmapEncoder(); encoder.Frames.Add(BitmapFrame.Create(bitmap));
            using var output = File.Create(path); encoder.Save(output);
        });
    }
    static void CheckLayoutDiagnostics()
    {
        var area = new Rect(0, 0, 16, 18);
        if (!FitsLayout(new Rect(-.5, -.5, 17, 19), area) || FitsLayout(new Rect(0, 0, 17, 18), area) ||
            FitsLayout(new Rect(-.51, 0, 16, 18), area) || FitsLayout(new Rect(0, -.51, 16, 18), area) || FitsLayout(new Rect(0, 0, 16, 18.51), area))
            throw new Exception("Layout tolerance must allow half a pixel and reject real clipping");
        var failures = new Dictionary<string, List<string>>(); int continued = 0;
        RecordLayout(failures, "main", () => throw new Exception("injected layout failure"));
        RecordLayout(failures, "settings", () => continued++);
        if (failures["main"].Count != 1 || continued != 1) throw new Exception("Layout failures must not abort later surfaces");
        var model = new MainViewModel { Mode = "desktop", CameraAvailable = false };
        if (model.StatusTone != "Ready") throw new Exception("Desktop-only mode must ignore camera availability");
        foreach (string mode in new[] { "camera", "both" })
        {
            model.Mode = mode;
            if (model.StatusTone != "Warning") throw new Exception("Camera modes must warn when camera is unavailable");
        }
        model.IsBusy = true;
        if (model.StatusTone != "Busy") throw new Exception("Busy status tone lost");
        model.IsRecording = true;
        if (model.StatusTone != "Recording") throw new Exception("Recording status must take priority");
        model.IsRecording = model.IsBusy = false; model.Mode = "desktop"; model.HasWarning = true;
        if (model.StatusTone != "Warning") throw new Exception("Non-camera errors must still warn in desktop mode");
    }
    static IEnumerable<FrameworkElement> Descendants(DependencyObject parent)
    {
        for (int i = 0; i < VisualTreeHelper.GetChildrenCount(parent); i++)
        {
            var child = VisualTreeHelper.GetChild(parent, i);
            if (child is FrameworkElement element) yield return element;
            foreach (var nested in Descendants(child)) yield return nested;
        }
    }
    static List<double> ToneStarts(string path)
    {
        var result = new List<double>(); bool active = false;
        using var input = File.OpenRead(path);
        byte[] pcm = new byte[480 * 4];
        for (long offset = 0; offset + pcm.Length <= input.Length; offset += pcm.Length)
        {
            input.ReadExactly(pcm);
            double sin = 0, cos = 0;
            for (int i = 0; i < 480; i++) { float sample = BitConverter.ToSingle(pcm, i * 4); double phase = 2 * Math.PI * 997 * i / 48000; sin += sample * Math.Sin(phase); cos += sample * Math.Cos(phase); }
            bool detected = 2 * Math.Sqrt(sin * sin + cos * cos) / 480 > .004;
            if (detected && !active) result.Add(offset / (48000.0 * 4));
            active = detected;
        }
        return result;
    }
    static List<double> FlashStarts(IEnumerable<string> metadata)
    {
        var result = new List<double>(); double time = 0; bool bright = false;
        foreach (string line in metadata)
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
    sealed class TestScene : Window
    {
        readonly TextBlock title, subtitle;
        bool flash;
        public bool Flash
        {
            get => flash;
            set { flash = value; Background = value ? Brushes.White : new SolidColorBrush(Color.FromRgb(18, 36, 60)); title.Foreground = value ? Brushes.Black : Brushes.White; subtitle.Foreground = value ? Brushes.Black : Brushes.LightBlue; }
        }
        public TestScene()
        {
            Title = "庄Sir录制验收画面"; Topmost = true; WindowStyle = WindowStyle.None; ResizeMode = ResizeMode.NoResize; WindowStartupLocation = WindowStartupLocation.Manual;
            SourceInitialized += (_, _) =>
            {
                var transform = HwndSource.FromHwnd(new WindowInteropHelper(this).Handle)?.CompositionTarget?.TransformFromDevice ?? Matrix.Identity;
                var screen = Screen.PrimaryScreen!.Bounds;
                var origin = transform.Transform(new Point(screen.Left, screen.Top)); var size = transform.Transform(new Point(screen.Width, screen.Height));
                Left = origin.X; Top = origin.Y; Width = size.X; Height = size.Y;
            };
            title = new TextBlock { Text = "庄Sir · Windows 桌面与系统声音测试", FontSize = 37, FontWeight = FontWeights.Bold, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 0, 0, 28) };
            subtitle = new TextBlock { Text = "测试完成后自动关闭此画面 · 不打开摄像头或话筒", FontSize = 21, TextWrapping = TextWrapping.Wrap };
            var content = new StackPanel { Margin = new Thickness(80, 120, 80, 0) }; content.Children.Add(title); content.Children.Add(subtitle); Content = content; Flash = false;
        }
    }
}
