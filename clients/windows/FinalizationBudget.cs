using System.Diagnostics;

namespace ZSirCapture;

// Conservative admission policy, not a measured storage/encoder speed guarantee.
// Progress and the finite overall budget are independent: a slow advancing writer
// may continue; a stalled writer cannot consume the entire long-recording budget.
internal static class FinalizationBudget
{
    internal const double StallSeconds = 60;
    internal const ulong ProgressThresholdBytes = 65536;
    internal const double MaximumSeconds = 2 * 60 * 60;
    internal const double AssumedBytesPerSecond = 25_000_000;
    internal static TimeSpan Calculate(long inputBytes, double mediaSeconds, bool encodeAudio, bool remux)
    {
        if (inputBytes < 0 || !double.IsFinite(mediaSeconds) || mediaSeconds < 0)
            throw new ArgumentOutOfRangeException(nameof(inputBytes));
        double seconds = 120 + inputBytes / AssumedBytesPerSecond * (remux ? 3 : 1)
            + (encodeAudio ? mediaSeconds : 0);
        return TimeSpan.FromSeconds(Math.Min(MaximumSeconds, seconds));
    }

    internal static object Describe(TimeSpan total) => new {
        totalSeconds = total.TotalSeconds, stallSeconds = StallSeconds,
        assumedBytesPerSecond = AssumedBytesPerSecond, maximumSeconds = MaximumSeconds, progressThresholdBytes = ProgressThresholdBytes,
        copyIoPasses = 1, remuxIoPasses = 3, audioSecondsPerMediaSecond = 1,
        note = "conservative finite policy, not measured throughput; cumulative I/O is a heuristic, not durable media-write proof; periodic FFmpeg stats disabled"
    };

    internal sealed class Progress
    {
        ulong previous;
        double lastProgress;
        internal void Check(double elapsedSeconds, ulong transferredBytes, TimeSpan budget)
        {
            if (transferredBytes >= previous && transferredBytes - previous >= ProgressThresholdBytes)
            { previous = transferredBytes; lastProgress = elapsedSeconds; }
            if (elapsedSeconds >= budget.TotalSeconds) throw new TimeoutException("素材处理超过本次有限总预算，原素材与部分副本保留");
            if (elapsedSeconds - lastProgress >= StallSeconds) throw new TimeoutException("素材处理连续 60 秒没有读写进展，原素材与部分副本保留");
        }
    }

    internal static async Task WaitAsync(Task work, Func<ulong> transferredBytes, TimeSpan budget)
    {
        var clock = Stopwatch.StartNew();
        var progress = new Progress();
        while (!work.IsCompleted)
        {
            if (await Task.WhenAny(work, Task.Delay(1000)) == work) break;
            progress.Check(clock.Elapsed.TotalSeconds, transferredBytes(), budget);
        }
        await work;
    }
}
