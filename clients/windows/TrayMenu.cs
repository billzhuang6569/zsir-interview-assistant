namespace ZSirCapture;

internal sealed class TrayMenu : IDisposable
{
    readonly NotifyIcon icon;
    readonly ContextMenuStrip menu = new();

    internal TrayMenu(MainForm owner)
    {
        var stealth = new ToolStripMenuItem("在录屏里隐身");
        stealth.Click += (_, _) => owner.SetStealthInCapture(!owner.StealthInCapture);
        var show = new ToolStripMenuItem("显示小窗", null, (_, _) => owner.ShowSmallWindow());
        var record = new ToolStripMenuItem("开始录制");
        record.Click += async (_, _) => { if (owner.IsRecording) await owner.StopRecordingAsync(); else if (owner.CanStartRecording) await owner.StartRecordingAsync(); };
        menu.Items.AddRange(new ToolStripItem[] { stealth, show, record, new ToolStripMenuItem("打开素材目录", null, (_, _) => owner.OpenMaterialFolder()), new ToolStripSeparator(), new ToolStripMenuItem("退出", null, (_, _) => owner.Close()) });
        menu.Opening += (_, _) =>
        {
            stealth.Checked = owner.StealthInCapture;
            stealth.Enabled = owner.CanChangeStealth;
            record.Text = owner.IsRecording ? "停止并保存" : "开始录制";
            record.Enabled = owner.IsRecording || owner.CanStartRecording;
        };
        icon = new NotifyIcon { Icon = owner.Icon ?? SystemIcons.Application, Text = "庄Sir采访录制助手", ContextMenuStrip = menu, Visible = true };
        icon.DoubleClick += (_, _) => owner.ShowSmallWindow();
    }
    public void Dispose() { icon.Visible = false; icon.Dispose(); menu.Dispose(); }
}
