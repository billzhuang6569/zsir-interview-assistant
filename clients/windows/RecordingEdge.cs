using System.Diagnostics;
using System.Drawing.Drawing2D;
using System.Runtime.InteropServices;

namespace ZSirCapture;

internal sealed class RecordingEdge : Form, IMessageFilter
{
    readonly MainForm owner;
    readonly System.Windows.Forms.Timer animation = new() { Interval = 80 };
    readonly Stopwatch motion = Stopwatch.StartNew();
    readonly ToolTip tip = new();
    double lastInteraction;
    public bool IsDocked { get; private set; }
    public bool Excluded { get; private set; }
    static double Now => Stopwatch.GetTimestamp() / (double)Stopwatch.Frequency;

    public RecordingEdge(MainForm owner)
    {
        this.owner = owner;
        Text = "正在录制 · 点击展开";
        AccessibleRole = AccessibleRole.PushButton;
        AccessibleName = "展开录制窗口";
        FormBorderStyle = FormBorderStyle.None; ShowInTaskbar = false; TopMost = true;
        StartPosition = FormStartPosition.Manual;
        ClientSize = new(32, 40); BackColor = Color.Fuchsia; TransparencyKey = Color.Fuchsia;
        DoubleBuffered = true; Cursor = Cursors.Hand;
        HandleCreated += (_, _) => Excluded = SetWindowDisplayAffinity(Handle, 0x11);
        MouseClick += (_, _) => Reveal(true);
        animation.Tick += (_, _) => { Place(); Invalidate(); };
        Application.AddMessageFilter(this);
        ResetIdle();
    }
    protected override bool ShowWithoutActivation => true;
    protected override CreateParams CreateParams { get { var p = base.CreateParams; p.ExStyle |= 0x08000000; return p; } }
    public void ResetIdle() => lastInteraction = Now;
    public bool PreFilterMessage(ref Message message)
    {
        if (message.Msg is 0x100 or 0x101 or 0x200 or 0x201 or 0x204 or 0x207 or 0x20A)
            if (Control.FromHandle(message.HWnd)?.FindForm() == owner) ResetIdle();
        return false;
    }
    public void Tick()
    {
        if (!owner.IsRecording || owner.LastError != null || !owner.Enabled)
        { if (IsDocked) Reveal(false); ResetIdle(); return; }
        tip.SetToolTip(this, $"正在录制 {owner.Timecode} · 点击展开");
        AccessibleName = $"正在录制 {owner.Timecode}，展开录制窗口";
        if (!IsDocked && Now - lastInteraction >= 15 && owner.WindowState != FormWindowState.Minimized)
        {
            _ = Handle;
            if (!Excluded) { ResetIdle(); return; }
            Place(); IsDocked = true; Show(); owner.Hide(); animation.Start();
        }
    }
    void Place()
    {
        var area = Screen.FromRectangle(owner.Bounds).WorkingArea;
        Location = new(area.Right - Width, Math.Clamp(owner.Top + owner.Height / 2 - Height / 2, area.Top, area.Bottom - Height));
    }
    public void Reveal(bool activate)
    {
        ResetIdle();
        if (!IsDocked) return;
        IsDocked = false; animation.Stop(); Hide();
        var area = Screen.FromRectangle(owner.Bounds).WorkingArea;
        owner.Location = new(Math.Clamp(owner.Left, area.Left, Math.Max(area.Left, area.Right - owner.Width)),
            Math.Clamp(owner.Top, area.Top, Math.Max(area.Top, area.Bottom - owner.Height)));
        owner.Show();
        if (activate) owner.Activate();
    }
    protected override void OnPaint(PaintEventArgs e)
    {
        base.OnPaint(e);
        e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
        SystemParametersInfo(0x1042, 0, out bool animationsEnabled, 0);
        float bounce = animationsEnabled ? (float)Math.Sin(motion.Elapsed.TotalSeconds * Math.PI / .85) * 2 : 0;
        var circle = new RectangleF((Width - 19) / 2f, (Height - 19) / 2f + bounce, 19, 19);
        using var fill = new SolidBrush(Color.FromArgb(35, 30, 32));
        using var stroke = new Pen(Color.FromArgb(255, 65, 65), 3);
        e.Graphics.FillEllipse(fill, circle); e.Graphics.DrawEllipse(stroke, circle);
    }
    protected override void Dispose(bool disposing)
    {
        if (disposing) { Application.RemoveMessageFilter(this); animation.Dispose(); tip.Dispose(); }
        base.Dispose(disposing);
    }
    [DllImport("user32.dll")] static extern bool SystemParametersInfo(uint action, uint param, [MarshalAs(UnmanagedType.Bool)] out bool value, uint flags);
    [DllImport("user32.dll")] static extern bool SetWindowDisplayAffinity(IntPtr hwnd, uint affinity);
}
