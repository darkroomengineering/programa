namespace Programa;

/// <summary>
/// A workspace's agent indicator, computed as the macOS app does (SidebarAgentIndicator in
/// Sources/AgentActivityState.swift): the worst state among its terminals (needs input, then
/// working, then the resting states), ties going to the freshest report. Reports come from OSC 7501,
/// which Claude Code 2.1.295+ sends on its own.
/// </summary>
internal sealed record AgentIndicator(string State, string LabelKey, string Glyph, bool IsStale, DateTimeOffset LastEventAt, string? App, string? Message)
{
    /// <summary>A working or needs-input agent with no report for this long reads "(stale)".</summary>
    internal static readonly TimeSpan StaleAfter = TimeSpan.FromMinutes(10);

    /// <summary>Claude Code's logo (Lobe Icons claudecode-color, MIT; the macOS AgentIconClaudeCode
    /// asset) as 24x24 path data, and its color.</summary>
    internal const string ClaudeLogoPath = "M20.998 10.949H24v3.102h-3v3.028h-1.487V20H18v-2.921h-1.487V20H15v-2.921H9V20H7.488v-2.921H6V20H4.487v-2.921H3V14.05H0V10.95h3V5h17.998v5.949zM6 10.949h1.488V8.102H6v2.847zm10.51 0H18V8.102h-1.49v2.847z";
    internal const string ClaudeLogoColor = "#D97757";

    internal static AgentIndicator? From(IEnumerable<(ProgramStatusRecord Status, DateTimeOffset At)> reports, DateTimeOffset now)
    {
        var (status, at) = reports
            .OrderByDescending(report => Severity(report.Status.State))
            .ThenByDescending(report => report.At)
            .FirstOrDefault();
        if (status is null) return null;
        var stale = status.State is "working" or "blocked" && now - at > StaleAfter;
        var (labelKey, glyph) = status.State switch
        {
            "blocked" => (stale ? "AgentNeedsInputStale" : "AgentNeedsInput", ""),
            "working" => (stale ? "AgentWorkingStale" : "AgentWorking", ""),
            "done" => ("AgentDone", ""),
            "error" => ("AgentError", ""),
            _ => ("AgentIdle", ""),
        };
        return new(status.State, labelKey, glyph, stale, at, status.App, status.Msg);
    }

    private static int Severity(string state) => state switch { "blocked" => 2, "working" => 1, _ => 0 };

    /// <summary>"3m", "2h", "4d" since the last report, or null under a minute ("now").</summary>
    internal static (string Key, long Value)? Elapsed(TimeSpan span) =>
        span.TotalMinutes < 1 ? null
        : span.TotalHours < 1 ? ("ElapsedMinutes", (long)span.TotalMinutes)
        : span.TotalDays < 1 ? ("ElapsedHours", (long)span.TotalHours)
        : ("ElapsedDays", (long)span.TotalDays);
}
