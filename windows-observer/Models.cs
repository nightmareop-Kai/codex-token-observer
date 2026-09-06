using System.Collections.Generic;
using System.Text.Json.Serialization;

namespace TokenObserver;

public sealed class UsageSnapshot
{
    [JsonPropertyName("today")] public long Today { get; set; }
    [JsonPropertyName("total")] public long Total { get; set; }
    [JsonPropertyName("projects")] public List<ProjectUsage> Projects { get; set; } = new();
    [JsonPropertyName("quota")] public QuotaUsage? Quota { get; set; }
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
