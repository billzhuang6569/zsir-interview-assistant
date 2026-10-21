using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;

namespace ZSirCapture;

// RF64 keeps the native mix format and supports recordings larger than 4 GB.
internal sealed class AudioFile : IDisposable
{
    readonly FileStream stream;
    readonly BinaryWriter writer;
    readonly int blockAlign;
    readonly long dataStart;
    readonly byte[] zeros = new byte[65536];
    public long Frames { get; private set; }
    public AudioFile(string path, byte[] format, int alignment)
    {
        blockAlign = alignment;
        stream = new(path, FileMode.CreateNew, FileAccess.ReadWrite, FileShare.Read);
        writer = new(stream, Encoding.ASCII, leaveOpen: true);
        writer.Write("RF64"u8); writer.Write(uint.MaxValue); writer.Write("WAVEds64"u8); writer.Write(28u);
        writer.Write(0L); writer.Write(0L); writer.Write(0L); writer.Write(0u);
        writer.Write("fmt "u8); writer.Write((uint)format.Length); writer.Write(format);
        if (format.Length % 2 != 0) writer.Write((byte)0);
        writer.Write("data"u8); writer.Write(uint.MaxValue); dataStart = stream.Position;
        Checkpoint();
    }
    public void PadTo(long frame)
    {
        long bytes = Math.Max(0, frame - Frames) * blockAlign;
        while (bytes > 0) { int count = (int)Math.Min(bytes, zeros.Length); stream.Write(zeros, 0, count); bytes -= count; }
        Frames = Math.Max(Frames, frame);
    }
    public void AppendAt(long frame, byte[] data, int frames)
    {
        PadTo(Math.Max(0, frame));
        int skip = (int)Math.Min(frames, Math.Max(0, Frames - frame));
        stream.Write(data, skip * blockAlign, (frames - skip) * blockAlign);
        Frames += frames - skip;
    }
    public void Checkpoint()
    {
        long end = stream.Position;
        stream.Position = 20;
        writer.Write(end - 8); writer.Write(end - dataStart); writer.Write(Frames);
        stream.Position = end;
        stream.Flush(true);
    }
    public void Dispose() { try { Checkpoint(); } finally { writer.Dispose(); stream.Dispose(); } }
}

internal sealed class Loopback
{
    volatile bool stopping;
    readonly TaskCompletionSource started = new(TaskCreationOptions.RunContinuationsAsynchronously);
    readonly TaskCompletionSource completed = new(TaskCreationOptions.RunContinuationsAsynchronously);
    public double OriginQpc { get; private set; }
    public double OriginUnix { get; private set; }
    public string DeviceName { get; private set; } = "";
    public int Rate { get; private set; }
    public int Channels { get; private set; }
    public int Discontinuities { get; private set; }
    public long Packets { get; private set; }
    public volatile float Peak;
    public Exception? Failure { get; private set; }
    public Task StartAsync(string path, string deviceId)
    {
        var thread = new Thread(() => Capture(path, deviceId)) { IsBackground = true, Name = "WASAPI loopback" };
        thread.SetApartmentState(ApartmentState.MTA);
        thread.Start();
        return started.Task;
    }
    public async Task StopAsync() { stopping = true; await completed.Task; }
    void Capture(string path, string deviceId)
    {
        IMMDeviceEnumerator? enumerator = null; IMMDevice? device = null;
        IAudioClient? client = null; IAudioCaptureClient? capture = null;
        IntPtr formatPtr = IntPtr.Zero;
        bool running = false;
        try
        {
            enumerator = CoreAudio.Enumerator();
            CoreAudio.Check(deviceId.Length == 0 ? enumerator.GetDefaultAudioEndpoint(0, 0, out device) : enumerator.GetDevice(deviceId, out device));
            DeviceName = CoreAudio.Name(device);
            var iid = CoreAudio.AudioClientId;
            CoreAudio.Check(device.Activate(ref iid, 23, IntPtr.Zero, out var obj)); client = (IAudioClient)obj;
            CoreAudio.Check(client.GetMixFormat(out formatPtr));
            int length = 18 + (ushort)Marshal.ReadInt16(formatPtr, 16);
            if (length > 4096) throw new InvalidOperationException("无效的系统音频格式");
            byte[] format = new byte[length]; Marshal.Copy(formatPtr, format, 0, length);
            int tag = BitConverter.ToUInt16(format, 0), bits = BitConverter.ToUInt16(format, 14);
            Rate = BitConverter.ToInt32(format, 4); Channels = BitConverter.ToUInt16(format, 2);
            int alignment = BitConverter.ToUInt16(format, 12);
            bool floating = tag == 3 || (tag == 65534 && length >= 40 && BitConverter.ToInt32(format, 24) == 3);
            bool pcm = tag == 1 || (tag == 65534 && length >= 40 && BitConverter.ToInt32(format, 24) == 1);
            if (Rate <= 0 || Rate > 384000 || Channels < 1 || alignment < 1 || !(floating && bits == 32 || pcm && bits == 16))
                throw new InvalidOperationException("当前音频格式尚不支持，请在系统中使用 16 位 PCM 或 32 位浮点输出");
            CoreAudio.Check(client.Initialize(0, 0x20000, 1_000_000, 0, formatPtr, IntPtr.Zero));
            iid = CoreAudio.CaptureClientId; CoreAudio.Check(client.GetService(ref iid, out var service)); capture = (IAudioCaptureClient)service;
            using var file = new AudioFile(path, format, alignment);
            double before = Clock.Qpc;
            OriginUnix = Clock.Unix;
            OriginQpc = (before + Clock.Qpc) / 2;
            CoreAudio.Check(client.Start()); running = true;
            started.TrySetResult();
            var flush = Stopwatch.StartNew();
            while (true)
            {
                CoreAudio.Check(capture.GetNextPacketSize(out uint available));
                while (available > 0)
                {
                    CoreAudio.Check(capture.GetBuffer(out var data, out var frames, out var flags, out _, out var qpc));
                    try
                    {
                        if ((flags & 4) != 0) throw new InvalidOperationException("系统声音时间戳异常，已停止以避免音画错位");
                        if ((flags & 1) != 0 && Packets > 0) Discontinuities++;
                        long target = (long)Math.Round((qpc / 10_000_000.0 - OriginQpc) * Rate);
                        if (Math.Abs(target / (double)Rate - (Clock.Qpc - OriginQpc)) > 5)
                            throw new InvalidOperationException("系统声音时钟偏移异常");
                        byte[] bytes = new byte[checked((int)frames * alignment)];
                        if ((flags & 2) == 0) Marshal.Copy(data, bytes, 0, bytes.Length);
                        float peak = 0;
                        for (int i = 0; i < bytes.Length; i += bits / 8)
                        {
                            float sample = floating ? BitConverter.ToSingle(bytes, i) : BitConverter.ToInt16(bytes, i) / 32768f;
                            if (float.IsFinite(sample)) peak = Math.Max(peak, Math.Abs(sample));
                        }
                        Peak = peak; Packets++;
                        file.AppendAt(target, bytes, (int)frames);
                    }
                    finally { CoreAudio.Check(capture.ReleaseBuffer(frames)); }
                    CoreAudio.Check(capture.GetNextPacketSize(out available));
                }
                if (stopping) break;
                // Leave room for delayed packets; silent periods must not collapse the timeline.
                if ((Clock.Qpc - OriginQpc) - file.Frames / (double)Rate > 2.5)
                { file.PadTo((long)((Clock.Qpc - OriginQpc - 2) * Rate)); Peak = 0; }
                if (flush.Elapsed.TotalSeconds >= 5) { file.Checkpoint(); flush.Restart(); }
                Thread.Sleep(5);
            }
            CoreAudio.Check(client.Stop()); running = false;
            file.PadTo((long)Math.Ceiling((Clock.Qpc - OriginQpc) * Rate));
        }
        catch (Exception ex) { Failure = ex; started.TrySetException(ex); }
        finally
        {
            if (running) client?.Stop();
            if (formatPtr != IntPtr.Zero) Marshal.FreeCoTaskMem(formatPtr);
            CoreAudio.Release(capture); CoreAudio.Release(client); CoreAudio.Release(device); CoreAudio.Release(enumerator);
            completed.TrySetResult();
        }
    }
}

internal static class Clock
{
    public static double Qpc => Stopwatch.GetTimestamp() / (double)Stopwatch.Frequency;
    public static double Unix { get { GetSystemTimePreciseAsFileTime(out long value); return (value - 116444736000000000L) / 10_000_000.0; } }
    [DllImport("kernel32.dll")] static extern void GetSystemTimePreciseAsFileTime(out long value);
}
