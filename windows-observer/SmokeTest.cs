using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;

namespace TokenObserver;

/// <summary>Offline release smoke: synthetic counters only, never reads the user's Codex home.</summary>
public static class SmokeTest
{
    public static int Run(Application application, string output)
    {
        Directory.CreateDirectory(output);
        application.ShutdownMode = ShutdownMode.OnExplicitShutdown;
        application.Startup += async (_, _) =>
        {
            try
            {
                await Verify(output);
                File.WriteAllText(Path.Combine(output, "result.txt"), "PASS: WPF layout, weekly remaining and reset boundaries, project display, synthetic network leaderboard states/pagination/own rank, explicit immutable nickname consent, page geometry and counter preservation, exact counters, animation settling, native foreground policy, bundled Python collection and restart. No live registrations or uploads.\n");
                application.Shutdown(0);
            }
            catch (Exception error)
            {
                File.WriteAllText(Path.Combine(output, "failure.txt"), error.ToString());
                application.Shutdown(1);
            }
        };
        return application.Run();
    }

    private static async Task Verify(string output)
    {
        Require(ForegroundWatcher.IsTarget("Codex") && ForegroundWatcher.IsTarget("ChatGPT"), "Native app allowlist");
        Require(!ForegroundWatcher.IsTarget("chrome") && !ForegroundWatcher.IsTarget("CodexTokenObserver"), "Browser/self exclusion");
        var view = new ObserverView();
        var fixture = new UsageSnapshot
        {
            Today = 8_403_527, Total = 6_172_098_410,
            Quota = new QuotaUsage { Available = true, CurrentPercent = 46, CumulativePercent = 46 },
            Projects = Enumerable.Range(1, 12).Select(i => new ProjectUsage
            {
                Name = i == 2 ? "中文项目示例" : "Project " + i,
                Path = "C:/fixture/project-" + i, Today = 1_000_000 / i, Total = 100_000_000 / i
            }).ToList()
        };
        view.Apply(fixture, false);
        Render(view, output, "compact");
        Require(Elements<TextBlock>(view).Any(text => text.Text == "ZUNO"), "Zuno panel branding");
        Require(!view.Expanded && Elements<RollingNumber>(view).Count() == 5, "Compact top-three Today fields");
        Require(Elements<TextBlock>(view).Any(text => text.Text == "中文项目示例"), "Project name preserved");
        var button = Elements<Button>(view).Single();
        button.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
        Render(view, output, "expanded");
        Require(view.Expanded, "Expand works");
        Require(Elements<RollingNumber>(view).Count(number => number.IsVisible || number.Visibility == Visibility.Visible) == 17, "Expanded projects include totals without extra Today fields");
        var projectScroll = Elements<ScrollViewer>(view).Single();
        var viewport = Elements<ScrollContentPresenter>(projectScroll).Single();
        var viewportRight = viewport.TransformToAncestor(view).TransformBounds(new Rect(viewport.RenderSize)).Right;
        Require(Elements<RollingNumber>((DependencyObject)projectScroll.Content).All(number =>
            number.TransformToAncestor(view).TransformBounds(new Rect(number.RenderSize)).Right <= viewportRight - 1),
            "Every project counter ends inside the viewport with space before its scrollbar");
        button.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
        Require(!view.Expanded, "Collapse works");
        VerifyWeeklyQuota(view, fixture, output);
        view.SetBackground(false); Render(view, output, "transparent"); view.SetBackground(true);
        view.Apply(new UsageSnapshot(), false); Render(view, output, "empty");
        view.Apply(fixture, false);
        var number = new RollingNumber { Width = 220, Height = 26 };
        number.SetValue(9_007_199_254_740_993L, false);
        Require(number.Value == 9_007_199_254_740_993L, "Integer values above double precision stay exact");
        number.SetValue(99, false); number.SetValue(100, true);
        await Task.Delay(4800);
        Require(number.Value == 100 && !number.HasAnimatedProperties, "Animation settles with no remaining clock");
        number.SetValue(0, true); Require(number.Value == 0, "Daily decrease snaps to zero");
        var host = new ObserverWindow(smokeMode: true);
        try
        {
            Require(host.Title == "Zuno" && host.Icon != null, "Zuno window title and embedded app icon");
            Require(!host.ShowingLeaderboardForTests, "New windows open on Counter");
            host.Show();
            await host.Dispatcher.InvokeAsync(() => { }, DispatcherPriority.ContextIdle);
            host.ViewForTests.Apply(fixture, false);
            await host.Dispatcher.InvokeAsync(() => { }, DispatcherPriority.ContextIdle);
            await VerifyProfile(host, output);
            var liveButton = Elements<Button>(host.ViewForTests).Single();
            Require(ObserverWindow.IsInteractiveGestureSource(liveButton), "Project button opts out of page gestures");
            Require(!ObserverWindow.IsInteractiveGestureSource(host.ViewForTests), "Noninteractive panel background allows gestures");
            Require(!ObserverWindow.ExceedsDragThreshold(new Point(0, 0), new Point(0, 0))
                && ObserverWindow.ExceedsDragThreshold(new Point(0, 0), new Point(100, 100)),
                "A moving pointer crosses the drag threshold, not a page switch");
            await VerifyPageSwitch(host, fixture, output, "compact");
            Require(HitBelongsToButton(liveButton, new Point(liveButton.ActualWidth / 2, 2))
                && HitBelongsToButton(liveButton, new Point(liveButton.ActualWidth / 2, liveButton.ActualHeight - 2)),
                "Project header blank area belongs to its button, not window dragging");
            liveButton.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
            await host.Dispatcher.InvokeAsync(() => { }, DispatcherPriority.ContextIdle);
            var liveScroll = Elements<ScrollViewer>(host.ViewForTests).Single();
            Require(ObserverWindow.IsInteractiveGestureSource(liveScroll), "Project scrolling opts out of page gestures");
            liveScroll.ScrollToEnd();
            await host.Dispatcher.InvokeAsync(() => { }, DispatcherPriority.ContextIdle);
            Require(liveScroll.VerticalOffset > 0 && Math.Abs(liveScroll.VerticalOffset - liveScroll.ScrollableHeight) <= 1,
                "Expanded project list scrolls to its final item");
            liveScroll.ScrollToTop();
            await host.Dispatcher.InvokeAsync(() => { }, DispatcherPriority.ContextIdle);
            await VerifyPageSwitch(host, fixture, output, "expanded");
            Require(host.Top + host.ActualHeight <= host.WorkingAreaForTests.Bottom + 1, "Expanded native window remains on screen");
            host.SetForegroundForTests(true); Require(host.Topmost, "Target app floats observer");
            host.SetForegroundForTests(false); Require(!host.Topmost, "Other apps lower observer");
            host.Hide(); host.SetForegroundForTests(true); Require(!host.IsVisible, "Manual hide survives foreground changes");
            host.ShowObserver(); Require(host.IsVisible, "Observer can be restored");
        }
        finally { host.QuitForTests(); }
        await VerifyCollector(output);
    }

    private static void VerifyWeeklyQuota(ObserverView view, UsageSnapshot fixture, string output)
    {
        var originalQuota = fixture.Quota;
        var red = Color.FromRgb(250, 89, 87);
        void Check(QuotaUsage? quota, string name, string expected, double fraction, bool warning,
            bool stale = false, Color? quotaColor = null)
        {
            fixture.Quota = quota;
            view.Apply(fixture, false);
            Render(view, output, "quota-" + name);
            var section = Elements<StackPanel>(view).Single(panel =>
                AutomationProperties.GetName(panel).StartsWith("Weekly remaining ", StringComparison.Ordinal));
            var labels = Elements<TextBlock>(section).ToArray();
            Require(labels.Any(label => label.Text == "WEEKLY REMAINING"), name + ": remaining label");
            Require(labels.Any(label => label.Text == expected), name + ": correct remaining percentage");
            Require(!labels.Any(label => label.Text.Contains("≈")), name + ": historical estimates are not displayed");
            Require(labels.Any(label => label.Text == "STALE") == stale, name + ": stale marker preserved");
            Require(AutomationProperties.GetName(section).EndsWith(", stale", StringComparison.Ordinal) == stale,
                name + ": stale status is accessible");
            var track = section.Children.OfType<Border>().Single();
            var fill = (Border)track.Child;
            Require(Math.Abs(fill.Width - track.ActualWidth * fraction) < 0.001,
                name + ": fill represents remaining, not used quota");
            if (quotaColor is Color expectedColor)
                Require(((SolidColorBrush)fill.Background).Color == expectedColor,
                    name + ": color follows current used quota only");
            Require(Elements<RollingNumber>(view).All(number =>
                (((SolidColorBrush)number.DigitBrush).Color == red) == warning),
                name + ": only an exhausted current window warns on counters");
            Require(Elements<RollingNumber>(view).Take(2).Select(number => number.Value)
                .SequenceEqual(new[] { fixture.Today, fixture.Total }), name + ": quota never clears token totals");
            var detail = section.ToolTip?.ToString() ?? "";
            Require(detail.Contains("not a fixed number of tokens") && detail.Contains("reported resets")
                && detail.Contains("Today and Total token counts are not cleared") && !detail.Contains("Cumulative"),
                name + ": tooltip explains quota and token history separately");
        }

        Check(new QuotaUsage { Available = true, CurrentPercent = 27, CumulativePercent = 127, Estimated = true },
            "historical-carry", "73%", 0.73, false, quotaColor: Color.FromRgb(152, 199, 107));
        Check(new QuotaUsage { Available = true, CurrentPercent = 100, CumulativePercent = 200 },
            "exhausted", "0%", 0, true, quotaColor: red);
        Check(new QuotaUsage { Available = true, CurrentPercent = 0, CumulativePercent = 200, Estimated = true },
            "reset", "100%", 1, false, quotaColor: Color.FromRgb(77, 199, 133));
        Check(new QuotaUsage { Available = true, CurrentPercent = 150, CumulativePercent = 250 },
            "clamped-exhausted", "0%", 0, true, quotaColor: red);
        Check(new QuotaUsage { Stale = true, CurrentPercent = 27, CumulativePercent = 127, Estimated = true },
            "stale", "73%", 0.73, false, stale: true, quotaColor: Color.FromRgb(152, 199, 107));
        Check(new QuotaUsage { Available = true, CumulativePercent = 127 }, "missing-current", "—", 0, false);
        Check(new QuotaUsage { Stale = true, CumulativePercent = 127 }, "stale-missing-current", "—", 0, false, stale: true);
        Check(new QuotaUsage { CurrentPercent = 27, CumulativePercent = 127 }, "unavailable", "—", 0, false);
        Check(null, "missing", "—", 0, false);
        foreach (var invalid in new[] { -1d, double.NaN, double.PositiveInfinity, double.NegativeInfinity })
            Check(new QuotaUsage { Available = true, CurrentPercent = invalid, CumulativePercent = 127 },
                "invalid-" + invalid.ToString(System.Globalization.CultureInfo.InvariantCulture), "—", 0, false);
        Check(new QuotaUsage { Stale = true, CurrentPercent = double.NaN, CumulativePercent = 127 },
            "stale-invalid", "—", 0, false, stale: true);
        fixture.Quota = originalQuota;
        view.Apply(fixture, false);
    }

    private static async Task VerifyPageSwitch(ObserverWindow host, UsageSnapshot fixture, string output, string name)
    {
        var frame = new Rect(host.Left, host.Top, host.ActualWidth, host.ActualHeight);
        var counter = host.ViewForTests;
        var collector = host.CollectorForTests;
        var expanded = counter.Expanded;
        var initialValues = Elements<RollingNumber>(counter).Select(number => number.Value).ToArray();
        host.TogglePageForTests();
        await host.Dispatcher.InvokeAsync(() => { }, DispatcherPriority.ContextIdle);
        Require(host.ShowingLeaderboardForTests && counter.Visibility == Visibility.Hidden,
            "Leaderboard overlays the retained counter");
        Require(ReferenceEquals(counter.Parent, host.LeaderboardForTests.Parent), "Both pages remain mounted in one container");
        Require(new Rect(host.Left, host.Top, host.ActualWidth, host.ActualHeight) == frame,
            "Switching to leaderboard preserves the exact window frame");
        Require(ReferenceEquals(collector, host.CollectorForTests), "Switching pages retains the collector instance");
        Require(Elements<RollingNumber>(counter).Select(number => number.Value).SequenceEqual(initialValues),
            "Sample leaderboard never overwrites the real counters");
        var boardFixture = BoardFixture();
        host.ApplySnapshotForTests(new UsageSnapshot
        {
            Today = fixture.Today, Total = fixture.Total, Quota = fixture.Quota, Projects = fixture.Projects,
            Profile = new ZunoProfile { Status = "active", Nickname = "Fixture Me", Id = "fixture-me" },
            Leaderboard = boardFixture
        });
        await host.Dispatcher.InvokeAsync(() => { }, DispatcherPriority.ContextIdle);
        var labels = Elements<TextBlock>(host.LeaderboardForTests).Select(label => label.Text).ToArray();
        Require(labels.Any(label => label.Contains("Self-reported") && label.Contains("Not verified by OpenAI")),
            "Unverified client-reported ranking is clearly described");
        Require(labels.Any(label => label.Contains("2026-09-07") && label.Contains("Asia/Shanghai")),
            "Server-provided ranking date and fixed time zone are visible");
        Require(labels.Any(label => label.Contains("You · #58") && label.Contains("Fixture Me")), "Own rank outside this page remains visible");
        var requestedOffset = -1;
        void ObservePage(int offset) => requestedOffset = offset;
        host.LeaderboardForTests.PageRequested += ObservePage;
        Elements<Button>(host.LeaderboardForTests).Single(button => AutomationProperties.GetName(button) == "Next leaderboard page")
            .RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
        host.LeaderboardForTests.PageRequested -= ObservePage;
        Require(requestedOffset == 50, "Next page asks for the next offset, not a local fake slice");
        var scroll = Elements<ScrollViewer>(host.LeaderboardForTests).Single();
        Require(ObserverWindow.IsInteractiveGestureSource(scroll), "Leaderboard scrolling opts out of page gestures");
        scroll.ScrollToEnd();
        await host.Dispatcher.InvokeAsync(() => { }, DispatcherPriority.ContextIdle);
        Require(scroll.ScrollableHeight <= 0 || Math.Abs(scroll.VerticalOffset - scroll.ScrollableHeight) <= 1,
            "Leaderboard scroll reaches the last server fixture row without resizing the window");
        RenderElement(host.LeaderboardForTests, output, "leaderboard-" + name);

        // Exercise the exact snapshot path used by the collector while hidden.
        // Network views remain independent and returning reveals newer values.
        var next = new UsageSnapshot { Today = fixture.Today + 315, Total = fixture.Total + 315, Projects = fixture.Projects, Quota = fixture.Quota };
        counter.Apply(next, false);
        Require(Elements<RollingNumber>(counter).Take(2).Select(number => number.Value)
            .SequenceEqual(new[] { next.Today, next.Total }), "The hidden counter continues to accept snapshots");
        await VerifyLeaderboardStates(host.LeaderboardForTests, output, name);
        Elements<Button>(host.LeaderboardForTests).Single(button => AutomationProperties.GetName(button) == "Back to Counter")
            .RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
        await host.Dispatcher.InvokeAsync(() => { }, DispatcherPriority.ContextIdle);
        Require(!host.ShowingLeaderboardForTests && counter.Visibility == Visibility.Visible && counter.Expanded == expanded,
            "Back restores Counter and its project expansion state");
        Require(new Rect(host.Left, host.Top, host.ActualWidth, host.ActualHeight) == frame,
            "Returning to Counter preserves the exact window frame");
        Require(Elements<RollingNumber>(counter).Take(2).Select(number => number.Value)
            .SequenceEqual(new[] { next.Today, next.Total }), "Returning retains the latest true snapshot values");
        counter.Apply(fixture, false);
    }

    private static LeaderboardSnapshot BoardFixture() => new()
    {
        Status = "ok", Date = "2026-09-07", TimeZone = "Asia/Shanghai", TotalParticipants = 61,
        UpdatedAt = "2026-09-08T02:00:00Z",
        Entries = Enumerable.Range(1, 50).Select(rank => new LeaderboardEntry
        {
            Id = "fixture-" + rank, Rank = rank, Nickname = rank == 2 ? "测试昵称" : "Fixture " + rank,
            TotalTokens = 30_000_000 / rank
        }).ToList(),
        OwnEntry = new LeaderboardEntry { Id = "fixture-me", Rank = 58, Nickname = "Fixture Me", TotalTokens = 5_270 }
    };

    private static async Task VerifyLeaderboardStates(LeaderboardView view, string output, string name)
    {
        bool Has(string text) => Elements<TextBlock>(view).Any(label => label.Text.Contains(text));
        var fixture = BoardFixture();
        fixture.Status = "offline"; fixture.Stale = true;
        view.Apply(fixture, 0, null);
        await view.Dispatcher.InvokeAsync(() => { }, DispatcherPriority.ContextIdle);
        Require(Has("Offline") && Has("Fixture 1"), "Offline state preserves last successful participants, never zeros them");
        RenderElement(view, output, "leaderboard-offline-" + name);
        view.Apply(new LeaderboardSnapshot { Status = "ok", Date = "2026-09-07" }, 0,
            new ZunoProfile { Status = "active", Nickname = "Fixture Me" });
        await view.Dispatcher.InvokeAsync(() => { }, DispatcherPriority.ContextIdle);
        Require(Has("No reported activity") && Has("Not ranked yesterday") && !Has("Fixture 1"), "Empty board and own not-ranked state contain no fictional people");
        RenderElement(view, output, "leaderboard-empty-" + name);
        view.Apply(new LeaderboardSnapshot { Status = "loading" }, 0, null);
        Require(Has("Loading"), "Loading is not presented as an empty result");
        view.Apply(new LeaderboardSnapshot { Status = "not_configured" }, 0, null);
        Require(Has("not configured"), "Missing service remains explicit");
        view.Apply(BoardFixture(), 0, new ZunoProfile { Status = "paused" });
        Require(Has("Sharing paused") && !Has("Offline"), "Paused sharing is distinct from a fresh public ranking");
        var uploadPending = BoardFixture();
        uploadPending.Error = "sync_failed"; uploadPending.OwnEntryStale = true;
        view.Apply(uploadPending, 0, new ZunoProfile { Status = "active", Nickname = "Fixture Me", Error = "sync_failed" });
        Require(Has("Upload pending") && Has("You · #58") && Has("61 participants") && !Has("Offline"),
            "Failed own upload keeps real own rank and a fresh global board without claiming upload success");
        uploadPending.OwnEntry = null;
        view.Apply(uploadPending, 0, new ZunoProfile { Status = "active", Nickname = "Fixture Me", Error = "sync_failed" });
        Require(Has("You · Upload pending") && !Has("Not ranked yesterday"), "Unreported own activity is pending, not a confirmed zero/not-ranked result");
        await view.Dispatcher.InvokeAsync(() => { }, DispatcherPriority.ContextIdle);
        RenderElement(view, output, "leaderboard-upload-pending-" + name);
    }

    private static async Task VerifyProfile(ObserverWindow host, string output)
    {
        var dialog = new ProfileWindow { Owner = host };
        var registrations = 0;
        string? requested = null;
        dialog.RegisterRequested += name => { registrations++; requested = name; };
        dialog.Show();
        try
        {
            await dialog.Dispatcher.InvokeAsync(() => { }, DispatcherPriority.ContextIdle);
            var field = Elements<TextBox>(dialog).Single();
            Require(dialog.NameEditableForTests && field.Text == "" && registrations == 0, "Opening onboarding never chooses a nickname or registers");
            Require(Elements<TextBlock>(dialog).Any(label => label.Text.Contains("permanent") && label.Text.Contains("public")), "Permanent nickname and public daily tokens are explained before consent");
            var join = Elements<Button>(dialog).Single(button => Equals(button.Content, "Create & Join"));
            field.Text = "Fixture User";
            join.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
            Require(registrations == 1 && requested == "Fixture User", "Only explicit Create & Join requests registration");
            dialog.Apply(new ZunoProfile { Status = "pending", Nickname = "Fixture User" }, true);
            Require(!dialog.NameEditableForTests && !field.IsEnabled, "Pending identity cannot be changed during registration");
            join.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
            Require(registrations == 1, "Busy registration cannot submit twice");
            dialog.Apply(new ZunoProfile { Status = "pending", Nickname = "Fixture User", Error = "offline" });
            Require(!dialog.NameEditableForTests && Equals(join.Content, "Retry Create & Join"), "Uncertain registration preserves and retries the same name");
            dialog.Apply(new ZunoProfile { Status = "needs_name", Error = "nickname_taken" });
            Require(dialog.NameEditableForTests && Elements<TextBlock>(dialog).Any(label => label.Text.Contains("already taken")), "Only a confirmed name rejection unlocks pre-join input");
            dialog.Apply(new ZunoProfile { Status = "active", Nickname = "Fixture User" });
            Require(!dialog.NameEditableForTests && Elements<Button>(dialog).Any(button => Equals(button.Content, "Pause sync")), "Registered name is immutable with pause control");
            dialog.Apply(new ZunoProfile { Status = "active", Nickname = "Fixture User", Error = "sync_failed" });
            Require(!dialog.NameEditableForTests && field.Text == "Fixture User"
                && Elements<TextBlock>(dialog).Any(label => label.Text.Contains("Upload pending"))
                && Elements<Button>(dialog).Any(button => Equals(button.Content, "Pause sync")),
                "An active profile with an upload error retains its identity and pause control");
            join.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
            Require(registrations == 1, "Registered profiles never submit a rename");
            dialog.Apply(new ZunoProfile { Status = "paused", Nickname = "Fixture User" });
            Require(!dialog.NameEditableForTests && Elements<Button>(dialog).Any(button => Equals(button.Content, "Resume sync")), "Paused profile keeps the same immutable name");
            RenderElement(dialog, output, "profile-registered");
        }
        finally { dialog.Close(); }
        Require(registrations == 1, "Closing the profile does not create another identity");
        var staleOwnFixture = BoardFixture();
        staleOwnFixture.Error = "sync_failed"; staleOwnFixture.OwnEntryStale = true;
        var json = JsonSerializer.Serialize(new UsageSnapshot { Today = 15, Total = 30,
            Profile = new ZunoProfile { Status = "active", Nickname = "Fixture Me", Error = "sync_failed" }, Leaderboard = staleOwnFixture });
        var decoded = JsonSerializer.Deserialize<UsageSnapshot>(json)!;
        Require(decoded.Profile?.Nickname == "Fixture Me" && decoded.Leaderboard?.OwnEntry?.Rank == 58 && decoded.Today == 15
            && decoded.Leaderboard.OwnEntryStale && decoded.Leaderboard.Error == "sync_failed" && !decoded.Leaderboard.Stale,
            "Python-compatible stream decodes own upload staleness separately from global freshness and local counters");
    }

    private static void RenderElement(FrameworkElement element, string output, string name)
    {
        var bitmap = new RenderTargetBitmap((int)Math.Ceiling(element.ActualWidth * 3),
            (int)Math.Ceiling(element.ActualHeight * 3), 288, 288, PixelFormats.Pbgra32);
        bitmap.Render(element);
        var png = new PngBitmapEncoder(); png.Frames.Add(BitmapFrame.Create(bitmap));
        using var file = File.Create(Path.Combine(output, name + ".png")); png.Save(file);
    }

    private static async Task VerifyCollector(string output)
    {
        var isolated = Path.Combine(output, "collector-fixture");
        var sessions = Path.Combine(isolated, "sessions");
        Directory.CreateDirectory(sessions);
        var database = Path.Combine(isolated, "counter.sqlite3");
        using (var init = Process.Start(CollectorProcess.Command(database, sessions, "init"))!)
        {
            var text = init.StandardOutput.ReadToEndAsync();
            var errors = init.StandardError.ReadToEndAsync();
            using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(15));
            await init.WaitForExitAsync(deadline.Token);
            await text; await errors;
            Require(init.ExitCode == 0, "Bundled Python starts and initializes isolated database");
        }
        var timestamp = DateTimeOffset.UtcNow.AddSeconds(1).ToString("O");
        var meta = JsonSerializer.Serialize(new { type = "session_meta", payload = new { cwd = "C:/fixture/中文项目示例" } });
        var entry = JsonSerializer.Serialize(new
        {
            timestamp, type = "event_msg", payload = new
            {
                type = "token_count", info = new { last_token_usage = new { total_tokens = 315, input_tokens = 300, output_tokens = 15 } }
            }
        });
        File.WriteAllText(Path.Combine(sessions, "fixture.jsonl"), meta + "\n" + entry + "\n");
        async Task<UsageSnapshot> Sample()
        {
            using var collector = new CollectorProcess();
            var completion = new TaskCompletionSource<UsageSnapshot>(TaskCreationOptions.RunContinuationsAsynchronously);
            collector.Snapshot += snapshot => completion.TrySetResult(snapshot);
            collector.Unavailable += message => completion.TrySetException(new Exception(message));
            collector.Start(database, sessions, readQuota: false, readLeaderboard: false);
            return await completion.Task.WaitAsync(TimeSpan.FromSeconds(15));
        }
        var first = await Sample(); var second = await Sample();
        Require(first.Today == 315 && first.Total == 315 && first.Projects.Count == 1, "End-to-end bundled collector snapshot");
        Require(first.Projects[0].Name == "中文项目示例", "End-to-end collector preserves Unicode project names");
        Require(second.Total == 315, "Restart persists count without double counting");

        // The native window uses this isolated process while its counter page
        // is hidden. No local Codex account/session paths are involved.
        var host = new ObserverWindow(smokeMode: true);
        try
        {
            host.Show();
            await host.Dispatcher.InvokeAsync(() => { }, DispatcherPriority.ContextIdle);
            var completion = new TaskCompletionSource<UsageSnapshot>(TaskCreationOptions.RunContinuationsAsynchronously);
            host.CollectorForTests.Snapshot += snapshot => completion.TrySetResult(snapshot);
            host.CollectorForTests.Unavailable += message => completion.TrySetException(new Exception(message));
            host.CollectorForTests.Start(database, sessions, readQuota: false, readLeaderboard: false);
            host.TogglePageForTests();
            var backgroundSnapshot = await completion.Task.WaitAsync(TimeSpan.FromSeconds(15));
            await host.Dispatcher.InvokeAsync(() => { }, DispatcherPriority.ContextIdle);
            Require(host.ShowingLeaderboardForTests && backgroundSnapshot.Total == 315,
                "The existing collector still emits snapshots on the leaderboard page");
            Require(Elements<RollingNumber>(host.ViewForTests).Take(2).All(number => number.Value == 315),
                "Native collector snapshots update the hidden real counter");
            host.TogglePageForTests();
            await host.Dispatcher.InvokeAsync(() => { }, DispatcherPriority.ContextIdle);
            Require(!host.ShowingLeaderboardForTests && Elements<RollingNumber>(host.ViewForTests).Take(2).All(number => number.Value == 315),
                "Returning from leaderboard shows the collector's unchanged persisted total");
        }
        finally { host.QuitForTests(); }
        // The test database remains in the CI smoke artifact, never in the release ZIP.
    }

    private static bool HitBelongsToButton(Button button, Point point)
    {
        var hit = button.InputHitTest(point) as DependencyObject;
        while (hit != null)
        {
            if (ReferenceEquals(hit, button)) return true;
            hit = hit is Visual || hit is System.Windows.Media.Media3D.Visual3D
                ? VisualTreeHelper.GetParent(hit) : LogicalTreeHelper.GetParent(hit);
        }
        return false;
    }

    private static IEnumerable<T> Elements<T>(DependencyObject parent) where T : DependencyObject
    {
        for (var i = 0; i < VisualTreeHelper.GetChildrenCount(parent); i++)
        {
            var child = VisualTreeHelper.GetChild(parent, i);
            if (child is UIElement element && element.Visibility != Visibility.Visible) continue;
            if (child is T match) yield return match;
            foreach (var nested in Elements<T>(child)) yield return nested;
        }
    }
    private static void Render(ObserverView view, string output, string name)
    {
        view.Measure(new Size(view.Width, view.Height));
        view.Arrange(new Rect(0, 0, view.Width, view.Height));
        view.UpdateLayout();
        var bitmap = new RenderTargetBitmap((int)view.Width * 3, (int)view.Height * 3, 288, 288, PixelFormats.Pbgra32);
        bitmap.Render(view);
        var png = new PngBitmapEncoder(); png.Frames.Add(BitmapFrame.Create(bitmap));
        using var file = File.Create(Path.Combine(output, name + ".png")); png.Save(file);
    }
    private static void Require(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException(message);
    }
}
