using System.Text.Json;
using System.Text.RegularExpressions;

namespace Programa;

internal sealed record AgentState(string Bucket, int Priority, int AnchorLastLines, Regex[] Patterns, string? Confidence = null, string? SourceNotes = null);

/// <summary>A manifest; <paramref name="Source"/> is "bundled" or "override" (a file in the user folder).</summary>
internal sealed record AgentManifest(string Agent, string DisplayName, Regex[] ScreenPatterns, AgentState[] States, string Source = "bundled", string[]? ProcessNames = null)
{
    /// <summary>The first state, by priority, with a pattern in its last N lines; "done" reads as idle.</summary>
    internal string? Classify(string text) => Match(text) is { } match ? match.State.Bucket == "done" ? "idle" : match.State.Bucket : null;

    /// <summary>The state that matched and its pattern, as agent.detection.classify reports them.</summary>
    internal (AgentState State, string Pattern)? Match(string text)
    {
        var lines = text.Replace("\r\n", "\n").TrimEnd('\n').Split('\n');
        foreach (var state in States.OrderByDescending(item => item.Priority))
        {
            var tail = string.Join('\n', lines.Skip(Math.Max(0, lines.Length - state.AnchorLastLines)));
            if (state.Patterns.FirstOrDefault(pattern => AgentDetection.Matches(pattern, tail)) is { } matched) return (state, matched.ToString());
        }
        return null;
    }
}

/// <summary>A manifest file left out because some of its patterns do not compile.</summary>
internal sealed record RejectedManifest(string Agent, string Path, string[] InvalidPatterns);

/// <summary>Screen-manifest agent detection, as on macOS (docs/agent-detection-manifests.md): the
/// bundled manifests from Resources/AgentDetection, each fully replaced by a file of the same agent id
/// in %USERPROFILE%\.config\programa\agent-detection.</summary>
internal static class AgentDetection
{
    private static readonly TimeSpan PatternTimeout = TimeSpan.FromMilliseconds(50);

    internal static string UserFolder => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".config", "programa", "agent-detection");

    internal static string BundledFolder => Path.Combine(AppContext.BaseDirectory, "AgentDetection");

    internal static IReadOnlyList<AgentManifest> Load(string bundledFolder, string userFolder) => LoadAll(bundledFolder, userFolder).Manifests;

    /// <summary>The manifests by agent id, and the files rejected for patterns that do not compile.</summary>
    internal static (IReadOnlyList<AgentManifest> Manifests, IReadOnlyList<RejectedManifest> Rejected) LoadAll(string bundledFolder, string userFolder)
    {
        var manifests = new Dictionary<string, AgentManifest>(StringComparer.Ordinal);
        var rejected = new List<RejectedManifest>();
        foreach (var (folder, source) in new[] { (bundledFolder, "bundled"), (userFolder, "override") })
        {
            if (!Directory.Exists(folder)) continue;
            foreach (var file in Directory.EnumerateFiles(folder, "*.json"))
            {
                // A file that fails to parse is skipped, so one bad override never stops the others.
                try
                {
                    var invalid = new List<string>();
                    if (Parse(File.ReadAllText(file), invalid) is not { } manifest) continue;
                    if (invalid.Count > 0) rejected.Add(new RejectedManifest(manifest.Agent, file, [.. invalid]));
                    else manifests[manifest.Agent] = manifest with { Source = source };
                }
                catch (Exception error) when (error is JsonException or ArgumentException or IOException or InvalidOperationException or KeyNotFoundException) { }
            }
        }
        return (manifests.Values.ToList(), rejected);
    }

    internal static AgentManifest? Parse(string json) => Parse(json, null);

    /// <summary>The manifest; a pattern that does not compile goes into <paramref name="invalid"/> (or throws without it).</summary>
    private static AgentManifest? Parse(string json, List<string>? invalid)
    {
        using var document = JsonDocument.Parse(json);
        var root = document.RootElement;
        var agent = root.GetProperty("agent").GetString();
        if (string.IsNullOrEmpty(agent)) return null;
        var recognized = root.TryGetProperty("recognize", out var recognize);
        var screen = recognized && recognize.TryGetProperty("screen_patterns", out var patterns) ? Compile(patterns, invalid) : [];
        var processes = recognized && recognize.TryGetProperty("process_names", out var names)
            ? names.EnumerateArray().Select(name => name.GetString()!).ToArray() : [];
        var states = root.TryGetProperty("states", out var list)
            ? list.EnumerateArray().Select(state => new AgentState(
                state.GetProperty("bucket").GetString()!,
                state.TryGetProperty("priority", out var priority) ? priority.GetInt32() : 0,
                state.TryGetProperty("anchor_last_n_lines", out var anchor) ? anchor.GetInt32() : 12,
                state.TryGetProperty("patterns", out var statePatterns) ? Compile(statePatterns, invalid) : [],
                state.TryGetProperty("confidence", out var confidence) ? confidence.GetString() : null,
                state.TryGetProperty("source_notes", out var notes) ? notes.GetString() : null)).ToArray()
            : [];
        var name = root.TryGetProperty("display_name", out var display) ? display.GetString() ?? agent : agent;
        return new AgentManifest(agent, name, screen, states, ProcessNames: processes);
    }

    /// <summary>The manifest whose screen patterns match the text, if any.</summary>
    internal static AgentManifest? Recognize(IReadOnlyList<AgentManifest> manifests, string text) =>
        manifests.FirstOrDefault(manifest => manifest.ScreenPatterns.Any(pattern => Matches(pattern, text)));

    internal static bool Matches(Regex pattern, string text)
    {
        try { return pattern.IsMatch(text); }
        catch (RegexMatchTimeoutException) { return false; }
    }

    private static Regex[] Compile(JsonElement patterns, List<string>? invalid) =>
        patterns.EnumerateArray().Select(pattern => pattern.GetString()!).Select(source =>
        {
            try { return new Regex(source, RegexOptions.CultureInvariant, PatternTimeout); }
            catch (ArgumentException) when (invalid is not null)
            {
                invalid.Add(source);
                return null;
            }
        }).OfType<Regex>().ToArray();

    /// <summary>agent.detection.list, as on macOS: the manifests as loaded now (re-read from disk), by agent id.</summary>
    internal static object List()
    {
        var (manifests, rejected) = LoadAll(BundledFolder, UserFolder);
        var bundled = Load(BundledFolder, Path.Combine(Path.GetTempPath(), "programa-no-agent-overrides")).Select(manifest => manifest.Agent).ToHashSet(StringComparer.Ordinal);
        return new
        {
            manifests = manifests.OrderBy(manifest => manifest.Agent, StringComparer.Ordinal).Select(manifest => new
            {
                agent = manifest.Agent,
                display_name = manifest.DisplayName,
                source = manifest.Source,
                process_names = manifest.ProcessNames ?? [],
                shadows_bundled = manifest.Source == "override" && bundled.Contains(manifest.Agent),
                states = manifest.States.Select(state => new
                {
                    bucket = state.Bucket,
                    priority = state.Priority,
                    anchor_last_n_lines = state.AnchorLastLines,
                    patterns = state.Patterns.Select(pattern => pattern.ToString()).ToList(),
                    confidence = state.Confidence,
                    source_notes = state.SourceNotes,
                }).ToList(),
            }).ToList(),
            rejected = rejected.Select(item => new { agent = item.Agent, path = item.Path, reason = "invalid patterns: " + string.Join(", ", item.InvalidPatterns) }).ToList(),
        };
    }

    /// <summary>agent.detection.classify: which manifest the text belongs to (the named agent, else the
    /// first whose screen patterns match) and the state it reads as.</summary>
    internal static Dictionary<string, object?> Classify(string text, string? requested, IReadOnlyList<AgentManifest>? manifests = null)
    {
        manifests ??= Load(BundledFolder, UserFolder);
        AgentManifest? manifest = null;
        string? via = null;
        if (requested is not null)
        {
            manifest = manifests.FirstOrDefault(item => item.Agent == requested) ?? throw new ControlException("not_found", $"No manifest loaded for agent '{requested}'");
            via = "explicit";
        }
        else if (text.Length > 0 && Recognize(manifests, text) is { } recognized)
        {
            manifest = recognized;
            via = "screen_pattern";
        }
        var match = manifest?.Match(text);
        return new Dictionary<string, object?>
        {
            ["requested_agent"] = requested, ["recognized_via"] = via, ["agent"] = manifest?.Agent, ["display_name"] = manifest?.DisplayName,
            ["bucket"] = match?.State.Bucket, ["confidence"] = match?.State.Confidence, ["matched_pattern"] = match?.Pattern,
        };
    }
}
