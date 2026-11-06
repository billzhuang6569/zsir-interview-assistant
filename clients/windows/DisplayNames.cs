using System.Runtime.InteropServices;

namespace ZSirCapture;

internal static class DisplayNames
{
    internal static void CheckNativeLayout()
    {
        if (Marshal.SizeOf<NativePath>() != 72 || Marshal.SizeOf<NativeMode>() != 64 ||
            Marshal.SizeOf<SourceName>() != 84 || Marshal.SizeOf<TargetName>() != 420)
            throw new InvalidOperationException("DisplayConfig native layout mismatch");
    }
    internal static Dictionary<string, string> FriendlyNames()
    {
        var result = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        // Display topology can change between buffer sizing and querying; retry the native snapshot.
        for (int attempt = 0; attempt < 3; attempt++)
        {
            if (GetDisplayConfigBufferSizes(2, out uint pathCount, out uint modeCount) != 0) break;
            var paths = new NativePath[pathCount]; var modes = new NativeMode[modeCount];
            int error = QueryDisplayConfig(2, ref pathCount, paths, ref modeCount, modes, IntPtr.Zero);
            if (error == 122) continue;
            if (error != 0) break;
            foreach (var path in paths.Take((int)pathCount))
            {
                var source = new SourceName { Header = new Header { Type = 1, Size = (uint)Marshal.SizeOf<SourceName>(), Adapter = path.SourceAdapter, Id = path.SourceId }, Name = "" };
                var target = new TargetName { Header = new Header { Type = 2, Size = (uint)Marshal.SizeOf<TargetName>(), Adapter = path.TargetAdapter, Id = path.TargetId }, Name = "", DevicePath = "" };
                if (GetSourceName(ref source) == 0 && GetTargetName(ref target) == 0 && !string.IsNullOrWhiteSpace(target.Name)) result[source.Name] = target.Name;
            }
            break;
        }
        return result;
    }
    internal static string Caption(Screen screen, int index, IReadOnlyDictionary<string, string> names)
    {
        string primary = screen.Primary ? "（主）" : "";
        string caption = $"显示器 {index + 1}{primary} · {screen.Bounds.Width}×{screen.Bounds.Height}";
        if (!names.TryGetValue(screen.DeviceName, out string? name)) return caption;
        return name.ReplaceLineEndings(" ") + "\n" + caption;
    }
    [StructLayout(LayoutKind.Sequential)] struct Luid { public uint Low; public int High; }
    [StructLayout(LayoutKind.Sequential)] struct Header { public uint Type, Size; public Luid Adapter; public uint Id; }
    [StructLayout(LayoutKind.Explicit, Size = 72)] struct NativePath
    {
        [FieldOffset(0)] public Luid SourceAdapter; [FieldOffset(8)] public uint SourceId;
        [FieldOffset(20)] public Luid TargetAdapter; [FieldOffset(28)] public uint TargetId;
    }
    [StructLayout(LayoutKind.Explicit, Size = 64)] struct NativeMode { [FieldOffset(0)] public uint Type; }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] struct SourceName
    {
        public Header Header; [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string Name;
    }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] struct TargetName
    {
        public Header Header; public uint Flags, Technology; public ushort Manufacturer, Product; public uint Connector;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 64)] public string Name;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DevicePath;
    }
    [DllImport("user32.dll")] static extern int GetDisplayConfigBufferSizes(uint flags, out uint paths, out uint modes);
    [DllImport("user32.dll")] static extern int QueryDisplayConfig(uint flags, ref uint pathCount, [Out] NativePath[] paths, ref uint modeCount, [Out] NativeMode[] modes, IntPtr topology);
    [DllImport("user32.dll", EntryPoint = "DisplayConfigGetDeviceInfo")] static extern int GetSourceName(ref SourceName name);
    [DllImport("user32.dll", EntryPoint = "DisplayConfigGetDeviceInfo")] static extern int GetTargetName(ref TargetName name);
}
