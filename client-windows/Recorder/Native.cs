using System.Runtime.InteropServices;
using Windows.Graphics.Capture;
using Windows.Graphics.DirectX.Direct3D11;

namespace ZsirRecorder;

internal static class Native
{
    [DllImport("d3d11.dll")] static extern int D3D11CreateDevice(nint adapter, int driver, nint software, uint flags, nint levels, uint count, uint sdk, out nint device, out int level, out nint context);
    [DllImport("d3d11.dll")] static extern int CreateDirect3D11DeviceFromDXGIDevice(nint dxgi, out nint device);
    [DllImport("combase.dll")] static extern int WindowsCreateString([MarshalAs(UnmanagedType.LPWStr)] string text, int length, out nint value);
    [DllImport("combase.dll")] static extern int WindowsDeleteString(nint value);
    [DllImport("combase.dll")] static extern int RoGetActivationFactory(nint name, in Guid iid, out nint factory);
    [DllImport("user32.dll")] internal static extern bool EnumDisplayMonitors(nint dc, nint clip, MonitorCallback callback, nint data);
    internal delegate bool MonitorCallback(nint monitor, nint dc, ref Rect rect, nint data);
    [StructLayout(LayoutKind.Sequential)] internal struct Rect { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern nint CreateWindowExW(uint ex, string cls, string name, uint style, int x, int y, int w, int h, nint parent, nint menu, nint instance, nint param);
    [DllImport("user32.dll", SetLastError = true)] static extern bool SetWindowDisplayAffinity(nint hwnd, uint affinity);
    [DllImport("user32.dll")] static extern bool DestroyWindow(nint hwnd);
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct ReasonContext { public uint Version, Flags; [MarshalAs(UnmanagedType.LPWStr)] public string Reason; }
    [DllImport("kernel32.dll", SetLastError = true)] static extern Microsoft.Win32.SafeHandles.SafeFileHandle PowerCreateRequest(ref ReasonContext context);
    [DllImport("kernel32.dll")] static extern bool PowerSetRequest(Microsoft.Win32.SafeHandles.SafeFileHandle handle, int type);
    [DllImport("kernel32.dll")] static extern bool PowerClearRequest(Microsoft.Win32.SafeHandles.SafeFileHandle handle, int type);
    internal sealed class PowerRequest : IDisposable
    {
        readonly Microsoft.Win32.SafeHandles.SafeFileHandle handle;
        internal PowerRequest()
        {
            var reason = new ReasonContext { Flags = 1, Reason = "庄Sir采访录制" };
            handle = PowerCreateRequest(ref reason);
            if (handle.IsInvalid || !PowerSetRequest(handle, 0) || !PowerSetRequest(handle, 1))
                Console.Error.WriteLine("POWER_REQUEST_FAILED: 无法阻止休眠，请保持电脑唤醒。");
        }
        public void Dispose() { if (!handle.IsInvalid) { PowerClearRequest(handle, 0); PowerClearRequest(handle, 1); } handle.Dispose(); }
    }

    [ComImport, Guid("3628E81B-3CAC-4C60-B7F4-23CE0E0C3356"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface ICaptureItemInterop
    {
        void CreateForWindow(nint window, in Guid iid, out nint result);
        void CreateForMonitor(nint monitor, in Guid iid, out nint result);
    }

    internal static IDirect3DDevice CreateDevice()
    {
        Marshal.ThrowExceptionForHR(D3D11CreateDevice(0, 1, 0, 0x20, 0, 0, 7, out var device, out _, out var context));
        nint dxgi = 0, inspectable = 0;
        try
        {
            var iid = new Guid("54EC77FA-1377-44E6-8C32-88FD5F44C84C");
            Marshal.ThrowExceptionForHR(Marshal.QueryInterface(device, ref iid, out dxgi));
            Marshal.ThrowExceptionForHR(CreateDirect3D11DeviceFromDXGIDevice(dxgi, out inspectable));
            return WinRT.MarshalInterface<IDirect3DDevice>.FromAbi(inspectable);
        }
        finally
        {
            if (inspectable != 0) Marshal.Release(inspectable);
            if (dxgi != 0) Marshal.Release(dxgi);
            Marshal.Release(context); Marshal.Release(device);
        }
    }

    internal static GraphicsCaptureItem Item(nint monitor)
    {
        const string name = "Windows.Graphics.Capture.GraphicsCaptureItem";
        Marshal.ThrowExceptionForHR(WindowsCreateString(name, name.Length, out var str));
        nint factory = 0, item = 0;
        object? interop = null;
        try
        {
            Marshal.ThrowExceptionForHR(RoGetActivationFactory(str, typeof(ICaptureItemInterop).GUID, out factory));
            interop = Marshal.GetObjectForIUnknown(factory);
            ((ICaptureItemInterop)interop).CreateForMonitor(monitor, new Guid("79C3F95B-31F7-4EC2-A464-632EF5D30760"), out item);
            return WinRT.MarshalInspectable<GraphicsCaptureItem>.FromAbi(item);
        }
        finally
        {
            if (item != 0) Marshal.Release(item);
            if (interop != null) Marshal.ReleaseComObject(interop);
            if (factory != 0) Marshal.Release(factory);
            WindowsDeleteString(str);
        }
    }

    internal static bool TestWindowExclusion()
    {
        var window = CreateWindowExW(0, "STATIC", "zsir exclusion probe", 0, 0, 0, 16, 16, 0, 0, 0, 0);
        if (window == 0) return false;
        try { return OperatingSystem.IsWindowsVersionAtLeast(10, 0, 19041) && SetWindowDisplayAffinity(window, 0x11); }
        finally { DestroyWindow(window); }
    }
}
