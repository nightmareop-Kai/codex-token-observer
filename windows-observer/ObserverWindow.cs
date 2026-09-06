using System;
using System.ComponentModel;
using System.IO;
using System.Text.Json;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Threading;
using Forms = System.Windows.Forms;

namespace TokenObserver;

public sealed class ObserverWindow : Window
{
    private readonly ObserverView view = new();
    private readonly CollectorProcess collector = new();
    private readonly string support = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Codex Token Observer");
    private readonly Forms.NotifyIcon tray = new();
    private ForegroundWatcher? watcher;
    private Preferences preferences;
    private bool targetForeground;
    private bool exiting;
    private bool moving;
    private readonly bool smokeMode;
    internal ObserverView ViewForTests => view;
    internal Rect WorkingAreaForTests => WorkingArea();
    internal void SetForegroundForTests(bool value) { targetForeground = value; ApplyForeground(); }
    internal void QuitForTests() => Quit();

    public ObserverWindow(bool smokeMode = false)
    {
        this.smokeMode = smokeMode;
        preferences = smokeMode ? new Preferences() : LoadPreferences();
        Title = "Codex Token Observer";
        WindowStyle = WindowStyle.None; ResizeMode = ResizeMode.NoResize;
        AllowsTransparency = true; Background = Brushes.Transparent;
        ShowInTaskbar = false; ShowActivated = false;
        SizeToContent = SizeToContent.WidthAndHeight;
        Content = view;
        view.SetBackground(preferences.Background);
        view.ExpandedChanged += _ => Dispatcher.BeginInvoke(DispatcherPriority.Loaded, new Action(ClampToScreen));
        MouseLeftButtonDown += (_, e) =>
        {
            if (e.OriginalSource is DependencyObject source && IsButton(source)) return;
            if (e.ButtonState == MouseButtonState.Pressed)
            {
                try { DragMove(); SnapToEdge(); SavePreferences(); }
                catch (InvalidOperationException) { }
            }
        };
        ContextMenu = MakeContextMenu();
        tray.Icon = System.Drawing.SystemIcons.Application;
        tray.Text = "Codex Token Observer";
        tray.Visible = !smokeMode;
        tray.DoubleClick += (_, _) => Dispatcher.Invoke(ShowObserver);
        tray.ContextMenuStrip = MakeTrayMenu();
        collector.Snapshot += snapshot => Dispatcher.BeginInvoke(new Action(() => { view.SetConnected(true); view.Apply(snapshot); }));
        collector.Unavailable += message => Dispatcher.BeginInvoke(new Action(() => { view.SetConnected(false); view.ToolTip = message; }));
        Loaded += (_, _) =>
        {
            if (preferences.Left is double left && preferences.Top is double top && double.IsFinite(left) && double.IsFinite(top))
            { Left = left; Top = top; ClampToScreen(); }
            else MoveCorner(right: true);
            if (smokeMode) return;
            watcher = new ForegroundWatcher(target => Dispatcher.BeginInvoke(new Action(() => { targetForeground = target; ApplyForeground(); })));
            var codexHome = Environment.GetEnvironmentVariable("CODEX_HOME");
            if (string.IsNullOrWhiteSpace(codexHome)) codexHome = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".codex");
            collector.Start(Path.Combine(support, "token_counter.sqlite3"), Path.Combine(codexHome, "sessions"));
        };
        Closing += (_, e) => { if (!exiting) { e.Cancel = true; Hide(); } };
        Closed += (_, _) => { watcher?.Dispose(); collector.Dispose(); tray.Visible = false; tray.Dispose(); };
    }

    private static bool IsButton(DependencyObject source)
    {
        while (source != null)
        {
            if (source is System.Windows.Controls.Primitives.ButtonBase || source is System.Windows.Controls.Primitives.ScrollBar) return true;
            source = source is Visual || source is System.Windows.Media.Media3D.Visual3D
                ? VisualTreeHelper.GetParent(source) : LogicalTreeHelper.GetParent(source);
        }
        return false;
    }
    public void ShowObserver() { Show(); ApplyForeground(); }
    private void Quit() { SavePreferences(); exiting = true; Close(); }
    private void ToggleBackground() { preferences.Background = !preferences.Background; view.SetBackground(preferences.Background); SavePreferences(); }
    private void ToggleFollow() { preferences.Follow = !preferences.Follow; ApplyForeground(); SavePreferences(); }
    private void ApplyForeground()
    {
        Topmost = !preferences.Follow || targetForeground;
        if (!IsVisible) return;
        var handle = new WindowInteropHelper(this).Handle;
        ForegroundWatcher.SetWindowPos(handle, Topmost ? new IntPtr(-1) : new IntPtr(1), 0, 0, 0, 0, 0x0013);
    }
    private ContextMenu MakeContextMenu()
    {
        var menu = new ContextMenu();
        void Add(string title, Action action, Func<bool>? check = null)
        {
            var item = new MenuItem { Header = title, IsCheckable = check != null };
            item.Click += (_, _) => action();
            if (check != null) menu.Opened += (_, _) => item.IsChecked = check();
            menu.Items.Add(item);
        }
        Add("Hide Window", Hide);
        Add("Move to Bottom Left", () => MoveCorner(false));
        Add("Move to Bottom Right", () => MoveCorner(true));
        Add("Show Translucent Background", ToggleBackground, () => preferences.Background);
        Add("Follow Codex / ChatGPT", ToggleFollow, () => preferences.Follow);
        Add("Replay Counter Animation", view.ReplayCounters);
        menu.Items.Add(new Separator());
        Add("Quit Token Observer", Quit);
        return menu;
    }
    private Forms.ContextMenuStrip MakeTrayMenu()
    {
        var menu = new Forms.ContextMenuStrip();
        var visibility = new Forms.ToolStripMenuItem("Hide Window");
        visibility.Click += (_, _) => Dispatcher.Invoke(() => { if (IsVisible) Hide(); else ShowObserver(); });
        menu.Items.Add(visibility);
        menu.Opening += (_, _) => visibility.Text = IsVisible ? "Hide Window" : "Show Window";
        void Add(string text, Action action) => menu.Items.Add(text, null, (_, _) => Dispatcher.Invoke(action));
        Add("Move to Bottom Left", () => MoveCorner(false));
        Add("Move to Bottom Right", () => MoveCorner(true));
        Add("Show / Hide Background", ToggleBackground);
        Add("Follow Codex / ChatGPT", ToggleFollow);
        menu.Items.Add(new Forms.ToolStripSeparator());
        Add("Quit Token Observer", Quit);
        return menu;
    }
    private Rect WorkingArea()
    {
        var screen = Forms.Screen.FromHandle(new WindowInteropHelper(this).Handle);
        var transform = PresentationSource.FromVisual(this)?.CompositionTarget?.TransformFromDevice ?? Matrix.Identity;
        var rect = screen.WorkingArea;
        return new Rect(transform.Transform(new Point(rect.Left, rect.Top)), transform.Transform(new Point(rect.Right, rect.Bottom)));
    }
    private void MoveCorner(bool right)
    {
        var area = WorkingArea(); Left = right ? area.Right - ActualWidth - 3 : area.Left + 3;
        Top = area.Bottom - ActualHeight - 3; SavePreferences();
    }
    private void ClampToScreen()
    {
        if (moving) return;
        moving = true;
        var area = WorkingArea();
        Left = Math.Clamp(Left, area.Left + 3, Math.Max(area.Left + 3, area.Right - ActualWidth - 3));
        Top = Math.Clamp(Top, area.Top + 3, Math.Max(area.Top + 3, area.Bottom - ActualHeight - 3));
        moving = false;
    }
    private void SnapToEdge()
    {
        var area = WorkingArea(); const double range = 26;
        if (Math.Abs(Left - area.Left) < range) Left = area.Left + 3;
        if (Math.Abs(Left + ActualWidth - area.Right) < range) Left = area.Right - ActualWidth - 3;
        if (Math.Abs(Top - area.Top) < range) Top = area.Top + 3;
        if (Math.Abs(Top + ActualHeight - area.Bottom) < range) Top = area.Bottom - ActualHeight - 3;
        ClampToScreen();
    }
    private Preferences LoadPreferences()
    {
        try { return JsonSerializer.Deserialize<Preferences>(File.ReadAllText(Path.Combine(support, "settings.json"))) ?? new(); }
        catch (IOException) { return new(); } catch (JsonException) { return new(); } catch (UnauthorizedAccessException) { return new(); }
    }
    private void SavePreferences()
    {
        if (smokeMode) return;
        preferences.Left = Left; preferences.Top = Top;
        try
        {
            Directory.CreateDirectory(support);
            var path = Path.Combine(support, "settings.json");
            var temporary = path + ".tmp";
            File.WriteAllText(temporary, JsonSerializer.Serialize(preferences));
            File.Move(temporary, path, overwrite: true);
        }
        catch (IOException) { } catch (UnauthorizedAccessException) { }
    }
    public sealed class Preferences
    {
        public bool Follow { get; set; } = true;
        public bool Background { get; set; } = true;
        public double? Left { get; set; }
        public double? Top { get; set; }
    }
}
