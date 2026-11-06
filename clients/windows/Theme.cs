using System.Drawing.Drawing2D;
using System.Drawing.Text;
using System.Runtime.InteropServices;

namespace ZSirCapture;

internal static class Theme
{
    internal static readonly Color Background = Color.FromArgb(29, 31, 38), Panel = Color.FromArgb(43, 46, 55),
        Border = Color.FromArgb(65, 69, 81), Ink = Color.FromArgb(236, 238, 243),
        Muted = Color.FromArgb(157, 164, 179), Accent = Color.FromArgb(232, 93, 46),
        Mint = Color.FromArgb(104, 217, 183), Orange = Color.FromArgb(245, 164, 79);
    internal static Font Font(float size = 9, FontStyle style = FontStyle.Regular) => new("Microsoft YaHei UI", size, style);
    internal static Font IconFont(float size = 12)
    {
        using var installed = new InstalledFontCollection();
        return new Font(installed.Families.Any(f => f.Name == "Segoe Fluent Icons") ? "Segoe Fluent Icons" : "Segoe MDL2 Assets", size);
    }
    internal static Label Label(string text, bool muted = false) => new()
    {
        Text = text, AutoSize = true, ForeColor = muted ? Muted : Ink,
        BackColor = Color.Transparent, Margin = new Padding(0, 4, 0, 4), Anchor = AnchorStyles.Left
    };
    internal static Button Button(string text, bool primary = false)
    {
        var button = new Button { Text = text, AutoSize = true, AutoSizeMode = AutoSizeMode.GrowAndShrink,
            FlatStyle = FlatStyle.Flat, UseVisualStyleBackColor = false, BackColor = primary ? Accent : Panel,
            ForeColor = Ink, Padding = new Padding(8, 6, 8, 6), Margin = new Padding(0, 4, 0, 4), Cursor = Cursors.Hand };
        button.FlatAppearance.BorderColor = Border;
        button.FlatAppearance.BorderSize = primary ? 0 : 1;
        button.FlatAppearance.MouseOverBackColor = primary ? Color.FromArgb(248, 114, 64) : Border;
        return button;
    }
    internal static Button IconButton(string glyph, string name, ToolTip tip)
    {
        var button = Button(glyph); button.Font = IconFont(); button.AccessibleName = name;
        button.Padding = Padding.Empty; button.AutoSize = false;
        tip.SetToolTip(button, name); return button;
    }
    internal static TableLayoutPanel Column()
    {
        var column = new TableLayoutPanel { AutoSize = true, AutoSizeMode = AutoSizeMode.GrowAndShrink,
            Dock = DockStyle.Top, ColumnCount = 1, RowCount = 0, BackColor = Color.Transparent, Margin = Padding.Empty };
        column.ColumnStyles.Add(new(SizeType.Percent, 100)); return column;
    }
    internal static void Add(TableLayoutPanel column, Control child)
    {
        int row = column.RowCount++;
        column.RowStyles.Add(new(SizeType.AutoSize));
        child.Dock = DockStyle.Top; column.Controls.Add(child, 0, row);
    }
    internal static TableLayoutPanel Row(int flexible, params Control[] children)
    {
        var row = new TableLayoutPanel { AutoSize = true, AutoSizeMode = AutoSizeMode.GrowAndShrink,
            ColumnCount = children.Length, RowCount = 1, Dock = DockStyle.Top,
            BackColor = Color.Transparent, Margin = Padding.Empty };
        row.RowStyles.Add(new(SizeType.AutoSize));
        for (int i = 0; i < children.Length; i++)
        {
            row.ColumnStyles.Add(new(i == flexible ? SizeType.Percent : SizeType.AutoSize, i == flexible ? 100 : 0));
            row.Controls.Add(children[i], i, 0);
        }
        return row;
    }
    internal static CheckBox Toggle(string text, bool value) => new DarkCheckBox
        { Text = text, Checked = value, AutoSize = true, ForeColor = Ink, BackColor = Panel, Margin = new Padding(0, 8, 0, 8) };
    internal static ComboBox Combo(string name)
    {
        var combo = new ComboBox { AccessibleName = name, DropDownStyle = ComboBoxStyle.DropDownList,
            Dock = DockStyle.Top, FlatStyle = FlatStyle.Flat, BackColor = Panel, ForeColor = Ink,
            DrawMode = DrawMode.OwnerDrawFixed, Margin = new Padding(0, 4, 0, 8), IntegralHeight = false };
        void SizeItems() => combo.ItemHeight = Math.Max(combo.Font.Height + combo.LogicalToDeviceUnits(10), combo.LogicalToDeviceUnits(28));
        combo.FontChanged += (_, _) => SizeItems(); combo.DpiChangedAfterParent += (_, _) => SizeItems(); SizeItems();
        combo.DrawItem += (_, e) =>
        {
            using var fill = new SolidBrush((e.State & DrawItemState.Selected) != 0 ? Border : Panel);
            e.Graphics.FillRectangle(fill, e.Bounds);
            var bounds = Rectangle.Inflate(e.Bounds, -combo.LogicalToDeviceUnits(6), 0);
            TextRenderer.DrawText(e.Graphics, e.Index >= 0 ? combo.GetItemText(combo.Items[e.Index]) : combo.Text,
                combo.Font, bounds, combo.Enabled ? Ink : Muted, TextFormatFlags.VerticalCenter | TextFormatFlags.EndEllipsis);
            e.DrawFocusRectangle();
        };
        return combo;
    }
    internal static void Window(Form form)
    {
        form.AutoScaleDimensions = new SizeF(96F, 96F); form.AutoScaleMode = AutoScaleMode.Dpi;
        form.Font = Font(); form.BackColor = Background; form.ForeColor = Ink;
        void ApplyWindowTheme()
        {
            int dark = 1, corner = 2;
            if (DwmSetWindowAttribute(form.Handle, 20, ref dark, sizeof(int)) < 0)
                DwmSetWindowAttribute(form.Handle, 19, ref dark, sizeof(int));
            DwmSetWindowAttribute(form.Handle, 33, ref corner, sizeof(int));
            if (OperatingSystem.IsWindowsVersionAtLeast(10, 0, 22621))
            {
                int acrylic = 3; DwmSetWindowAttribute(form.Handle, 38, ref acrylic, sizeof(int));
            }
        }
        form.HandleCreated += (_, _) => ApplyWindowTheme();
        form.Shown += (_, _) => ApplyWindowTheme();
    }
    internal static GraphicsPath Rounded(Rectangle bounds, int radius)
    {
        var path = new GraphicsPath(); int d = Math.Min(radius * 2, Math.Min(bounds.Width, bounds.Height));
        if (d <= 0) { path.AddRectangle(bounds); return path; }
        path.AddArc(bounds.Left, bounds.Top, d, d, 180, 90); path.AddArc(bounds.Right - d, bounds.Top, d, d, 270, 90);
        path.AddArc(bounds.Right - d, bounds.Bottom - d, d, d, 0, 90); path.AddArc(bounds.Left, bounds.Bottom - d, d, d, 90, 90);
        path.CloseFigure(); return path;
    }
    internal static void WrapLabels(Control parent)
    {
        foreach (Control child in parent.Controls)
        {
            if (child is Label { AutoSize: true } label)
            {
                int available = parent.DisplayRectangle.Width;
                if (parent is TableLayoutPanel table)
                {
                    int column = table.GetColumn(child);
                    int[] widths = table.GetColumnWidths();
                    if (column >= 0 && column < widths.Length) available = widths.Skip(column).Take(table.GetColumnSpan(child)).Sum();
                }
                label.MaximumSize = new(Math.Max(1, available - child.Margin.Horizontal), label.MaximumSize.Height);
            }
            WrapLabels(child);
        }
    }
    internal static void ScaleLayoutFixture(Control root, float factor)
    {
        IEnumerable<Control> All(Control parent)
        {
            yield return parent;
            foreach (Control child in parent.Controls) foreach (var nested in All(child)) yield return nested;
        }
        var fonts = All(root).Select(c => (Control: c, Font: new Font(c.Font.FontFamily, c.Font.Size * factor, c.Font.Style))).ToArray();
        root.Scale(new SizeF(factor, factor));
        foreach (var item in fonts) item.Control.Font = item.Font;
    }
    [DllImport("dwmapi.dll")] static extern int DwmSetWindowAttribute(IntPtr hwnd, int attribute, ref int value, int size);

    internal sealed class SegmentButton : Button
    {
        readonly bool selected;
        static readonly Color DisabledInk = Color.FromArgb(
            (int)(Panel.R + (Muted.R - Panel.R) * .6),
            (int)(Panel.G + (Muted.G - Panel.G) * .6),
            (int)(Panel.B + (Muted.B - Panel.B) * .6));
        internal SegmentButton(string text, bool selected)
        {
            Text = text; this.selected = selected; Enabled = selected; Cursor = Cursors.Hand;
            AutoSize = true; AutoSizeMode = AutoSizeMode.GrowAndShrink;
            FlatStyle = FlatStyle.Flat; UseVisualStyleBackColor = false; BackColor = Panel;
            SetStyle(ControlStyles.UserPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
        }
        protected override void OnPaint(PaintEventArgs e)
        {
            e.Graphics.Clear(Panel);
            TextRenderer.DrawText(e.Graphics, Text, Font, ClientRectangle, selected ? Accent : DisabledInk,
                TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.SingleLine | TextFormatFlags.EndEllipsis);
            if (selected)
            {
                using var pen = new Pen(Accent, LogicalToDeviceUnits(1));
                e.Graphics.DrawRectangle(pen, Rectangle.Inflate(ClientRectangle, -1, -1));
            }
            if (Focused && ShowFocusCues) ControlPaint.DrawFocusRectangle(e.Graphics, Rectangle.Inflate(ClientRectangle, -3, -3));
        }
    }
    internal sealed class DisclosureButton : Button
    {
        internal bool Expanded = true;
        internal DisclosureButton()
        {
            Text = "收起预览"; Font = Theme.Font(8); ForeColor = Muted; Cursor = Cursors.Hand;
            AutoSize = true; AutoSizeMode = AutoSizeMode.GrowAndShrink;
            FlatStyle = FlatStyle.Flat; FlatAppearance.BorderSize = 0; UseVisualStyleBackColor = false;
            SetStyle(ControlStyles.SupportsTransparentBackColor | ControlStyles.UserPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
            BackColor = Color.Transparent; Padding = Padding.Empty;
        }
        public override Size GetPreferredSize(Size proposedSize)
        {
            var text = TextRenderer.MeasureText(Text, Font);
            return new(text.Width + Font.Height + LogicalToDeviceUnits(4), Math.Max(text.Height, Font.Height));
        }
        protected override void OnPaint(PaintEventArgs e)
        {
            int iconWidth = Font.Height, gap = LogicalToDeviceUnits(4);
            using var icon = IconFont(Font.Size);
            TextRenderer.DrawText(e.Graphics, Expanded ? "\uE70D" : "\uE76C", icon, new Rectangle(0, 0, iconWidth, Height), Muted,
                TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.SingleLine);
            TextRenderer.DrawText(e.Graphics, Text, Font, new Rectangle(iconWidth + gap, 0, Math.Max(0, Width - iconWidth - gap), Height), Muted,
                TextFormatFlags.Left | TextFormatFlags.VerticalCenter | TextFormatFlags.SingleLine);
            if (Focused && ShowFocusCues) ControlPaint.DrawFocusRectangle(e.Graphics, ClientRectangle);
        }
    }
    sealed class DarkCheckBox : CheckBox
    {
        protected override void OnPaint(PaintEventArgs e)
        {
            e.Graphics.Clear(BackColor);
            int size = LogicalToDeviceUnits(16), gap = LogicalToDeviceUnits(8);
            var box = new Rectangle(0, (Height - size) / 2, size - 1, size - 1);
            using var fill = new SolidBrush(Checked ? Accent : Background); using var pen = new Pen(Enabled ? Border : Muted);
            e.Graphics.FillRectangle(fill, box); e.Graphics.DrawRectangle(pen, box);
            if (Checked) TextRenderer.DrawText(e.Graphics, "✓", Font, box, Ink, TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.NoPadding);
            TextRenderer.DrawText(e.Graphics, Text, Font, new Rectangle(size + gap, 0, Math.Max(0, Width - size - gap), Height), Enabled ? Ink : Muted, TextFormatFlags.VerticalCenter | TextFormatFlags.WordBreak);
            if (Focused && ShowFocusCues) ControlPaint.DrawFocusRectangle(e.Graphics, ClientRectangle);
        }
        public override Size GetPreferredSize(Size proposedSize)
        {
            var text = TextRenderer.MeasureText(Text, Font);
            return new(text.Width + LogicalToDeviceUnits(28), Math.Max(text.Height, LogicalToDeviceUnits(20)));
        }
    }
    internal sealed class Card : TableLayoutPanel
    {
        internal Card()
        {
            DoubleBuffered = true; AutoSize = true; AutoSizeMode = AutoSizeMode.GrowAndShrink;
            ColumnCount = 1; RowCount = 0; ColumnStyles.Add(new(SizeType.Percent, 100)); BackColor = Panel;
            Padding = new Padding(16); Margin = new Padding(0, 12, 0, 12);
        }
        protected override void OnPaintBackground(PaintEventArgs e)
        {
            e.Graphics.Clear(Background); e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
            using var path = Rounded(Rectangle.Inflate(ClientRectangle, -1, -1), LogicalToDeviceUnits(12));
            using var fill = new SolidBrush(Panel); using var pen = new Pen(Border);
            e.Graphics.FillPath(fill, path); e.Graphics.DrawPath(pen, path);
        }
    }
    internal sealed class PreviewTile : PictureBox
    {
        internal string Caption = "桌面 · 系统声音";
        internal PreviewTile() { SizeMode = PictureBoxSizeMode.Zoom; BackColor = Panel; }
        protected override void OnSizeChanged(EventArgs e)
        {
            base.OnSizeChanged(e);
            using var path = Rounded(ClientRectangle, LogicalToDeviceUnits(10));
            var old = Region; Region = new Region(path); old?.Dispose();
        }
        protected override void OnPaint(PaintEventArgs e)
        {
            base.OnPaint(e);
            if (Image == null) TextRenderer.DrawText(e.Graphics, "正在加载桌面预览", Font, ClientRectangle, Muted, TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter);
            int inset = LogicalToDeviceUnits(8);
            var caption = new Rectangle(inset, inset, Math.Max(1, Width - inset * 2), Font.Height + inset);
            using var fill = new SolidBrush(Color.FromArgb(210, Background)); e.Graphics.FillRectangle(fill, caption);
            TextRenderer.DrawText(e.Graphics, Caption, Font, caption, Ink, TextFormatFlags.VerticalCenter | TextFormatFlags.EndEllipsis);
        }
    }
}

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
