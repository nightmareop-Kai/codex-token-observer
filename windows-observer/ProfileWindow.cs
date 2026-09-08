using System;
using System.Linq;
using System.Text;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Media;

namespace TokenObserver;

/// <summary>Consent is the Create & Join click, never merely opening or closing this window.</summary>
public sealed class ProfileWindow : Window
{
    private readonly TextBox nickname = new() { FontSize = 17, MaxLength = 96, Padding = new Thickness(8), Margin = new Thickness(0, 10, 0, 10) };
    private readonly TextBlock heading = new() { FontSize = 20, FontWeight = FontWeights.SemiBold };
    private readonly TextBlock detail = new() { TextWrapping = TextWrapping.Wrap, FontSize = 12 };
    private readonly TextBlock error = new() { TextWrapping = TextWrapping.Wrap, FontSize = 12, Foreground = Brushes.IndianRed, Margin = new Thickness(0, 8, 0, 8) };
    private readonly Button join = new() { Content = "Create & Join", Padding = new Thickness(14, 7, 14, 7), IsDefault = true };
    private readonly Button sync = new() { Padding = new Thickness(14, 7, 14, 7) };
    private ZunoProfile profile = new();
    private bool busy;
    public event Action<string>? RegisterRequested;
    public event Action? SyncRequested;
    internal bool NameEditableForTests => !nickname.IsReadOnly;

    public ProfileWindow()
    {
        Title = "Your Zuno profile";
        Width = 380; SizeToContent = SizeToContent.Height;
        ResizeMode = ResizeMode.NoResize; WindowStartupLocation = WindowStartupLocation.CenterOwner;
        ShowInTaskbar = false;
        var content = new StackPanel { Margin = new Thickness(22) };
        Content = content;
        content.Children.Add(heading);
        content.Children.Add(nickname);
        AutomationProperties.SetName(nickname, "Permanent Zuno nickname");
        content.Children.Add(detail);
        content.Children.Add(error);
        var controls = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right };
        var later = new Button { Content = "Close", Padding = new Thickness(12, 7, 12, 7), Margin = new Thickness(0, 0, 8, 0), IsCancel = true };
        later.Click += (_, _) => Close();
        controls.Children.Add(later); controls.Children.Add(sync); controls.Children.Add(join);
        content.Children.Add(controls);
        join.Click += (_, _) =>
        {
            if (busy || profile.IsJoined) return;
            var candidate = nickname.Text.Normalize(NormalizationForm.FormKC).Trim();
            var runes = candidate.EnumerateRunes().ToArray();
            if (runes.Length < 2 || runes.Length > 24 || runes.Any(rune =>
                !Rune.IsLetterOrDigit(rune) && rune.Value != ' ' && rune.Value != '_' && rune.Value != '-'))
            {
                error.Text = "Use 2–24 letters, numbers, spaces, underscores or hyphens.";
                return;
            }
            nickname.Text = candidate;
            RegisterRequested?.Invoke(candidate);
        };
        sync.Click += (_, _) => { if (!busy && profile.IsJoined) SyncRequested?.Invoke(); };
        Apply(new ZunoProfile());
    }

    public void Apply(ZunoProfile value, bool requestInProgress = false, string? message = null)
    {
        profile = value; busy = requestInProgress;
        heading.Text = value.IsJoined ? "Your Zuno profile" : "Choose your Zuno name";
        var locked = value.IsJoined || value.Status == "pending" || !string.IsNullOrEmpty(value.Nickname);
        if (value.Nickname is not null) nickname.Text = value.Nickname;
        nickname.IsReadOnly = locked || busy;
        nickname.IsEnabled = !busy;
        join.Visibility = value.IsJoined ? Visibility.Collapsed : Visibility.Visible;
        join.IsEnabled = !busy;
        join.Content = busy ? "Connecting…" : locked ? "Retry Create & Join" : "Create & Join";
        sync.Visibility = value.IsJoined ? Visibility.Visible : Visibility.Collapsed;
        sync.IsEnabled = !busy;
        sync.Content = value.Status == "paused" ? "Resume sync" : "Pause sync";
        detail.Text = value.IsJoined
            ? $"Your name is permanent and cannot be changed.\n\nLeaderboard sync is {(value.Status == "paused" ? "paused" : "active")}. Pausing stops uploads; your public profile and existing daily results remain visible. Local counting always continues."
            : "This name is permanent and cannot be changed.\n\nCreate & Join makes your nickname, random installation ID and daily token totals public. Only actual activity after you join is eligible. No sessions, project names or Codex account details are shared.\n\nYou can close this window and keep counting locally without joining.";
        error.Text = message ?? (value.IsJoined && !string.IsNullOrEmpty(value.Error)
            ? "Upload pending. Your public daily total may be out of date. Local counting and your permanent identity are unchanged; Zuno will retry when sharing is active."
            : ErrorMessage(value.Error));
    }

    public static string ErrorMessage(string? code) => code switch
    {
        null or "" => "",
        "nickname_taken" => "That name is already taken. Choose another name before joining.",
        "invalid_nickname" => "Use 2–24 letters, numbers, spaces, underscores or hyphens.",
        "rate_limited" => "Too many requests. Please wait and try again.",
        "identity_conflict" => "This installation could not be verified. Your existing identity has not been replaced.",
        "immutable_nickname" => "Your registered name is permanent and cannot be changed.",
        "not_configured" => "The leaderboard service is not configured. Local counting continues.",
        "sync_failed" => "Upload pending. Your daily total may be out of date; local counting continues.",
        _ => "Unable to reach the leaderboard. Your local counting continues. Retry with the same identity."
    };
}
