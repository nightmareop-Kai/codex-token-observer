using System;
using System.Globalization;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Automation.Peers;
using System.Windows.Media;
using System.Windows.Media.Animation;

namespace TokenObserver;

/// <summary>
/// A mechanical counter: a higher wheel moves only while its lower wheels carry.
/// Long integers stay exact; only the final, at-most-48-token movement uses doubles.
/// WPF owns the short animation clock. No rendering timer runs while the counter rests.
/// </summary>
public sealed class RollingNumber : FrameworkElement
{
    private static readonly DependencyProperty ProgressProperty = DependencyProperty.Register(
        "Progress", typeof(double), typeof(RollingNumber),
        new FrameworkPropertyMetadata(1d, FrameworkPropertyMetadataOptions.AffectsRender));

    private static readonly Typeface CounterTypeface = new(
        new FontFamily("Bahnschrift, Segoe UI"), FontStyles.Normal,
        FontWeights.SemiBold, FontStretches.Condensed);
    private static readonly Brush LeadingZeroBrush = FrozenBrush(Color.FromArgb(104, 122, 140, 158));

    private long _start;
    private long _target;
    private bool _hasValue;
    private int _animationGeneration;
    private Brush _digitBrush = FrozenBrush(Color.FromRgb(102, 219, 242));

    public double DigitSize { get; set; } = 20;
    public int MinimumDigits { get; set; } = 12;
    public long Value => _target;

    public Brush DigitBrush
    {
        get => _digitBrush;
        set { _digitBrush = value; InvalidateVisual(); }
    }

    public RollingNumber()
    {
        SnapsToDevicePixels = true;
        ClipToBounds = true;
        Focusable = false;
        TextOptions.SetTextFormattingMode(this, TextFormattingMode.Display);
        TextOptions.SetTextRenderingMode(this, TextRenderingMode.Grayscale);
        AutomationProperties.SetName(this, "0 tokens");
    }

    public void SetValue(long value, bool animate = true)
    {
        Dispatcher.VerifyAccess();
        value = Math.Max(0, value);
        if (_hasValue && value == _target) return;

        var current = DisplayedInteger();
        var shouldAnimate = animate && _hasValue && value > _target;
        var previousTarget = _target;
        _animationGeneration++;
        BeginAnimation(ProgressProperty, null);
        _hasValue = true;
        _target = value;
        AutomationProperties.SetName(this, value.ToString(CultureInfo.InvariantCulture) + " tokens");

        if (!shouldAnimate)
        {
            _start = value;
            base.SetValue(ProgressProperty, 1d);
            InvalidateVisual();
            return;
        }

        // Skip the unreadable part of a large batch, then let the real tail settle.
        _start = Math.Max(current, value - Math.Min(value, 48));
        var delta = value - previousTarget;
        StartAnimation(Math.Clamp(3 + Math.Log10(Math.Max(1, delta)) * 0.24, 3, 4.5));
    }

    public void Replay()
    {
        Dispatcher.VerifyAccess();
        if (!_hasValue || _target == 0) return;
        _animationGeneration++;
        BeginAnimation(ProgressProperty, null);
        _start = _target - Math.Min(_target, 48);
        StartAnimation(3.8);
    }

    private void StartAnimation(double seconds)
    {
        var generation = ++_animationGeneration;
        base.SetValue(ProgressProperty, 1d);
        var animation = new DoubleAnimation(0, 1, TimeSpan.FromSeconds(seconds))
        {
            EasingFunction = new CubicEase { EasingMode = EasingMode.EaseOut },
            FillBehavior = FillBehavior.Stop
        };
        animation.Completed += (_, _) =>
        {
            // A cancelled clock must not stop a newer update or replay.
            if (generation != _animationGeneration) return;
            _animationGeneration++;
            BeginAnimation(ProgressProperty, null);
            _start = _target;
            InvalidateVisual();
        };
        BeginAnimation(ProgressProperty, animation, HandoffBehavior.SnapshotAndReplace);
    }

    private long DisplayedInteger()
    {
        var distance = _target - _start;
        var progress = Math.Clamp((double)GetValue(ProgressProperty), 0, 1);
        return _start + Math.Min(distance, (long)Math.Floor(distance * progress));
    }

    protected override Size MeasureOverride(Size availableSize) => new(
        double.IsInfinity(availableSize.Width) ? DigitSize * 8 : availableSize.Width,
        DigitSize * 1.35);

    protected override void OnRender(DrawingContext drawingContext)
    {
        base.OnRender(drawingContext);
        if (ActualWidth <= 0 || ActualHeight <= 0) return;

        var progress = Math.Clamp((double)GetValue(ProgressProperty), 0, 1);
        var movement = (_target - _start) * progress;
        var steps = (long)Math.Floor(movement);
        var current = _start + Math.Min(_target - _start, steps);
        var fraction = current == _target ? 0 : movement - steps;
        var currentDigits = current.ToString(CultureInfo.InvariantCulture).Length;
        var count = Math.Max(Math.Clamp(MinimumDigits, 1, 19), _target.ToString(CultureInfo.InvariantCulture).Length);
        var groupCount = (count - 1) / 3;
        var fontSize = Math.Min(DigitSize, ActualWidth / (count * 0.61 + groupCount * 0.28));
        fontSize = Math.Max(1, fontSize);
        var digitWidth = fontSize * 0.61;
        var groupWidth = fontSize * 0.28;
        var totalWidth = count * digitWidth + groupCount * groupWidth;
        var x = ActualWidth - totalWidth;
        var rowHeight = ActualHeight;
        var dpi = VisualTreeHelper.GetDpi(this).PixelsPerDip;

        for (var index = 0; index < count; index++)
        {
            if (index > 0 && (count - index) % 3 == 0) x += groupWidth;
            var power = count - index - 1;
            long place = 1;
            for (var exponent = 0; exponent < power; exponent++) place *= 10;
            var digit = (int)((current / place) % 10);
            // Units always rotate; tens rotate only from x9 to x0, and so on.
            var carry = current % place == place - 1 ? fraction : 0;
            var active = index >= count - currentDigits;
            var incomingActive = active || (carry > 0 && digit == 0);

            drawingContext.PushClip(new RectangleGeometry(new Rect(x, 0, digitWidth, rowHeight)));
            DrawDigit(drawingContext, digit, x, -carry * rowHeight,
                digitWidth, rowHeight, fontSize, dpi, active ? DigitBrush : LeadingZeroBrush);
            if (carry > 0)
                DrawDigit(drawingContext, (digit + 1) % 10, x, (1 - carry) * rowHeight,
                    digitWidth, rowHeight, fontSize, dpi, incomingActive ? DigitBrush : LeadingZeroBrush);
            drawingContext.Pop();
            x += digitWidth;
        }
    }

    private static void DrawDigit(DrawingContext context, int digit, double x, double y,
        double width, double height, double size, double dpi, Brush brush)
    {
        var text = new FormattedText(digit.ToString(CultureInfo.InvariantCulture),
            CultureInfo.InvariantCulture, FlowDirection.LeftToRight, CounterTypeface, size, brush, dpi);
        context.DrawText(text, new Point(x + (width - text.WidthIncludingTrailingWhitespace) / 2,
            y + (height - text.Height) / 2));
    }

    protected override AutomationPeer OnCreateAutomationPeer() => new CounterAutomationPeer(this);

    private sealed class CounterAutomationPeer(RollingNumber owner) : FrameworkElementAutomationPeer(owner)
    {
        protected override string GetClassNameCore() => nameof(RollingNumber);
        protected override AutomationControlType GetAutomationControlTypeCore() => AutomationControlType.Text;
    }

    private static Brush FrozenBrush(Color color)
    {
        var brush = new SolidColorBrush(color);
        brush.Freeze();
        return brush;
    }
}
