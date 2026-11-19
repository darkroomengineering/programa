using System.Text;
using System.Text.Json;

namespace Programa;

internal sealed record StatusEntry(string Key, string Value, string? Icon, string? Color, string? Url, int Priority, string Format, DateTimeOffset At);
internal sealed record LogEntry(string Message, string Level, string? Source, DateTimeOffset At);
internal sealed record MetadataBlock(string Key, string Markdown, int Priority, DateTimeOffset At);
internal sealed record SidebarProgress(double Value, string? Label);

/// <summary>One workspace's sidebar metadata: status entries, log, progress and markdown blocks.</summary>
internal sealed class WorkspaceMetadata
{
    internal readonly Dictionary<string, StatusEntry> Status = new(StringComparer.Ordinal);
    internal readonly List<LogEntry> Log = [];
    internal readonly Dictionary<string, MetadataBlock> Blocks = new(StringComparer.Ordinal);
    /// <summary>Agent processes by status key (workspace.set_agent_pid, set_status pid): the port scan looks under them too.</summary>
    internal readonly Dictionary<string, int> AgentPids = new(StringComparer.Ordinal);
    internal SidebarProgress? Progress;
    /// <summary>Bumps on every change, so a sidebar row rebuilds its lines only then.</summary>
    internal int Version;

    /// <summary>Priority first, then newest, then key, as on macOS.</summary>
    internal List<StatusEntry> StatusInOrder() =>
        Status.Values.OrderByDescending(entry => entry.Priority).ThenByDescending(entry => entry.At).ThenBy(entry => entry.Key, StringComparer.Ordinal).ToList();

    internal List<MetadataBlock> BlocksInOrder() =>
        Blocks.Values.OrderByDescending(block => block.Priority).ThenByDescending(block => block.At).ThenBy(block => block.Key, StringComparer.Ordinal).ToList();
}

/// <summary>The sidebar metadata behind workspace.set_status, log, set_progress and report_meta_block,
/// as on macOS (Sources/TerminalController+Telemetry.swift): the same limits, validation and
/// replies. Lives on the UI thread with the windows; a closed workspace's metadata goes with it.
/// Session restore brings back the log and progress, not status entries (their processes are gone).</summary>
internal static class SidebarMetadata
{
    internal const int MaxStatusEntries = 128;
    internal const int MaxBlocks = 128;
    // ponytail: macOS reads a hidden sidebarMaxLogEntries default (1...500); a setting when someone asks.
    internal const int MaxLogEntries = 50;

    internal static readonly string[] Methods =
    [
        "workspace.set_status", "workspace.clear_status", "workspace.list_status",
        "workspace.log", "workspace.clear_log", "workspace.list_log",
        "workspace.set_progress", "workspace.clear_progress",
        "workspace.report_meta_block", "workspace.clear_meta_block", "workspace.list_meta_blocks",
        "workspace.set_agent_pid", "workspace.clear_agent_pid",
    ];

    internal static readonly string[] Levels = ["info", "progress", "success", "warning", "error"];

    private static readonly Dictionary<string, WorkspaceMetadata> Workspaces = new(StringComparer.OrdinalIgnoreCase);

    /// <summary>A workspace's metadata changed.</summary>
    internal static event Action<string>? Changed;

    internal static WorkspaceMetadata? Of(string workspaceId) => Workspaces.GetValueOrDefault(workspaceId);

    private static WorkspaceMetadata For(string workspaceId) =>
        Workspaces.TryGetValue(workspaceId, out var metadata) ? metadata : Workspaces[workspaceId] = new WorkspaceMetadata();

    private static void Touch(string workspaceId, WorkspaceMetadata metadata)
    {
        metadata.Version++;
        Changed?.Invoke(workspaceId);
    }

    internal static object FromControl(string method, string workspaceId, JsonElement p, DateTimeOffset now)
    {
        var metadata = For(workspaceId);
        switch (method)
        {
            case "workspace.set_status":
            {
                var key = Key(p);
                var value = Raw(p, "value") ?? throw Invalid("Missing value");
                Limit(value, 16 * 1024, "value");
                var icon = Limit(Trimmed(p, "icon"), 256, "icon");
                var color = Limit(Trimmed(p, "color"), 128, "color");
                var format = (Trimmed(p, "format") ?? "plain").ToLowerInvariant() switch
                {
                    "plain" => "plain",
                    "markdown" or "md" => "markdown",
                    _ => throw Invalid("Invalid format — use: plain, markdown"),
                };
                var priority = Priority(p);
                string? url = null;
                if (Trimmed(p, "url") is { } rawUrl)
                {
                    if (!Uri.TryCreate(rawUrl, UriKind.Absolute, out var parsed) || parsed.Scheme is not ("http" or "https"))
                        throw Invalid("Invalid url — expected http(s) URL");
                    url = Limit(parsed.AbsoluteUri, 4 * 1024, "url");
                }
                var pid = Pid(p, required: false);
                var entry = new StatusEntry(key, value, icon, color, url, priority, format, now);
                // The same entry again keeps its place (macOS shouldReplaceStatusEntry).
                if (metadata.Status.GetValueOrDefault(key) is not { } current || current with { At = now } != entry)
                {
                    while (!metadata.Status.ContainsKey(key) && metadata.Status.Count >= MaxStatusEntries)
                        metadata.Status.Remove(metadata.Status.Values.OrderBy(old => old.At).ThenBy(old => old.Key, StringComparer.Ordinal).First().Key);
                    metadata.Status[key] = entry;
                    Touch(workspaceId, metadata);
                }
                if (pid is { } agent) SetAgentPid(metadata, key, agent);
                return new { workspace_id = workspaceId, key, value };
            }
            case "workspace.clear_status":
            {
                var key = Trimmed(p, "key") ?? throw Invalid("Missing key");
                if (metadata.Status.Remove(key)) Touch(workspaceId, metadata);
                metadata.AgentPids.Remove(key);
                return new { workspace_id = workspaceId, key };
            }
            case "workspace.set_agent_pid":
            {
                var key = Key(p);
                var pid = Pid(p, required: true)!.Value;
                SetAgentPid(metadata, key, pid);
                return new { workspace_id = workspaceId, key, pid };
            }
            case "workspace.clear_agent_pid":
            {
                var key = Key(p);
                metadata.AgentPids.Remove(key);
                return new { workspace_id = workspaceId, key };
            }
            case "workspace.list_status":
                return new { workspace_id = workspaceId, entries = metadata.StatusInOrder().Select(StatusJson) };
            case "workspace.log":
            {
                var message = Raw(p, "message") is { Length: > 0 } text ? text : throw Invalid("Missing message");
                Limit(message, 64 * 1024, "message");
                var level = Trimmed(p, "level") ?? "info";
                if (!Levels.Contains(level)) throw Invalid("Unknown log level — use: info, progress, success, warning, error");
                var source = Limit(Trimmed(p, "source"), 512, "source");
                Append(metadata, new LogEntry(message, level, source, now));
                Touch(workspaceId, metadata);
                return new { workspace_id = workspaceId, message, level, source };
            }
            case "workspace.clear_log":
                if (metadata.Log.Count > 0)
                {
                    metadata.Log.Clear();
                    Touch(workspaceId, metadata);
                }
                return new { workspace_id = workspaceId };
            case "workspace.list_log":
            {
                IEnumerable<LogEntry> entries = metadata.Log;
                if (Present(p, "limit"))
                {
                    if (!p.GetProperty("limit").TryGetInt32(out var limit) || limit < 0) throw Invalid("Invalid limit — must be >= 0");
                    entries = metadata.Log.TakeLast(limit);
                }
                return new { workspace_id = workspaceId, entries = entries.Select(entry => new { message = entry.Message, level = entry.Level, source = entry.Source, timestamp = entry.At.ToUnixTimeMilliseconds() / 1000.0 }) };
            }
            case "workspace.set_progress":
            {
                var value = Present(p, "value") ? p.GetProperty("value") : default;
                var number = value.ValueKind == JsonValueKind.Number ? value.GetDouble()
                    : value.ValueKind == JsonValueKind.String && double.TryParse(value.GetString(), System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out var parsed) ? parsed
                    : double.NaN;
                if (!double.IsFinite(number)) throw Invalid("Invalid progress value — must be 0.0 to 1.0");
                var clamped = Math.Clamp(number, 0, 1);
                var label = Limit(Trimmed(p, "label"), 512, "label");
                var progress = new SidebarProgress(clamped, label);
                if (metadata.Progress != progress)
                {
                    metadata.Progress = progress;
                    Touch(workspaceId, metadata);
                }
                return new { workspace_id = workspaceId, value = clamped, label };
            }
            case "workspace.clear_progress":
                if (metadata.Progress is not null)
                {
                    metadata.Progress = null;
                    Touch(workspaceId, metadata);
                }
                return new { workspace_id = workspaceId };
            case "workspace.report_meta_block":
            {
                var key = Key(p);
                // Literal \n, \t and \r\n from a shell argument become real ones, as on macOS.
                var markdown = (Raw(p, "markdown") ?? throw Invalid("Missing markdown"))
                    .Replace("\\r\\n", "\n").Replace("\\n", "\n").Replace("\\t", "\t");
                if (markdown.Trim().Length == 0) throw Invalid("Missing markdown");
                Limit(markdown, 256 * 1024, "markdown");
                var priority = Priority(p);
                var block = new MetadataBlock(key, markdown, priority, now);
                if (metadata.Blocks.GetValueOrDefault(key) is not { } current || current with { At = now } != block)
                {
                    while (!metadata.Blocks.ContainsKey(key) && metadata.Blocks.Count >= MaxBlocks)
                        metadata.Blocks.Remove(metadata.Blocks.Values.OrderBy(old => old.At).ThenBy(old => old.Key, StringComparer.Ordinal).First().Key);
                    metadata.Blocks[key] = block;
                    Touch(workspaceId, metadata);
                }
                return new { workspace_id = workspaceId, key, markdown, priority };
            }
            case "workspace.clear_meta_block":
            {
                var key = Trimmed(p, "key") ?? throw Invalid("Missing key");
                var found = metadata.Blocks.Remove(key);
                if (found) Touch(workspaceId, metadata);
                return new { workspace_id = workspaceId, key, found };
            }
            case "workspace.list_meta_blocks":
                return new { workspace_id = workspaceId, blocks = metadata.BlocksInOrder().Select(BlockJson) };
        }
        throw new ControlException("method_not_found", $"{method} is not a sidebar method.");
    }

    internal const int MaxAgentPids = 128;

    private static void SetAgentPid(WorkspaceMetadata metadata, string key, int pid)
    {
        if (metadata.AgentPids.ContainsKey(key) || metadata.AgentPids.Count < MaxAgentPids) metadata.AgentPids[key] = pid;
    }

    private static int? Pid(JsonElement p, bool required)
    {
        if (!Present(p, "pid")) return required ? throw Invalid("pid must be an integer from 1 through 2147483647") : null;
        return p.GetProperty("pid").TryGetInt32(out var pid) && pid >= 1 ? pid : throw Invalid("pid must be an integer from 1 through 2147483647");
    }

    /// <summary>Every agent process a workspace registered, for the port scan.</summary>
    internal static IEnumerable<(string WorkspaceId, int Pid)> AgentProcesses() =>
        Workspaces.SelectMany(item => item.Value.AgentPids.Values.Select(pid => (item.Key, pid)));

    internal static object StatusJson(StatusEntry entry) =>
        new { key = entry.Key, value = entry.Value, icon = entry.Icon, color = entry.Color, url = entry.Url, priority = entry.Priority, format = entry.Format };

    internal static object BlockJson(MetadataBlock block) => new { key = block.Key, markdown = block.Markdown, priority = block.Priority };

    private static void Append(WorkspaceMetadata metadata, LogEntry entry)
    {
        metadata.Log.Add(entry);
        if (metadata.Log.Count > MaxLogEntries) metadata.Log.RemoveRange(0, metadata.Log.Count - MaxLogEntries);
    }

    /// <summary>workspace.reset_sidebar: status entries, log, progress and blocks all go.</summary>
    internal static void Reset(string workspaceId)
    {
        if (!Workspaces.Remove(workspaceId, out var metadata)) return;
        Touch(workspaceId, metadata);
    }

    internal static void Retain(ICollection<string> openWorkspaces)
    {
        foreach (var id in Workspaces.Keys.Where(id => !openWorkspaces.Contains(id)).ToList()) Workspaces.Remove(id);
    }

    internal static void Clear() => Workspaces.Clear();

    /// <summary>What a session keeps of a workspace: its log and progress.</summary>
    internal static SessionSidebar? Saved(string workspaceId) =>
        Of(workspaceId) is { } metadata && (metadata.Log.Count > 0 || metadata.Progress is not null)
            ? new SessionSidebar([.. metadata.Log.Select(entry => new SessionLogEntry(entry.Message, entry.Level, entry.Source, entry.At))], metadata.Progress)
            : null;

    internal static void Restore(string workspaceId, SessionSidebar saved)
    {
        var metadata = For(workspaceId);
        metadata.Log.Clear();
        foreach (var entry in saved.Log ?? [])
            if (entry.Message is { Length: > 0 } && Levels.Contains(entry.Level)) Append(metadata, new LogEntry(entry.Message, entry.Level, entry.Source, entry.At));
        metadata.Progress = saved.Progress is { } progress && double.IsFinite(progress.Value) ? progress with { Value = Math.Clamp(progress.Value, 0, 1) } : null;
        Touch(workspaceId, metadata);
    }

    private static bool Present(JsonElement p, string name) =>
        p.ValueKind == JsonValueKind.Object && p.TryGetProperty(name, out var value) && value.ValueKind != JsonValueKind.Null;

    private static string? Raw(JsonElement p, string name) =>
        p.ValueKind == JsonValueKind.Object && p.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.String ? value.GetString() : null;

    /// <summary>A string parameter trimmed, or null when it is missing or blank (macOS v2String).</summary>
    private static string? Trimmed(JsonElement p, string name) => Raw(p, name)?.Trim() is { Length: > 0 } text ? text : null;

    private static string Key(JsonElement p) => Limit(Trimmed(p, "key") ?? throw Invalid("Missing key"), 512, "key")!;

    private static int Priority(JsonElement p)
    {
        if (!Present(p, "priority")) return 0;
        var value = p.GetProperty("priority");
        if (value.ValueKind != JsonValueKind.Number || !value.TryGetInt64(out var priority)) throw Invalid("Invalid priority — must be an integer");
        return (int)Math.Clamp(priority, -9999, 9999);
    }

    private static string? Limit(string? value, int maxBytes, string name) =>
        value is not null && Encoding.UTF8.GetByteCount(value) > maxBytes ? throw Invalid($"{name} exceeds the UTF-8 limit of {maxBytes} bytes") : value;

    private static ControlException Invalid(string message) => new("invalid_params", message);
}
