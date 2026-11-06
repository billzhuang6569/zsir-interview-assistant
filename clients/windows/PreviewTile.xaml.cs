using System.Windows;
using System.Windows.Controls;
using System.Windows.Media.Imaging;

namespace ZSirCapture;

public partial class PreviewTile : UserControl
{
    public PreviewTile() { InitializeComponent(); UpdateEmpty(); }
    public static readonly DependencyProperty ImageProperty = DependencyProperty.Register(nameof(Image), typeof(BitmapSource), typeof(PreviewTile), new PropertyMetadata(null, Changed));
    public static readonly DependencyProperty CaptionProperty = DependencyProperty.Register(nameof(Caption), typeof(string), typeof(PreviewTile), new PropertyMetadata(""));
    public static readonly DependencyProperty GlyphProperty = DependencyProperty.Register(nameof(Glyph), typeof(string), typeof(PreviewTile), new PropertyMetadata("\uE714"));
    public static readonly DependencyProperty EmptyGlyphProperty = DependencyProperty.Register(nameof(EmptyGlyph), typeof(string), typeof(PreviewTile), new PropertyMetadata("\uE714"));
    public static readonly DependencyProperty EmptyTextProperty = DependencyProperty.Register(nameof(EmptyText), typeof(string), typeof(PreviewTile), new PropertyMetadata("等待预览"));
    public static readonly DependencyProperty ShowRetryProperty = DependencyProperty.Register(nameof(ShowRetry), typeof(bool), typeof(PreviewTile), new PropertyMetadata(false));
    public static readonly DependencyProperty ShowMeterProperty = DependencyProperty.Register(nameof(ShowMeter), typeof(bool), typeof(PreviewTile), new PropertyMetadata(false));
    public static readonly DependencyProperty RecordingProperty = DependencyProperty.Register(nameof(Recording), typeof(bool), typeof(PreviewTile), new PropertyMetadata(false));
    public static readonly DependencyProperty RatioProperty = DependencyProperty.Register(nameof(Ratio), typeof(double), typeof(PreviewTile), new PropertyMetadata(1.6));
    public static readonly DependencyProperty LevelProperty = DependencyProperty.Register(nameof(Level), typeof(double), typeof(PreviewTile), new PropertyMetadata(0.0, Changed));
    static readonly DependencyPropertyKey MeterHeightPropertyKey = DependencyProperty.RegisterReadOnly(nameof(MeterHeight), typeof(double), typeof(PreviewTile), new PropertyMetadata(0.0));
    public static readonly DependencyProperty MeterHeightProperty = MeterHeightPropertyKey.DependencyProperty;
    public BitmapSource? Image { get => (BitmapSource?)GetValue(ImageProperty); set => SetValue(ImageProperty, value); }
    public string Caption { get => (string)GetValue(CaptionProperty); set => SetValue(CaptionProperty, value); }
    public string Glyph { get => (string)GetValue(GlyphProperty); set => SetValue(GlyphProperty, value); }
    public string EmptyGlyph { get => (string)GetValue(EmptyGlyphProperty); set => SetValue(EmptyGlyphProperty, value); }
    public string EmptyText { get => (string)GetValue(EmptyTextProperty); set => SetValue(EmptyTextProperty, value); }
    public bool ShowRetry { get => (bool)GetValue(ShowRetryProperty); set => SetValue(ShowRetryProperty, value); }
    public bool ShowMeter { get => (bool)GetValue(ShowMeterProperty); set => SetValue(ShowMeterProperty, value); }
    public bool Recording { get => (bool)GetValue(RecordingProperty); set => SetValue(RecordingProperty, value); }
    public double Ratio { get => (double)GetValue(RatioProperty); set => SetValue(RatioProperty, value); }
    public double Level { get => (double)GetValue(LevelProperty); set => SetValue(LevelProperty, value); }
    public double MeterHeight => (double)GetValue(MeterHeightProperty);
    public event RoutedEventHandler? RetryRequested;
    void RetryClick(object sender, RoutedEventArgs e) => RetryRequested?.Invoke(this, e);
    static void Changed(DependencyObject d, DependencyPropertyChangedEventArgs e) => ((PreviewTile)d).UpdateEmpty();
    void UpdateEmpty()
    {
        if (Empty == null) return;
        Empty.Visibility = Image == null ? Visibility.Visible : Visibility.Collapsed;
        SetValue(MeterHeightPropertyKey, Math.Clamp(Level, 0, 100) * .26);
    }
}
