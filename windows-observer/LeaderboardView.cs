using System;
using System.Globalization;
using System.Linq;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;

namespace TokenObserver;

/// <summary>Server-reported activity only. Synthetic entries belong exclusively in smoke fixtures.</summary>
public sealed class LeaderboardView : Border
{
    public const int PageSize = 50;
    private static readonly Brush Accent = new SolidColorBrush(Color.FromRgb(102, 219, 242));
    private static readonly Brush Silver = new SolidColorBrush(Color.FromRgb(199, 214, 230));
    private static readonly Brush Secondary = new SolidColorBrush(Color.FromRgb(153, 171, 186));
    private readonly TextBlock dateLabel = Label("", 9, Secondary);
    private readonly TextBlock statusLabel = Label("Loading yesterday's ranking…", 9, Secondary);
    private readonly TextBlock ownLabel = Label("", 9, Accent);
    private readonly TextBlock pageLabel = Label("", 8, Secondary);
    private readonly TextBlock sharingLabel = Label("", 8, Secondary);
    private readonly StackPanel rows = new();
    private readonly Button previous;
    private readonly Button next;
    private readonly Button refresh;
    private readonly ScrollViewer scroll;
    private LeaderboardSnapshot snapshot = new();
    private ZunoProfile? profile;
    private int offset;
    private bool busy;
    public event Action? BackRequested;
    public event Action<int>? PageRequested;
    public event Action? ProfileRequested;

    public LeaderboardView()
    {
        Padding = new Thickness(14, 12, 14, 12);
        CornerRadius = new CornerRadius(14);
        BorderThickness = new Thickness(0.7);
        SnapsToDevicePixels = true;
        UseLayoutRounding = true;
        ClipToBounds = true;
        SetBackground(true);
        var content = new Grid();
        for (var i = 0; i < 5; i++) content.RowDefinitions.Add(new RowDefinition
        { Height = i == 2 ? new GridLength(1, GridUnitType.Star) : GridLength.Auto });
        Child = content;

        var header = new Grid { Margin = new Thickness(0, 0, 0, 6) };
        header.ColumnDefinitions.Add(new ColumnDefinition());
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        header.Children.Add(Label("YESTERDAY / LEADERBOARD", 9, Silver));
        var back = ActionButton("‹ Back", "Back to Counter", () => BackRequested?.Invoke());
        Grid.SetColumn(back, 1); header.Children.Add(back); content.Children.Add(header);

        var metadata = new StackPanel { Margin = new Thickness(0, 0, 0, 5) };
        metadata.Children.Add(dateLabel);
        statusLabel.TextWrapping = TextWrapping.Wrap;
        statusLabel.Margin = new Thickness(0, 4, 0, 0);
        metadata.Children.Add(statusLabel);
        Grid.SetRow(metadata, 1); content.Children.Add(metadata);
        scroll = new ScrollViewer
        {
            Content = rows, VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
            CanContentScroll = false, Focusable = false, Padding = new Thickness(0)
        };
        scroll.Resources.Add(typeof(System.Windows.Controls.Primitives.ScrollBar), ObserverView.CreateScrollBarStyle());
        Grid.SetRow(scroll, 2); content.Children.Add(scroll);
        ownLabel.TextWrapping = TextWrapping.Wrap;
        ownLabel.Margin = new Thickness(0, 5, 0, 3);
        Grid.SetRow(ownLabel, 3); content.Children.Add(ownLabel);

        var footer = new StackPanel();
        var navigation = new DockPanel();
        previous = ActionButton("‹", "Previous leaderboard page", () => PageRequested?.Invoke(Math.Max(0, offset - PageSize)));
        next = ActionButton("›", "Next leaderboard page", () => PageRequested?.Invoke(offset + PageSize));
        refresh = ActionButton("Refresh", "Refresh leaderboard", () => PageRequested?.Invoke(offset));
        var account = ActionButton("Profile", "Your Zuno profile", () => ProfileRequested?.Invoke());
        DockPanel.SetDock(previous, Dock.Left); navigation.Children.Add(previous);
        DockPanel.SetDock(next, Dock.Right); navigation.Children.Add(next);
        DockPanel.SetDock(account, Dock.Right); navigation.Children.Add(account);
        DockPanel.SetDock(refresh, Dock.Right); navigation.Children.Add(refresh);
        navigation.Children.Add(pageLabel); footer.Children.Add(navigation);
        sharingLabel.TextWrapping = TextWrapping.Wrap;
        sharingLabel.Margin = new Thickness(0, 3, 0, 0);
        footer.Children.Add(sharingLabel);
        var privacy = Label("Self-reported · Not verified by OpenAI", 8, Secondary);
        privacy.Margin = new Thickness(0, 4, 0, 0);
        privacy.ToolTip = "One installation per entry. Asia/Shanghai days. Late reports can update yesterday's ranking.";
        footer.Children.Add(privacy);
        Grid.SetRow(footer, 4); content.Children.Add(footer);
        Apply(new LeaderboardSnapshot(), 0, null);
    }

    public void Apply(LeaderboardSnapshot value, int pageOffset, ZunoProfile? currentProfile)
    {
        snapshot = value;
        profile = currentProfile;
        if (offset != pageOffset) scroll.ScrollToTop();
        offset = pageOffset;
        dateLabel.Text = value.Date is null ? "Yesterday · Asia/Shanghai" : $"{value.Date} · Asia/Shanghai";
        dateLabel.ToolTip = value.UpdatedAt is null ? "No successful reading yet." : $"Last ranking update: {value.UpdatedAt}";
        rows.Children.Clear();
        foreach (var entry in value.Entries)
        {
            var row = new Grid { Height = 28, Margin = new Thickness(0, 0, 7, 0) };
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(29) });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            var rank = Label(entry.Rank.ToString("D2", CultureInfo.InvariantCulture), 9, Secondary);
            var nickname = Label(entry.Nickname, 10, Silver);
            nickname.TextTrimming = TextTrimming.CharacterEllipsis;
            nickname.Margin = new Thickness(0, 0, 6, 0);
            nickname.ToolTip = entry.Nickname;
            var tokens = Label(entry.TotalTokens.ToString("N0", CultureInfo.InvariantCulture), 11, entry.Rank <= 3 ? Accent : Silver);
            tokens.FontFamily = new FontFamily("Consolas, Segoe UI");
            Grid.SetColumn(nickname, 1); Grid.SetColumn(tokens, 2);
            row.Children.Add(rank); row.Children.Add(nickname); row.Children.Add(tokens);
            AutomationProperties.SetName(row, $"Rank {entry.Rank}, {entry.Nickname}, {entry.TotalTokens} tokens");
            rows.Children.Add(row);
        }
        var outsidePage = value.OwnEntry != null && !value.Entries.Any(entry => entry.Id == value.OwnEntry.Id);
        var sharingState = SharingState();
        ownLabel.Text = value.OwnEntry != null && (outsidePage || sharingState.Length > 0)
            ? $"You · #{value.OwnEntry!.Rank} {value.OwnEntry.Nickname} · {value.OwnEntry.TotalTokens.ToString("N0", CultureInfo.InvariantCulture)}"
            : sharingState.Length > 0 ? "You"
            : value.Status == "ok" && value.OwnEntry == null && currentProfile?.IsJoined == true
                ? "You · Not ranked yesterday" : "";
        if (sharingState.Length > 0) ownLabel.Text += " · " + sharingState;
        ownLabel.Visibility = ownLabel.Text.Length == 0 ? Visibility.Collapsed : Visibility.Visible;
        UpdateStatus();
    }

    public void SetBusy(bool value) { busy = value; UpdateStatus(); }

    private void UpdateStatus()
    {
        statusLabel.Text = busy || snapshot.Status == "loading" ? "Loading yesterday's ranking…"
            : snapshot.Status == "not_configured" ? "Leaderboard service is not configured. Local counting continues."
            : snapshot.Status == "offline" || snapshot.Stale ? "Offline · Showing the last available ranking."
            : snapshot.Entries.Count == 0 ? "No reported activity for yesterday yet."
            : $"{snapshot.TotalParticipants:N0} participants · Daily tokens";
        if ((snapshot.Status == "offline" || snapshot.Stale) && snapshot.Entries.Count == 0)
            statusLabel.Text = "Leaderboard is offline. Local counting continues.";
        var sharingState = SharingState();
        sharingLabel.Text = sharingState.Length == 0 ? "" : sharingState + " · Your daily total may be out of date.";
        sharingLabel.Visibility = sharingState.Length == 0 ? Visibility.Collapsed : Visibility.Visible;
        pageLabel.Text = snapshot.Entries.Count == 0 ? "—" : $"{offset + 1}–{offset + snapshot.Entries.Count}";
        previous.IsEnabled = !busy && offset > 0;
        next.IsEnabled = !busy && !snapshot.Stale && snapshot.Status == "ok" && offset + snapshot.Entries.Count < snapshot.TotalParticipants;
        refresh.IsEnabled = !busy;
    }

    private string SharingState() => profile?.Status == "paused" ? "Sharing paused"
        : snapshot.OwnEntryStale || snapshot.Error == "sync_failed"
            || (profile?.IsJoined == true && !string.IsNullOrEmpty(profile.Error)) ? "Upload pending" : "";

    public void SetBackground(bool enabled)
    {
        Background = enabled ? new SolidColorBrush(Color.FromArgb(232, 7, 12, 18)) : Brushes.Transparent;
        BorderBrush = enabled ? new SolidColorBrush(Color.FromRgb(34, 47, 59)) : Brushes.Transparent;
    }

    private static Button ActionButton(string content, string accessibleName, Action action)
    {
        var button = new Button { Content = content, FontSize = 9, Foreground = Accent,
            Background = Brushes.Transparent, BorderThickness = new Thickness(0),
            Padding = new Thickness(5, 3, 5, 3), Cursor = Cursors.Hand, ToolTip = accessibleName };
        AutomationProperties.SetName(button, accessibleName);
        button.Click += (_, _) => action();
        return button;
    }

    private static TextBlock Label(string text, double size, Brush color) => new()
    {
        Text = text, FontFamily = new FontFamily("Bahnschrift, Segoe UI"), FontSize = size,
        FontWeight = FontWeights.SemiBold, Foreground = color,
        VerticalAlignment = VerticalAlignment.Center, TextWrapping = TextWrapping.NoWrap
    };
}
