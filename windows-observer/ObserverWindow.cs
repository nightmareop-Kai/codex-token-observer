using System;
using System.ComponentModel;
using System.IO;
using System.Globalization;
using System.Threading;
using System.Threading.Tasks;
using System.Text.Json;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Data;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using Forms = System.Windows.Forms;

namespace TokenObserver;

public sealed class ObserverWindow : Window
{
    private readonly ObserverView view = new();
    private readonly LeaderboardView leaderboard = new();
    private readonly Grid pages = new();
    private readonly CollectorProcess collector = new();
    private readonly string support = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Codex Token Observer");
    private readonly Forms.NotifyIcon tray = new();
    private readonly System.Drawing.Icon trayIcon;
    private ForegroundWatcher? watcher;
    private Preferences preferences;
    private bool targetForeground;
    private bool exiting;
    private bool moving;
    private bool showingLeaderboard;
    private Point? pointerOrigin;
    private bool pendingPageToggle;
    private long? lastDragAt;
    private readonly bool smokeMode;
    private readonly CancellationTokenSource requestCancellation = new();
    private readonly string database;
    private readonly string sessions;
    private ZunoProfile profile = new();
    private LeaderboardSnapshot board = new();
    private ProfileWindow? profileWindow;
    private bool onboardingOffered;
    private bool profileBusy;
    private bool boardBusy;
    private int boardOffset;
    internal ObserverView ViewForTests => view;
    internal LeaderboardView LeaderboardForTests => leaderboard;
    internal bool ShowingLeaderboardForTests => showingLeaderboard;
    internal CollectorProcess CollectorForTests => collector;
    internal void TogglePageForTests() => TogglePage();
    internal Rect WorkingAreaForTests => WorkingArea();
    internal void SetForegroundForTests(bool value) { targetForeground = value; ApplyForeground(); }
    internal void QuitForTests() => Quit();
    internal void ApplySnapshotForTests(UsageSnapshot snapshot) => ApplySnapshot(snapshot);

    public ObserverWindow(bool smokeMode = false)
    {
        this.smokeMode = smokeMode;
        database = Path.Combine(support, "token_counter.sqlite3");
        var codexHome = Environment.GetEnvironmentVariable("CODEX_HOME");
        if (string.IsNullOrWhiteSpace(codexHome)) codexHome = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".codex");
        sessions = Path.Combine(codexHome, "sessions");
        preferences = smokeMode ? new Preferences() : LoadPreferences();
        Title = "Zuno";
        var iconUri = new Uri("pack://application:,,,/Resources/Zuno.ico", UriKind.Absolute);
        Icon = BitmapFrame.Create(iconUri);
        trayIcon = LoadTrayIcon(iconUri);
        WindowStyle = WindowStyle.None; ResizeMode = ResizeMode.NoResize;
        AllowsTransparency = true; Background = Brushes.Transparent;
        ShowInTaskbar = false; ShowActivated = false;
        SizeToContent = SizeToContent.WidthAndHeight;
        pages.Width = view.Width;
        pages.SetBinding(HeightProperty, new Binding(nameof(FrameworkElement.Height)) { Source = view });
        pages.Children.Add(view);
        leaderboard.Visibility = Visibility.Collapsed;
        pages.Children.Add(leaderboard);
        Content = pages;
        view.SetBackground(preferences.Background);
        leaderboard.SetBackground(preferences.Background);
        leaderboard.BackRequested += () => SetPage(false);
        leaderboard.PageRequested += offset => _ = LoadBoardAsync(offset);
        leaderboard.ProfileRequested += ShowProfile;
        view.ExpandedChanged += _ => Dispatcher.BeginInvoke(DispatcherPriority.Loaded, new Action(ClampToScreen));
        MouseLeftButtonDown += BeginPointerGesture;
        MouseMove += ContinuePointerGesture;
        MouseLeftButtonUp += EndPointerGesture;
        LostMouseCapture += (_, _) => { pointerOrigin = null; pendingPageToggle = false; };
        ContextMenu = MakeContextMenu();
        tray.Icon = trayIcon;
        tray.Text = "Zuno";
        tray.Visible = !smokeMode;
        tray.DoubleClick += (_, _) => Dispatcher.Invoke(ShowObserver);
        tray.ContextMenuStrip = MakeTrayMenu();
        collector.Snapshot += snapshot => Dispatcher.BeginInvoke(new Action(() => ApplySnapshot(snapshot)));
        collector.Unavailable += message => Dispatcher.BeginInvoke(new Action(() => { view.SetConnected(false); view.ToolTip = message; }));
        Loaded += (_, _) =>
        {
            if (preferences.Left is double left && preferences.Top is double top && double.IsFinite(left) && double.IsFinite(top))
            { Left = left; Top = top; ClampToScreen(); }
            else MoveCorner(right: true);
            if (smokeMode) return;
            watcher = new ForegroundWatcher(target => Dispatcher.BeginInvoke(new Action(() => { targetForeground = target; ApplyForeground(); })));
            collector.Start(database, sessions);
        };
        Closing += (_, e) => { if (!exiting) { e.Cancel = true; Hide(); } };
        Closed += (_, _) =>
        {
            requestCancellation.Cancel(); profileWindow?.Close();
            watcher?.Dispose(); collector.Dispose(); tray.Visible = false; tray.Dispose(); trayIcon.Dispose();
        };
    }

    private void ApplySnapshot(UsageSnapshot snapshot)
    {
        if (exiting) return;
        view.SetConnected(true);
        view.Apply(snapshot);
        if (snapshot.Profile != null && !profileBusy) ApplyProfile(snapshot.Profile);
        if (snapshot.Leaderboard != null && !boardBusy
            && (boardOffset == 0 || (snapshot.Leaderboard.Date != null && snapshot.Leaderboard.Date != board.Date)))
        {
            boardOffset = 0;
            board = snapshot.Leaderboard;
            leaderboard.Apply(board, boardOffset, profile);
        }
        if (!smokeMode && !onboardingOffered && profile.Status == "needs_name")
        {
            onboardingOffered = true;
            ShowProfile();
        }
    }

    private void ApplyProfile(ZunoProfile value)
    {
        profile = value;
        profileWindow?.Apply(profile, profileBusy);
        leaderboard.Apply(board, boardOffset, profile);
    }

    private void ShowProfile()
    {
        if (profileWindow != null) { profileWindow.Activate(); return; }
        profileWindow = new ProfileWindow { Owner = this, Icon = Icon };
        profileWindow.Apply(profile, profileBusy);
        profileWindow.RegisterRequested += name => _ = RunProfileCommandAsync("profile-register", name);
        profileWindow.SyncRequested += () => _ = ToggleSyncAsync();
        profileWindow.Closed += (_, _) => profileWindow = null;
        profileWindow.Show();
    }

    private Task ToggleSyncAsync() => profile.IsJoined
        ? RunProfileCommandAsync(profile.Status == "paused" ? "profile-resume" : "profile-pause")
        : Task.CompletedTask;

    private async Task RunProfileCommandAsync(string command, string? name = null)
    {
        if (smokeMode || profileBusy || exiting) return;
        profileBusy = true;
        if (command == "profile-register")
            profile = new ZunoProfile { Status = "pending", Id = profile.Id, Nickname = name };
        profileWindow?.Apply(profile, true);
        string? failure = null;
        try
        {
            var arguments = name == null ? new[] { command } : new[] { command, "--nickname", name };
            var response = await CollectorProcess.RequestAsync<ProfileResponse>(database, sessions, requestCancellation.Token, arguments);
            if (response.Profile == null) throw new IOException("Invalid profile response.");
            ApplyProfile(response.Profile);
        }
        catch (Exception exception) when (exception is IOException or JsonException or OperationCanceledException or System.ComponentModel.Win32Exception or UnauthorizedAccessException)
        {
            failure = "The request could not finish. Retry with the same name; local counting continues.";
            // Registration might have succeeded before a lost response. Recover
            // the persisted identity; never substitute a newly chosen nickname.
            if (!exiting)
            {
                try
                {
                    var saved = await CollectorProcess.RequestAsync<ProfileResponse>(database, sessions, requestCancellation.Token, "profile-status");
                    if (saved.Profile != null) ApplyProfile(saved.Profile);
                }
                catch (Exception recovery) when (recovery is IOException or JsonException or OperationCanceledException or System.ComponentModel.Win32Exception or UnauthorizedAccessException) { }
            }
        }
        finally
        {
            profileBusy = false;
            if (!exiting) profileWindow?.Apply(profile, false, failure);
        }
        if (!exiting && profile.IsJoined) await LoadBoardAsync(0);
    }

    private async Task LoadBoardAsync(int offset)
    {
        if (smokeMode || boardBusy || exiting) return;
        boardBusy = true;
        leaderboard.SetBusy(true);
        try
        {
            var result = await CollectorProcess.RequestAsync<LeaderboardSnapshot>(database, sessions, requestCancellation.Token,
                "leaderboard-read", "--offset", Math.Max(0, offset).ToString(CultureInfo.InvariantCulture),
                "--limit", LeaderboardView.PageSize.ToString(CultureInfo.InvariantCulture));
            if (result.Status == "offline")
            {
                // A failed page fetch does not mean the old page is empty, nor
                // may a cached first page be relabeled as a later page.
                board.Status = "offline";
                board.Stale = board.Entries.Count > 0;
            }
            else { board = result; boardOffset = Math.Max(0, offset); }
        }
        catch (Exception exception) when (exception is IOException or JsonException or OperationCanceledException or System.ComponentModel.Win32Exception or UnauthorizedAccessException)
        { board.Status = "offline"; board.Stale = board.Entries.Count > 0; }
        finally
        {
            boardBusy = false;
            if (!exiting) { leaderboard.Apply(board, boardOffset, profile); leaderboard.SetBusy(false); }
        }
    }

    private static System.Drawing.Icon LoadTrayIcon(Uri resourceUri)
    {
        using var stream = Application.GetResourceStream(resourceUri).Stream;
        using var sourceIcon = new System.Drawing.Icon(stream);
        // NotifyIcon owns neither its assigned icon nor its stream. Clone the
        // embedded resource so the tray keeps a valid icon after this stream closes.
        return (System.Drawing.Icon)sourceIcon.Clone();
    }

    internal static bool IsInteractiveGestureSource(DependencyObject source)
    {
        while (source != null)
        {
            if (source is System.Windows.Controls.Primitives.ButtonBase || source is ScrollViewer
                || source is System.Windows.Controls.Primitives.ScrollBar
                || source is System.Windows.Controls.Primitives.TextBoxBase) return true;
            source = source is Visual || source is System.Windows.Media.Media3D.Visual3D
                ? VisualTreeHelper.GetParent(source) : LogicalTreeHelper.GetParent(source);
        }
        return false;
    }

    private void BeginPointerGesture(object sender, MouseButtonEventArgs e)
    {
        if (e.OriginalSource is not DependencyObject source || IsInteractiveGestureSource(source)) return;
        if (e.ButtonState != MouseButtonState.Pressed) return;
        pointerOrigin = e.GetPosition(this);
        // Wait for mouse-up before switching so a second press followed by a
        // drag cannot accidentally navigate. Buttons and scroll areas opt out.
        pendingPageToggle = e.ClickCount == 2
            && (lastDragAt is null || Environment.TickCount64 - lastDragAt.Value > Forms.SystemInformation.DoubleClickTime);
        CaptureMouse();
        e.Handled = true;
    }

    internal static bool ExceedsDragThreshold(Point origin, Point current) =>
        Math.Abs(current.X - origin.X) >= SystemParameters.MinimumHorizontalDragDistance
        || Math.Abs(current.Y - origin.Y) >= SystemParameters.MinimumVerticalDragDistance;

    private void ContinuePointerGesture(object sender, MouseEventArgs e)
    {
        if (pointerOrigin is not Point origin || e.LeftButton != MouseButtonState.Pressed
            || !ExceedsDragThreshold(origin, e.GetPosition(this))) return;
        pointerOrigin = null;
        pendingPageToggle = false;
        ReleaseMouseCapture();
        try { DragMove(); SnapToEdge(); SavePreferences(); }
        catch (InvalidOperationException) { }
        finally { lastDragAt = Environment.TickCount64; }
        e.Handled = true;
    }

    private void EndPointerGesture(object sender, MouseButtonEventArgs e)
    {
        if (pointerOrigin is not Point origin) return;
        var switchPage = pendingPageToggle && !ExceedsDragThreshold(origin, e.GetPosition(this));
        pointerOrigin = null;
        pendingPageToggle = false;
        ReleaseMouseCapture();
        if (switchPage) TogglePage();
        e.Handled = true;
    }

    private void TogglePage() => SetPage(!showingLeaderboard);

    private void SetPage(bool showLeaderboard)
    {
        showingLeaderboard = showLeaderboard;
        if (showLeaderboard) _ = LoadBoardAsync(boardOffset);
        // Hidden, not removed/collapsed: retain counter layout, project state,
        // animation targets and collector subscriptions while the ranking is visible.
        view.Visibility = showLeaderboard ? Visibility.Hidden : Visibility.Visible;
        leaderboard.Visibility = showLeaderboard ? Visibility.Visible : Visibility.Collapsed;
    }

    public void ShowObserver() { Show(); ApplyForeground(); }
    private void Quit() { SavePreferences(); exiting = true; Close(); }
    private void ToggleBackground()
    {
        preferences.Background = !preferences.Background;
        view.SetBackground(preferences.Background);
        leaderboard.SetBackground(preferences.Background);
        SavePreferences();
    }
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
        var navigation = new MenuItem { Header = "Leaderboard" };
        navigation.Click += (_, _) => TogglePage();
        menu.Opened += (_, _) => navigation.Header = showingLeaderboard ? "Back to Counter" : "Leaderboard";
        menu.Items.Add(navigation);
        Add("Your Zuno profile", ShowProfile);
        var sync = new MenuItem();
        sync.Click += (_, _) => _ = ToggleSyncAsync();
        menu.Opened += (_, _) =>
        {
            sync.Header = profile.Status == "paused" ? "Resume leaderboard sync" : "Pause leaderboard sync";
            sync.IsEnabled = profile.IsJoined && !profileBusy;
        };
        menu.Items.Add(sync);
        Add("Move to Bottom Left", () => MoveCorner(false));
        Add("Move to Bottom Right", () => MoveCorner(true));
        Add("Show Translucent Background", ToggleBackground, () => preferences.Background);
        Add("Follow Codex / ChatGPT", ToggleFollow, () => preferences.Follow);
        Add("Replay Counter Animation", view.ReplayCounters);
        menu.Items.Add(new Separator());
        Add("Quit Zuno", Quit);
        return menu;
    }
    private Forms.ContextMenuStrip MakeTrayMenu()
    {
        var menu = new Forms.ContextMenuStrip();
        var visibility = new Forms.ToolStripMenuItem("Hide Window");
        visibility.Click += (_, _) => Dispatcher.Invoke(() => { if (IsVisible) Hide(); else ShowObserver(); });
        menu.Items.Add(visibility);
        menu.Opening += (_, _) => visibility.Text = IsVisible ? "Hide Window" : "Show Window";
        var navigation = new Forms.ToolStripMenuItem("Leaderboard");
        navigation.Click += (_, _) => Dispatcher.Invoke(TogglePage);
        menu.Opening += (_, _) => navigation.Text = showingLeaderboard ? "Back to Counter" : "Leaderboard";
        menu.Items.Add(navigation);
        void Add(string text, Action action) => menu.Items.Add(text, null, (_, _) => Dispatcher.Invoke(action));
        Add("Your Zuno profile", ShowProfile);
        var sync = new Forms.ToolStripMenuItem("Pause leaderboard sync");
        sync.Click += (_, _) => Dispatcher.Invoke(() => _ = ToggleSyncAsync());
        menu.Opening += (_, _) =>
        {
            sync.Text = profile.Status == "paused" ? "Resume leaderboard sync" : "Pause leaderboard sync";
            sync.Enabled = profile.IsJoined && !profileBusy;
        };
        menu.Items.Add(sync);
        Add("Move to Bottom Left", () => MoveCorner(false));
        Add("Move to Bottom Right", () => MoveCorner(true));
        Add("Show / Hide Background", ToggleBackground);
        Add("Follow Codex / ChatGPT", ToggleFollow);
        menu.Items.Add(new Forms.ToolStripSeparator());
        Add("Quit Zuno", Quit);
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
