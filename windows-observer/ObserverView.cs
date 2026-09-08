using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Data;
using System.Windows.Input;
using System.Windows.Markup;
using System.Windows.Media;
using System.Windows.Shapes;

namespace TokenObserver;

/// <summary>The Windows companion to the macOS floating observer, without stored usage state.</summary>
public sealed class ObserverView : Border
{
    public const double CompactHeight = 248;
    public const double ExpandedHeight = 400;
    private const double CompactListHeight = 78;
    private const double ExpandedListHeight = 230;

    private static readonly Brush Accent = BrushFor(102, 219, 242);
    private static readonly Brush Silver = BrushFor(199, 214, 230);
    private static readonly Brush Secondary = BrushFor(153, 171, 186);
    private static readonly Brush Muted = BrushFor(99, 116, 132);
    private static readonly Brush Red = BrushFor(250, 89, 87);
    private static readonly FontFamily InterfaceFont = new("Bahnschrift, Segoe UI");

    private readonly TextBlock _connection;
    private readonly Ellipse _connectionDot;
    private readonly TextBlock _quotaValue;
    private readonly TextBlock _quotaStale;
    private readonly StackPanel _quotaSection;
    private readonly Border _quotaTrack;
    private readonly Border _quotaFill;
    private readonly RollingNumber _today;
    private readonly RollingNumber _total;
    private readonly Button _projectsButton;
    private readonly TextBlock _projectsLabel;
    private readonly TextBlock _projectsToggle;
    private readonly StackPanel _projectList;
    private readonly ScrollViewer _projectScroll;
    private readonly Grid _projectArea;
    private readonly TextBlock _emptyState;
    private readonly Dictionary<string, ProjectRow> _rows = new(StringComparer.Ordinal);
    private List<ProjectUsage> _projects = [];
    private bool _hasSnapshot;
    private bool _connected;
    private bool _overLimit;
    private double _quotaFraction;

    public event Action<bool>? ExpandedChanged;
    public bool Expanded { get; private set; }

    public ObserverView()
    {
        Width = 300;
        Height = CompactHeight;
        Padding = new Thickness(14, 12, 14, 12);
        CornerRadius = new CornerRadius(14);
        BorderThickness = new Thickness(0.7);
        SnapsToDevicePixels = true;
        UseLayoutRounding = true;
        SetBackground(true);

        var content = new StackPanel();
        Child = content;

        var header = new Grid { Margin = new Thickness(0, 0, 0, 8) };
        header.ColumnDefinitions.Add(new ColumnDefinition());
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var brand = new StackPanel { Orientation = Orientation.Horizontal };
        brand.Children.Add(Label("ZUNO", 8, Silver));
        brand.Children.Add(Label("  /  TOKEN COUNTER", 8, Secondary));
        header.Children.Add(brand);
        var connectionArea = new StackPanel { Orientation = Orientation.Horizontal };
        _connectionDot = new Ellipse { Width = 4, Height = 4, Fill = Brushes.Orange, Margin = new Thickness(0, 0, 5, 0) };
        _connection = Label("SYNC", 8, Secondary);
        connectionArea.Children.Add(_connectionDot);
        connectionArea.Children.Add(_connection);
        Grid.SetColumn(connectionArea, 1);
        header.Children.Add(connectionArea);
        content.Children.Add(header);

        _quotaSection = new StackPanel { Margin = new Thickness(0, 0, 0, 9) };
        var quotaHeader = new Grid { Height = 16, Margin = new Thickness(0, 0, 0, 4) };
        quotaHeader.ColumnDefinitions.Add(new ColumnDefinition());
        quotaHeader.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var quotaLabels = new StackPanel { Orientation = Orientation.Horizontal };
        quotaLabels.Children.Add(Label("WEEKLY REMAINING", 8, Secondary));
        _quotaStale = Label("STALE", 7, Secondary);
        _quotaStale.Margin = new Thickness(6, 0, 0, 0);
        _quotaStale.Visibility = Visibility.Collapsed;
        quotaLabels.Children.Add(_quotaStale);
        quotaHeader.Children.Add(quotaLabels);
        _quotaValue = Label("—", 11, Secondary);
        Grid.SetColumn(_quotaValue, 1);
        quotaHeader.Children.Add(_quotaValue);
        _quotaSection.Children.Add(quotaHeader);
        _quotaTrack = new Border { Height = 2, Background = BrushFor(43, 55, 67), CornerRadius = new CornerRadius(1) };
        _quotaFill = new Border { Width = 0, Height = 2, HorizontalAlignment = HorizontalAlignment.Left, CornerRadius = new CornerRadius(1) };
        _quotaTrack.Child = _quotaFill;
        _quotaTrack.SizeChanged += (_, _) => UpdateQuotaWidth();
        _quotaSection.Children.Add(_quotaTrack);
        content.Children.Add(_quotaSection);

        _today = new RollingNumber { DigitSize = 20, DigitBrush = Accent, Height = 27 };
        _total = new RollingNumber { DigitSize = 16, DigitBrush = Silver, Height = 23 };
        content.Children.Add(CounterLine("TODAY", _today, Accent));
        var totalLine = CounterLine("TOTAL", _total, Secondary);
        totalLine.Margin = new Thickness(0, 3, 0, 9);
        content.Children.Add(totalLine);
        content.Children.Add(new Border { Height = 1, Background = BrushFor(38, 51, 65) });

        var projectHeader = new Grid { Background = Brushes.Transparent, Height = 30 };
        projectHeader.ColumnDefinitions.Add(new ColumnDefinition());
        projectHeader.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        _projectsLabel = Label("PROJECTS / TODAY", 8, Secondary);
        _projectsToggle = Label("ALL 0  ⌄", 8, Secondary);
        Grid.SetColumn(_projectsToggle, 1);
        projectHeader.Children.Add(_projectsLabel);
        projectHeader.Children.Add(_projectsToggle);
        _projectsButton = new Button
        {
            Content = projectHeader, Background = Brushes.Transparent, BorderThickness = new Thickness(0),
            Padding = new Thickness(0), Height = 30, HorizontalContentAlignment = HorizontalAlignment.Stretch,
            VerticalContentAlignment = VerticalAlignment.Center, Cursor = Cursors.Hand,
            ToolTip = "Show all projects, ranked by today's usage."
        };
        // A chrome-free template avoids the system's bright default hover panel.
        var presenter = new FrameworkElementFactory(typeof(ContentPresenter));
        presenter.SetValue(ContentPresenter.HorizontalAlignmentProperty, HorizontalAlignment.Stretch);
        presenter.SetValue(ContentPresenter.VerticalAlignmentProperty, VerticalAlignment.Center);
        _projectsButton.Template = new ControlTemplate(typeof(Button)) { VisualTree = presenter };
        _projectsButton.Click += (_, _) => ToggleExpanded();
        _projectsButton.MouseEnter += (_, _) => SetProjectHeaderBrush(Accent);
        _projectsButton.MouseLeave += (_, _) => SetProjectHeaderBrush(Secondary);
        content.Children.Add(_projectsButton);

        _projectList = new StackPanel { HorizontalAlignment = HorizontalAlignment.Left };
        _projectScroll = new ScrollViewer
        {
            Content = _projectList, VerticalScrollBarVisibility = ScrollBarVisibility.Hidden,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled, CanContentScroll = false,
            Padding = new Thickness(0), Focusable = false
        };
        _projectScroll.Resources.Add(typeof(ScrollBar), CreateScrollBarStyle());
        // Match the actual viewport, not the outer scroll viewer: its scrollbar
        // owns a separate column and must never cover the final digit.
        _projectList.SetBinding(WidthProperty, new Binding(nameof(ScrollViewer.ViewportWidth)) { Source = _projectScroll });
        _projectArea = new Grid { Height = CompactListHeight };
        _projectArea.Children.Add(_projectScroll);
        _emptyState = Label("Reading local activity…", 10, Secondary);
        _emptyState.HorizontalAlignment = HorizontalAlignment.Center;
        _emptyState.VerticalAlignment = VerticalAlignment.Center;
        _projectArea.Children.Add(_emptyState);
        content.Children.Add(_projectArea);
        SetConnected(false);
        UpdateQuota(null);
    }

    public void Apply(UsageSnapshot snapshot, bool animate = true)
    {
        Dispatcher.VerifyAccess();
        var animateChanges = animate && _hasSnapshot;
        _hasSnapshot = true;
        UpdateQuota(snapshot.Quota);
        _today.SetValue(snapshot.Today, animateChanges);
        _total.SetValue(snapshot.Total, animateChanges);
        // The source already sorts by Today. Keep deterministic ordering for fixtures and older sources too.
        _projects = (snapshot.Projects ?? []).OrderByDescending(project => project.Today)
            .ThenByDescending(project => project.Total)
            .ThenBy(project => project.Name, StringComparer.OrdinalIgnoreCase)
            .ThenBy(project => project.Path, StringComparer.Ordinal).ToList();
        UpdateProjects(animateChanges);
        SetConnected(true);
    }

    public void SetBackground(bool enabled)
    {
        Background = enabled ? new SolidColorBrush(Color.FromArgb(232, 7, 12, 18)) : Brushes.Transparent;
        BorderBrush = enabled ? BrushFor(34, 47, 59) : Brushes.Transparent;
    }

    public void SetConnected(bool connected)
    {
        _connected = connected;
        _connection.Text = connected ? "LIVE" : "SYNC";
        _connectionDot.Fill = connected ? Accent : Brushes.Orange;
        _connection.ToolTip = connected
            ? "Connected to the local counter. Usage is scanned about every 5 minutes."
            : "Waiting for the local counter. The last available totals remain visible.";
        _emptyState.Text = _connected ? "Waiting for project activity" : "Reading local activity…";
    }

    public void ReplayCounters()
    {
        _today.Replay();
        _total.Replay();
        foreach (var row in _projectList.Children.OfType<ProjectRow>()) row.Replay();
    }

    private void ToggleExpanded()
    {
        Expanded = !Expanded;
        Height = Expanded ? ExpandedHeight : CompactHeight;
        _projectArea.Height = Expanded ? ExpandedListHeight : CompactListHeight;
        _projectScroll.VerticalScrollBarVisibility = Expanded ? ScrollBarVisibility.Auto : ScrollBarVisibility.Hidden;
        _projectScroll.ScrollToTop();
        UpdateProjects(false);
        ExpandedChanged?.Invoke(Expanded);
    }

    private void UpdateProjects(bool animate)
    {
        _projectsLabel.Text = Expanded ? "PROJECTS / ALL" : "PROJECTS / TODAY";
        _projectsToggle.Text = Expanded ? $"COLLAPSE · {_projects.Count}  ⌃" : $"ALL {_projects.Count}  ⌄";
        _projectsButton.ToolTip = Expanded
            ? "Ranked by today's usage. Click to show only the top three."
            : "Show all projects, ranked by today's usage.";
        AutomationProperties.SetName(_projectsButton,
            Expanded ? "Collapse project list" : $"Show all {_projects.Count} projects");
        _emptyState.Visibility = _projects.Count == 0 ? Visibility.Visible : Visibility.Collapsed;

        var currentPaths = new HashSet<string>(_projects.Select(project => project.Path ?? ""), StringComparer.Ordinal);
        foreach (var obsolete in _rows.Keys.Where(path => !currentPaths.Contains(path)).ToList()) _rows.Remove(obsolete);
        _projectList.Children.Clear();
        var visible = Expanded ? _projects : _projects.Take(3);
        var rank = 0;
        foreach (var project in visible)
        {
            rank++;
            var path = project.Path ?? "";
            if (!_rows.TryGetValue(path, out var row))
            {
                row = new ProjectRow();
                _rows.Add(path, row);
            }
            row.Apply(rank, project, showToday: rank <= 3, showTotal: Expanded,
                warning: _overLimit, animate: animate);
            _projectList.Children.Add(row);
        }
    }

    private void UpdateQuota(QuotaUsage? quota)
    {
        // Account resets replace the current allowance. Historical carry and
        // its estimated flag must not affect the remaining quota display.
        double? used = quota is { Available: true } or { Stale: true }
            ? quota.CurrentPercent : null;
        if (used is double invalid && (!double.IsFinite(invalid) || invalid < 0)) used = null;
        double? remaining = used is double current ? Math.Clamp(100 - current, 0, 100) : null;
        _overLimit = used >= 100;
        var tint = used is double value ? QuotaBrush(value) : Secondary;
        _quotaValue.Text = remaining is double available
            ? available.ToString("F0", CultureInfo.InvariantCulture) + "%"
            : "—";
        _quotaValue.Foreground = tint;
        _quotaStale.Visibility = quota?.Stale == true ? Visibility.Visible : Visibility.Collapsed;
        _quotaFill.Background = tint;
        _quotaFraction = (remaining ?? 0) / 100;
        UpdateQuotaWidth();
        _today.DigitBrush = _overLimit ? Red : Accent;
        _total.DigitBrush = _overLimit ? Red : Silver;

        var detail = "Remaining weekly Codex account allowance, not a fixed number of tokens. "
            + "Follows the account's reported resets at the next refresh. Today and Total token counts are not cleared. ";
        if (remaining is double left && used is double currentUsage)
        {
            detail += $"Remaining: {left.ToString("F0", CultureInfo.InvariantCulture)}%. "
                + $"Used in the current window: {currentUsage.ToString("F0", CultureInfo.InvariantCulture)}%.";
            if (quota?.ResetsAt is double reset && double.IsFinite(reset) && reset is >= -62135596800 and <= 253402300799)
                detail += " Window ends: " + DateTimeOffset.FromUnixTimeSeconds((long)reset).ToLocalTime()
                    .ToString("MMM d, yyyy HH:mm", CultureInfo.InvariantCulture) + ".";
        }
        else detail += "Waiting for a valid weekly reading. Sign in to Codex to view your account quota.";
        if (quota?.Stale == true) detail += remaining.HasValue
            ? " Showing the last available reading while waiting for an update."
            : " The last reading is unavailable or invalid; waiting for an update.";
        _quotaSection.ToolTip = detail;
        AutomationProperties.SetName(_quotaSection, "Weekly remaining " + _quotaValue.Text
            + (quota?.Stale == true ? ", stale" : ""));
    }

    private void UpdateQuotaWidth() => _quotaFill.Width = Math.Max(0, _quotaTrack.ActualWidth * _quotaFraction);
    private void SetProjectHeaderBrush(Brush brush) { _projectsLabel.Foreground = brush; _projectsToggle.Foreground = brush; }

    private static Grid CounterLine(string label, RollingNumber number, Brush labelBrush)
    {
        var row = new Grid();
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(44) });
        row.ColumnDefinitions.Add(new ColumnDefinition());
        row.Children.Add(Label(label, 8, labelBrush));
        Grid.SetColumn(number, 1);
        row.Children.Add(number);
        return row;
    }

    private static TextBlock Label(string text, double size, Brush color) => new()
    {
        Text = text, FontFamily = InterfaceFont, FontSize = size, FontWeight = FontWeights.SemiBold,
        Foreground = color, VerticalAlignment = VerticalAlignment.Center, TextWrapping = TextWrapping.NoWrap
    };

    internal static Style CreateScrollBarStyle() => (Style)XamlReader.Parse("""
        <Style xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
               xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
               TargetType="{x:Type ScrollBar}">
          <Setter Property="Width" Value="6"/>
          <Setter Property="MinWidth" Value="6"/>
          <Setter Property="Focusable" Value="False"/>
          <Setter Property="Template">
            <Setter.Value>
              <ControlTemplate TargetType="{x:Type ScrollBar}">
                <Border Background="#14222E" CornerRadius="3">
                  <Track x:Name="PART_Track" Orientation="Vertical" IsDirectionReversed="True"
                         Minimum="{TemplateBinding Minimum}" Maximum="{TemplateBinding Maximum}"
                         Value="{TemplateBinding Value}" ViewportSize="{TemplateBinding ViewportSize}">
                    <Track.DecreaseRepeatButton>
                      <RepeatButton Command="{x:Static ScrollBar.PageUpCommand}" Opacity="0"
                                    Focusable="False" IsTabStop="False"/>
                    </Track.DecreaseRepeatButton>
                    <Track.Thumb>
                      <Thumb Focusable="False">
                        <Thumb.Template>
                          <ControlTemplate TargetType="{x:Type Thumb}">
                            <Border Background="#526679" CornerRadius="3"/>
                          </ControlTemplate>
                        </Thumb.Template>
                      </Thumb>
                    </Track.Thumb>
                    <Track.IncreaseRepeatButton>
                      <RepeatButton Command="{x:Static ScrollBar.PageDownCommand}" Opacity="0"
                                    Focusable="False" IsTabStop="False"/>
                    </Track.IncreaseRepeatButton>
                  </Track>
                </Border>
              </ControlTemplate>
            </Setter.Value>
          </Setter>
        </Style>
        """);

    private static Brush BrushFor(byte red, byte green, byte blue)
    {
        var brush = new SolidColorBrush(Color.FromRgb(red, green, blue));
        brush.Freeze();
        return brush;
    }

    private static Brush QuotaBrush(double percentage)
    {
        var value = Math.Clamp(percentage, 0, 100);
        var from = value <= 60 ? Color.FromRgb(77, 199, 133) : Color.FromRgb(245, 199, 77);
        var to = value <= 60 ? Color.FromRgb(245, 199, 77) : Color.FromRgb(250, 89, 87);
        var fraction = value <= 60 ? value / 60 : (value - 60) / 40;
        return BrushFor((byte)(from.R + (to.R - from.R) * fraction),
            (byte)(from.G + (to.G - from.G) * fraction), (byte)(from.B + (to.B - from.B) * fraction));
    }

    private sealed class ProjectRow : Grid
    {
        private readonly TextBlock _rank = Label("", 9, Muted);
        private readonly TextBlock _name;
        private readonly StackPanel _metrics = new();
        private readonly Grid _todayLine;
        private readonly Grid _totalLine;
        private readonly RollingNumber _todayNumber = new() { DigitSize = 11, Height = 15, DigitBrush = Accent };
        private readonly RollingNumber _totalNumber = new() { DigitSize = 11, Height = 15, DigitBrush = Silver };

        public ProjectRow()
        {
            Margin = new Thickness(0, 0, 4, 6);
            ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(18) });
            ColumnDefinitions.Add(new ColumnDefinition());
            ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(140) });
            Children.Add(_rank);
            _name = new TextBlock
            {
                FontFamily = new FontFamily("Segoe UI, Microsoft YaHei UI"), FontSize = 9,
                Foreground = Silver, FontWeight = FontWeights.Medium,
                TextTrimming = TextTrimming.CharacterEllipsis, TextWrapping = TextWrapping.NoWrap,
                VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 6, 0)
            };
            Grid.SetColumn(_name, 1);
            Children.Add(_name);
            _todayLine = Metric("TODAY", _todayNumber, Accent);
            _totalLine = Metric("TOTAL", _totalNumber, Secondary);
            _metrics.Children.Add(_todayLine);
            _metrics.Children.Add(_totalLine);
            _metrics.VerticalAlignment = VerticalAlignment.Center;
            Grid.SetColumn(_metrics, 2);
            Children.Add(_metrics);
        }

        public void Apply(int rank, ProjectUsage project, bool showToday, bool showTotal, bool warning, bool animate)
        {
            _rank.Text = rank.ToString("D2", CultureInfo.InvariantCulture);
            // Project names are source data, never translated or inferred from a window title.
            _name.Text = string.IsNullOrEmpty(project.Path) ? "Unassigned" : project.Name;
            _name.ToolTip = string.IsNullOrEmpty(project.Path)
                ? "Project directory not identified." : project.Name + "\n" + project.Path;
            _todayLine.Visibility = showToday ? Visibility.Visible : Visibility.Collapsed;
            _totalLine.Visibility = showTotal ? Visibility.Visible : Visibility.Collapsed;
            Height = showToday && showTotal ? 34 : 22;
            _todayNumber.DigitBrush = warning ? Red : Accent;
            _totalNumber.DigitBrush = warning ? Red : Silver;
            _todayNumber.SetValue(project.Today, animate && showToday);
            _totalNumber.SetValue(project.Total, animate && showTotal);
            AutomationProperties.SetName(this, $"Today rank {rank}, {_name.Text}"
                + (showToday ? $", today {project.Today.ToString(CultureInfo.InvariantCulture)} tokens" : "")
                + (showTotal ? $", total {project.Total.ToString(CultureInfo.InvariantCulture)} tokens" : ""));
        }

        public void Replay()
        {
            if (_todayLine.Visibility == Visibility.Visible) _todayNumber.Replay();
            if (_totalLine.Visibility == Visibility.Visible) _totalNumber.Replay();
        }

        private static Grid Metric(string title, RollingNumber number, Brush labelBrush)
        {
            var row = new Grid { Height = 16 };
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(30) });
            row.ColumnDefinitions.Add(new ColumnDefinition());
            row.Children.Add(Label(title, 7, labelBrush));
            Grid.SetColumn(number, 1);
            row.Children.Add(number);
            return row;
        }
    }
}
