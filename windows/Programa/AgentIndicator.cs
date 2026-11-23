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

    /// <summary>The logo asset of an agent, as macOS TerminalTabAgentIconResolver: screen-manifest
    /// ids, hook provider names and the agents' short names. Aider has none (Lobe Icons has no mark).</summary>
    internal static string? LogoAsset(string? agent) => agent?.Trim().ToLowerInvariant() switch
    {
        "claude-code" or "claude" => "AgentIconClaudeCode",
        "codex" => "AgentIconCodex",
        "copilot-cli" or "copilot" or "github-copilot" => "AgentIconCopilot",
        "cursor-agent" or "cursor" => "AgentIconCursor",
        "gemini-cli" or "gemini" => "AgentIconGeminiCLI",
        "opencode" => "AgentIconOpenCode",
        _ => null,
    };

    /// <summary>A logo's SVG: the macOS Assets.xcassets/AgentIcons file (Lobe Icons, MIT; see its
    /// ATTRIBUTIONS.md), embedded in the app, in its dark variant when there is one and <paramref name="dark"/>.</summary>
    internal static byte[] LogoSvg(string asset, bool dark)
    {
        var assembly = typeof(AgentIndicator).Assembly;
        using var stream = (dark ? assembly.GetManifestResourceStream($"AgentIcons.{asset}-dark.svg") : null)
            ?? assembly.GetManifestResourceStream($"AgentIcons.{asset}.svg")
            ?? throw new InvalidOperationException($"{asset} is not embedded");
        using var bytes = new MemoryStream();
        stream.CopyTo(bytes);
        return bytes.ToArray();
    }

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
