using System.Runtime.InteropServices;

namespace ZSirCapture;

internal static class ResourceBudget
{
    // System commit includes page-file backing; physical free RAM alone is not an allocation budget.
    internal const long SafetyFloor = 512L * 1024 * 1024;
    // Admission heuristic: three full BGRA input packets plus capture/filter surfaces,
    // and 10 lookahead frames + per-worker working surfaces at output resolution.
    // Codec/device/driver allocations are not measured; this is not a peak-memory guarantee.
    internal static long EstimateStartup(int sourceWidth, int sourceHeight, int width, int height, int threads)
        => checked(SafetyFloor + (long)sourceWidth * sourceHeight * 4 * 6
            + (long)width * height * 4 * (10 + 4 * threads));

    internal static void Check(long minimum = SafetyFloor)
    {
        var status = new MemoryStatus { Length = (uint)Marshal.SizeOf<MemoryStatus>() };
        if (!GlobalMemoryStatusEx(ref status)) throw new IOException("无法读取系统内存预算");
        if (status.AvailablePageFile < (ulong)minimum)
            throw new IOException($"系统提交内存余量不足预算 {minimum / (1024 * 1024)} MB，已停止录制并保留原始素材");
    }
    [StructLayout(LayoutKind.Sequential)]
    struct MemoryStatus
    {
        public uint Length, MemoryLoad;
        public ulong TotalPhysical, AvailablePhysical, TotalPageFile, AvailablePageFile,
            TotalVirtual, AvailableVirtual, AvailableExtendedVirtual;
    }
    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    static extern bool GlobalMemoryStatusEx(ref MemoryStatus status);
}
