using System.Collections.Generic;
using System.Text.Json.Serialization;

namespace TokenObserver;

public sealed class UsageSnapshot
{
    [JsonPropertyName("today")] public long Today { get; set; }
    [JsonPropertyName("total")] public long Total { get; set; }
    [JsonPropertyName("projects")] public List<ProjectUsage> Projects { get; set; } = new();
    [JsonPropertyName("quota")] public QuotaUsage? Quota { get; set; }
    [JsonPropertyName("profile")] public ZunoProfile? Profile { get; set; }
    [JsonPropertyName("leaderboard")] public LeaderboardSnapshot? Leaderboard { get; set; }
}

public sealed class ZunoProfile
{
    [JsonPropertyName("status")] public string Status { get; set; } = "needs_name";
    [JsonPropertyName("id")] public string? Id { get; set; }
    [JsonPropertyName("nickname")] public string? Nickname { get; set; }
    [JsonPropertyName("error")] public string? Error { get; set; }
    public bool IsJoined => Status is "active" or "paused";
}

public sealed class ProfileResponse
{
    [JsonPropertyName("profile")] public ZunoProfile? Profile { get; set; }
}

public sealed class LeaderboardEntry
{
    [JsonPropertyName("id")] public string Id { get; set; } = "";
    [JsonPropertyName("rank")] public int Rank { get; set; }
    [JsonPropertyName("nickname")] public string Nickname { get; set; } = "";
    [JsonPropertyName("total_tokens")] public long TotalTokens { get; set; }
}

public sealed class LeaderboardSnapshot
{
    [JsonPropertyName("status")] public string Status { get; set; } = "loading";
    [JsonPropertyName("date")] public string? Date { get; set; }
    [JsonPropertyName("time_zone")] public string TimeZone { get; set; } = "Asia/Shanghai";
    [JsonPropertyName("entries")] public List<LeaderboardEntry> Entries { get; set; } = new();
    [JsonPropertyName("total_participants")] public int TotalParticipants { get; set; }
    [JsonPropertyName("own_entry")] public LeaderboardEntry? OwnEntry { get; set; }
    [JsonPropertyName("updated_at")] public string? UpdatedAt { get; set; }
    [JsonPropertyName("stale")] public bool Stale { get; set; }
    [JsonPropertyName("error")] public string? Error { get; set; }
    [JsonPropertyName("own_entry_stale")] public bool OwnEntryStale { get; set; }
}

public sealed class ProjectUsage
{
    [JsonPropertyName("name")] public string Name { get; set; } = "Unassigned";
    [JsonPropertyName("path")] public string Path { get; set; } = "";
    [JsonPropertyName("today")] public long Today { get; set; }
    [JsonPropertyName("total")] public long Total { get; set; }
}

public sealed class QuotaUsage
{
    [JsonPropertyName("available")] public bool Available { get; set; }
    [JsonPropertyName("stale")] public bool Stale { get; set; }
    [JsonPropertyName("estimated")] public bool Estimated { get; set; }
    [JsonPropertyName("current_percent")] public double? CurrentPercent { get; set; }
    [JsonPropertyName("cumulative_percent")] public double? CumulativePercent { get; set; }
    [JsonPropertyName("resets_at")] public double? ResetsAt { get; set; }
    [JsonPropertyName("reset_count")] public int ResetCount { get; set; }
}
