using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
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
                File.WriteAllText(Path.Combine(output, "result.txt"), "PASS: WPF layout, project display, exact counters, animation settling, native foreground policy, bundled Python collection and restart.\n");
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
        fixture.Quota!.CurrentPercent = 27; fixture.Quota.CumulativePercent = 127; fixture.Quota.Estimated = true;
        view.Apply(fixture, false); Render(view, output, "over-limit");
        Require(Elements<TextBlock>(view).Any(text => text.Text.Contains("127%")), "Quota exceeds 100 percent");
        fixture.Quota = null; view.Apply(fixture, false); Render(view, output, "quota-unavailable");
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
            host.Show();
            await host.Dispatcher.InvokeAsync(() => { }, DispatcherPriority.ContextIdle);
            host.ViewForTests.Apply(fixture, false);
            await host.Dispatcher.InvokeAsync(() => { }, DispatcherPriority.ContextIdle);
            var liveButton = Elements<Button>(host.ViewForTests).Single();
            Require(HitBelongsToButton(liveButton, new Point(liveButton.ActualWidth / 2, 2))
                && HitBelongsToButton(liveButton, new Point(liveButton.ActualWidth / 2, liveButton.ActualHeight - 2)),
                "Project header blank area belongs to its button, not window dragging");
            liveButton.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
            await host.Dispatcher.InvokeAsync(() => { }, DispatcherPriority.ContextIdle);
            var liveScroll = Elements<ScrollViewer>(host.ViewForTests).Single();
            liveScroll.ScrollToEnd();
            await host.Dispatcher.InvokeAsync(() => { }, DispatcherPriority.ContextIdle);
            Require(liveScroll.VerticalOffset > 0 && Math.Abs(liveScroll.VerticalOffset - liveScroll.ScrollableHeight) <= 1,
                "Expanded project list scrolls to its final item");
            liveScroll.ScrollToTop();
            await host.Dispatcher.InvokeAsync(() => { }, DispatcherPriority.ContextIdle);
            Require(host.Top + host.ActualHeight <= host.WorkingAreaForTests.Bottom + 1, "Expanded native window remains on screen");
            host.SetForegroundForTests(true); Require(host.Topmost, "Target app floats observer");
            host.SetForegroundForTests(false); Require(!host.Topmost, "Other apps lower observer");
            host.Hide(); host.SetForegroundForTests(true); Require(!host.IsVisible, "Manual hide survives foreground changes");
            host.ShowObserver(); Require(host.IsVisible, "Observer can be restored");
        }
        finally { host.QuitForTests(); }
        await VerifyCollector(output);
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
            collector.Start(database, sessions, readQuota: false);
            return await completion.Task.WaitAsync(TimeSpan.FromSeconds(15));
        }
        var first = await Sample(); var second = await Sample();
        Require(first.Today == 315 && first.Total == 315 && first.Projects.Count == 1, "End-to-end bundled collector snapshot");
        Require(first.Projects[0].Name == "中文项目示例", "End-to-end collector preserves Unicode project names");
        Require(second.Total == 315, "Restart persists count without double counting");
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
