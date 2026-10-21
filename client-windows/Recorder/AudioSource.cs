using System.Diagnostics;
using System.Runtime.InteropServices;
using NAudio.CoreAudioApi;
using NAudio.Wave;

namespace ZsirRecorder;

internal sealed class AudioSource : IDisposable
{
    readonly WasapiCapture capture;
    readonly MMDevice endpoint;
    readonly AudioTimeline timeline = new();
    long origin;
    internal Exception? Error;
    internal double LevelDb => timeline.Peak > 0 ? Math.Max(-120, 20 * Math.Log10(timeline.Peak)) : -120;
    internal string Name => endpoint.FriendlyName;

    internal AudioSource(bool loopback, string? mic)
    {
        using var devices = new MMDeviceEnumerator();
        endpoint = loopback ? devices.GetDefaultAudioEndpoint(DataFlow.Render, Role.Multimedia)
            : mic == null ? devices.GetDefaultAudioEndpoint(DataFlow.Capture, Role.Multimedia) : devices.GetDevice(mic);
        capture = loopback ? new WasapiLoopbackCapture(endpoint) : new WasapiCapture(endpoint);
        capture.WaveFormat = WaveFormat.CreateIeeeFloatWaveFormat(48000, 2);
        capture.DataAvailable += (_, e) =>
        {
            var t0 = Interlocked.Read(ref origin);
            if (t0 == 0) return;
            // shortcut: callback QPC approximates sample time; use native packet QPC if waveform sync fails acceptance.
            long end = (long)((Stopwatch.GetTimestamp() - t0) * (48000.0 / Stopwatch.Frequency));
            timeline.Add(MemoryMarshal.Cast<byte, float>(e.Buffer.AsSpan(0, e.BytesRecorded)), end);
        };
        capture.RecordingStopped += (_, e) => { if (e.Exception != null) Error = e.Exception; };
    }

    internal void Start() => capture.StartRecording();
    internal void Begin(long t0) => Interlocked.Exchange(ref origin, t0);
    internal byte[] Read(long start, int count) => timeline.Read(start, count);
    public void Dispose() { capture.StopRecording(); capture.Dispose(); endpoint.Dispose(); }
}

internal sealed class AudioTimeline
{
    readonly object sync = new();
    // QPC-addressed 2 s ring: delayed reads retain silence gaps instead of concatenating bursts.
    readonly float[] samples = new float[48000 * 2 * 2];
    readonly long[] positions = Enumerable.Repeat(-1L, 48000 * 2).ToArray();
    long lastEnd = -1;
    internal double Peak;

    internal void Add(ReadOnlySpan<float> input, long end)
    {
        int count = input.Length / 2;
        lock (sync)
        {
            // Preserve contiguous packets despite callback jitter; re-anchor after silence.
            if (lastEnd >= 0 && Math.Abs(end - count - lastEnd) < 4800) end = lastEnd + count;
            lastEnd = end;
            for (int i = 0; i < count; i++)
            {
                long at = end - count + i;
                if (at < 0) continue;
                int slot = (int)(at % positions.Length);
                positions[slot] = at;
                samples[slot * 2] = input[i * 2]; samples[slot * 2 + 1] = input[i * 2 + 1];
                Peak = Math.Max(Peak, Math.Max(Math.Abs(input[i * 2]), Math.Abs(input[i * 2 + 1])));
            }
        }
    }
    internal byte[] Read(long start, int count)
    {
        var bytes = new byte[count * 8];
        var output = MemoryMarshal.Cast<byte, float>(bytes);
        lock (sync)
            for (int i = 0; i < count; i++)
            {
                long at = start + i;
                int slot = (int)(at % positions.Length);
                if (positions[slot] != at) continue;
                output[i * 2] = samples[slot * 2]; output[i * 2 + 1] = samples[slot * 2 + 1];
            }
        return bytes;
    }
}
