using System.Buffers;
using System.IO.Pipes;
using System.Threading.Channels;

namespace ZSirCapture;

// One frame in flight and one pending; slow encoding never queues camera callbacks.
internal sealed class CameraFramePipe
{
    readonly NamedPipeServerStream pipe;
    readonly Channel<byte[]> frames;
    readonly CancellationTokenSource cancellation = new();
    public string Path { get; } = @"\\.\pipe\zsir-camera-" + Guid.NewGuid().ToString("N");
    public int FrameBytes { get; }
    public Task Completion { get; }
    public Exception? Failure { get; private set; }
    public long DroppedFrames => Interlocked.Read(ref droppedFrames);
    long droppedFrames;

    public CameraFramePipe(int width, int height)
    {
        if (width < 2 || height < 2 || width > 1920 || height > 1920)
            throw new ArgumentOutOfRangeException(nameof(width));
        FrameBytes = checked(width * height * 4);
        pipe = new NamedPipeServerStream(Path[(Path.LastIndexOf('\\') + 1)..], PipeDirection.Out, 1,
            PipeTransmissionMode.Byte, PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly, 65536, 65536);
        frames = Channel.CreateBounded<byte[]>(new BoundedChannelOptions(1) {
            FullMode = BoundedChannelFullMode.DropOldest, SingleReader = true
        }, frame => { Interlocked.Increment(ref droppedFrames); ArrayPool<byte>.Shared.Return(frame); });
        Completion = PumpAsync();
    }

    // Ownership of the rented array passes here, including after stop.
    public void Offer(byte[] frame)
    {
        if (frame.Length < FrameBytes) { ArrayPool<byte>.Shared.Return(frame); throw new ArgumentException("摄像头帧长度无效"); }
        if (!frames.Writer.TryWrite(frame)) ArrayPool<byte>.Shared.Return(frame);
    }

    public void RequestStop() { cancellation.Cancel(); frames.Writer.TryComplete(); }

    async Task PumpAsync()
    {
        try
        {
            await pipe.WaitForConnectionAsync(cancellation.Token);
            await foreach (byte[] frame in frames.Reader.ReadAllAsync(cancellation.Token))
            {
                try { await pipe.WriteAsync(frame.AsMemory(0, FrameBytes), cancellation.Token); }
                finally { ArrayPool<byte>.Shared.Return(frame); }
            }
        }
        catch (OperationCanceledException) when (cancellation.IsCancellationRequested) { }
        catch (IOException ex) { Failure = ex; }
        finally
        {
            frames.Writer.TryComplete();
            while (frames.Reader.TryRead(out var frame)) ArrayPool<byte>.Shared.Return(frame);
            pipe.Dispose();
        }
    }
}
