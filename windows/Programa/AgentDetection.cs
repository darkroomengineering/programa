using System.Text.Json;
using System.Text.RegularExpressions;

namespace Programa;

internal sealed record AgentState(string Bucket, int Priority, int AnchorLastLines, Regex[] Patterns);

internal sealed record AgentManifest(string Agent, string DisplayName, Regex[] ScreenPatterns, AgentState[] States)
{
    /// <summary>The first state, by priority, with a pattern in its last N lines; "done" reads as idle.</summary>
    internal string? Classify(string text)
    {
        var lines = text.Replace("\r\n", "\n").TrimEnd('\n').Split('\n');
        foreach (var state in States.OrderByDescending(item => item.Priority))
        {
            var tail = string.Join('\n', lines.Skip(Math.Max(0, lines.Length - state.AnchorLastLines)));
            if (state.Patterns.Any(pattern => AgentDetection.Matches(pattern, tail))) return state.Bucket == "done" ? "idle" : state.Bucket;
        }
        return null;
    }
}

/// <summary>Screen-manifest agent detection, as on macOS (docs/agent-detection-manifests.md): the
/// bundled manifests from Resources/AgentDetection, each fully replaced by a file of the same agent id
/// in %USERPROFILE%\.config\programa\agent-detection.</summary>
internal static class AgentDetection
{
    private static readonly TimeSpan PatternTimeout = TimeSpan.FromMilliseconds(50);

    internal static string UserFolder => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".config", "programa", "agent-detection");

    internal static IReadOnlyList<AgentManifest> Load(string bundledFolder, string userFolder)
    {
        var manifests = new Dictionary<string, AgentManifest>(StringComparer.Ordinal);
        foreach (var folder in new[] { bundledFolder, userFolder })
        {
            if (!Directory.Exists(folder)) continue;
            foreach (var file in Directory.EnumerateFiles(folder, "*.json"))
            {
                // A file that fails to parse is skipped, so one bad override never stops the others.
                try { if (Parse(File.ReadAllText(file)) is { } manifest) manifests[manifest.Agent] = manifest; }
                catch (Exception error) when (error is JsonException or ArgumentException or IOException or InvalidOperationException or KeyNotFoundException) { }
            }
        }
        return manifests.Values.ToList();
    }

    internal static AgentManifest? Parse(string json)
    {
        using var document = JsonDocument.Parse(json);
        var root = document.RootElement;
        var agent = root.GetProperty("agent").GetString();
        if (string.IsNullOrEmpty(agent)) return null;
        var screen = root.TryGetProperty("recognize", out var recognize) && recognize.TryGetProperty("screen_patterns", out var patterns)
            ? Compile(patterns) : [];
        var states = root.TryGetProperty("states", out var list)
            ? list.EnumerateArray().Select(state => new AgentState(
                state.GetProperty("bucket").GetString()!,
                state.TryGetProperty("priority", out var priority) ? priority.GetInt32() : 0,
                state.TryGetProperty("anchor_last_n_lines", out var anchor) ? anchor.GetInt32() : 12,
                state.TryGetProperty("patterns", out var statePatterns) ? Compile(statePatterns) : [])).ToArray()
            : [];
        var name = root.TryGetProperty("display_name", out var display) ? display.GetString() ?? agent : agent;
        return new AgentManifest(agent, name, screen, states);
    }

    /// <summary>The manifest whose screen patterns match the text, if any.</summary>
    internal static AgentManifest? Recognize(IReadOnlyList<AgentManifest> manifests, string text) =>
        manifests.FirstOrDefault(manifest => manifest.ScreenPatterns.Any(pattern => Matches(pattern, text)));

    internal static bool Matches(Regex pattern, string text)
    {
        try { return pattern.IsMatch(text); }
        catch (RegexMatchTimeoutException) { return false; }
    }

    private static Regex[] Compile(JsonElement patterns) =>
        patterns.EnumerateArray().Select(pattern => new Regex(pattern.GetString()!, RegexOptions.CultureInvariant, PatternTimeout)).ToArray();
}
