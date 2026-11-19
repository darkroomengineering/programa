using System.Globalization;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace Programa;

/// <summary>A helper: a subagent or subtask running inside its parent agent's terminal.</summary>
internal sealed record Helper(string Id, string? ParentId, string Host, string? Session, string? Task, string? Role, string? Summary, string State,
    string Placement, string WorkspaceId, string? SurfaceId, DateTimeOffset StartedAt, DateTimeOffset UpdatedAt, DateTimeOffset? EndedAt)
{
    internal bool Finished => Helpers.IsFinished(State);

    /// <summary>The macOS `agent` payload (AgentTaskRecord.payload).</summary>
    internal JsonObject Json()
    {
        static string Time(DateTimeOffset at) => at.UtcDateTime.ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'", CultureInfo.InvariantCulture);
        var independent = Placement != "runs_with_parent" && SurfaceId is not null;
        return new JsonObject
        {
            ["id"] = Id, ["parent_id"] = ParentId, ["host"] = Host, ["session"] = Session, ["task"] = Task, ["role"] = Role, ["summary"] = Summary,
            ["state"] = State, ["placement"] = Placement, ["workspace_id"] = WorkspaceId, ["surface_id"] = SurfaceId,
            ["has_independent_output"] = independent,
            ["output_location"] = Placement == "runs_with_parent" ? "runs_with_parent" : independent ? "workspace_surface" : "unavailable",
            ["started_at"] = Time(StartedAt), ["updated_at"] = Time(UpdatedAt), ["ended_at"] = EndedAt is { } ended ? Time(ended) : null,
        };
    }
}

/// <summary>The helper registry behind `agent.task.*` and the sidebar's helpers line, as on macOS
/// (Sources/AgentSupervision.swift): at most 256 helpers, the oldest finished one making room.
/// Lives on the UI thread with the windows; a closed workspace's helpers go with it.</summary>
internal static class Helpers
{
    internal const int Capacity = 256;
    private static readonly Dictionary<string, Helper> Records = new(StringComparer.OrdinalIgnoreCase);

    /// <summary>A workspace's helpers changed.</summary>
    internal static event Action<string>? Changed;

    internal static bool IsFinished(string state) => state is "completed" or "failed" or "cancelled";

    private static readonly string[] States = ["idle", "working", "blocked", "completed", "failed", "cancelled"];
    private static readonly string[] Placements = ["runs_with_parent", "nested_workspace", "separate_worktree"];

    internal static Helper? Find(string id) => Records.GetValueOrDefault(id);

    /// <summary>What the popover shows: the workspace's helpers that run with their parent.</summary>
    internal static List<Helper> Of(string workspaceId) =>
        Records.Values.Where(helper => helper.Placement == "runs_with_parent" && Same(helper.WorkspaceId, workspaceId)).ToList();

    internal static Helper Start(string id, string? parentId, string host, string? session, string? task, string? role, string? summary,
        string state, string placement, string workspaceId, string? surfaceId, DateTimeOffset now)
    {
        if (Records.ContainsKey(id)) throw new ControlException("invalid_params", $"Helper {id} already exists.");
        if (parentId is not null && (Find(parentId) is not { } parent || !Same(parent.WorkspaceId, workspaceId)))
            throw new ControlException("not_found", "Parent helper not found in workspace", new { parent_id = parentId });
        if (Records.Count >= Capacity)
        {
            var oldest = Records.Values.Where(helper => helper.Finished).MinBy(helper => helper.EndedAt ?? helper.UpdatedAt)
                ?? throw new ControlException("invalid_params", $"Programa already tracks {Capacity} running helpers.");
            Records.Remove(oldest.Id);
        }
        var helper = new Helper(id, parentId, host, session, task, role, summary, state, placement, workspaceId, surfaceId, now, now, IsFinished(state) ? now : null);
        Records[id] = helper;
        Changed?.Invoke(workspaceId);
        return helper;
    }

    internal static Helper Update(string id, string? state, string? session, string? task, string? role, string? summary, string? workspaceId, string? surfaceId, DateTimeOffset now)
    {
        var existing = Find(id) ?? throw new ControlException("not_found", $"Helper {id} not found.", new { agent_id = id });
        if (existing.Finished) throw new ControlException("invalid_params", $"Helper {id} already finished.");
        var next = state ?? existing.State;
        // A helper moved to another workspace without a surface must not keep the old one's terminal.
        var helper = existing with
        {
            State = next, Session = session ?? existing.Session, Task = task ?? existing.Task, Role = role ?? existing.Role, Summary = summary ?? existing.Summary,
            WorkspaceId = workspaceId ?? existing.WorkspaceId, SurfaceId = surfaceId ?? (workspaceId is null ? existing.SurfaceId : null),
            UpdatedAt = now, EndedAt = IsFinished(next) ? now : null,
        };
        Records[id] = helper;
        Changed?.Invoke(helper.WorkspaceId);
        if (!Same(helper.WorkspaceId, existing.WorkspaceId)) Changed?.Invoke(existing.WorkspaceId);
        return helper;
    }

    internal static Helper Finish(string id, string state, string? task, string? summary, DateTimeOffset now)
    {
        if (!IsFinished(state)) throw new ControlException("invalid_params", "state must be completed, failed or cancelled.");
        return Update(id, state, null, task, null, summary, null, null, now);
    }

    /// <summary>Every helper of a host session still active when that session ends.</summary>
    internal static List<Helper> FinishSession(string host, string session, string state, DateTimeOffset now)
    {
        if (!IsFinished(state)) throw new ControlException("invalid_params", "state must be completed, failed or cancelled.");
        return Records.Values.Where(helper => !helper.Finished && helper.Host == host && helper.Session == session).ToList()
            .Select(helper => Update(helper.Id, state, null, null, null, null, null, null, now)).ToList();
    }

    /// <summary>The popover's Clear: the workspace's finished helpers leave the list.</summary>
    internal static void ClearFinished(string workspaceId)
    {
        foreach (var helper in Records.Values.Where(helper => helper.Finished && Same(helper.WorkspaceId, workspaceId)).ToList()) Records.Remove(helper.Id);
        Changed?.Invoke(workspaceId);
    }

    /// <summary>Keeps only the helpers of workspaces still open.</summary>
    internal static void Retain(ICollection<string> openWorkspaces)
    {
        foreach (var helper in Records.Values.Where(helper => !openWorkspaces.Contains(helper.WorkspaceId)).ToList()) Records.Remove(helper.Id);
    }

    internal static void Reset() => Records.Clear();

    private static bool Same(string a, string b) => string.Equals(a, b, StringComparison.OrdinalIgnoreCase);

    /// <summary>`agent.task.*`. <paramref name="workspaceOpen"/> and <paramref name="surfaceIn"/> check
    /// ids against the windows.</summary>
    internal static object FromControl(string method, JsonElement p, Func<string, bool> workspaceOpen, Func<string, string, bool> surfaceIn, DateTimeOffset now)
    {
        string? Text(string key, int max, bool required = false)
        {
            var value = p.ValueKind == JsonValueKind.Object && p.TryGetProperty(key, out var raw) && raw.ValueKind != JsonValueKind.Null
                ? raw.ValueKind == JsonValueKind.String ? raw.GetString() : throw new ControlException("invalid_params", $"{key} must be a string.")
                : null;
            if (string.IsNullOrWhiteSpace(value)) return required ? throw new ControlException("invalid_params", $"{key} is required.") : null;
            return value.Length <= max ? value.Trim() : throw new ControlException("invalid_params", $"{key} is longer than {max} characters.");
        }
        string? State(string? fallback)
        {
            var state = Text("state", 32)?.ToLowerInvariant() ?? fallback;
            return state is null || States.Contains(state) ? state : throw new ControlException("invalid_params", $"Unknown state '{state}'.");
        }
        void CheckWorkspace(string? workspaceId, string? surfaceId)
        {
            if (workspaceId is not null && !workspaceOpen(workspaceId)) throw new ControlException("not_found", "Workspace not found", new { workspace_id = workspaceId });
            if (workspaceId is not null && surfaceId is not null && !surfaceIn(workspaceId, surfaceId))
                throw new ControlException("not_found", "Surface not found in workspace", new { workspace_id = workspaceId, surface_id = surfaceId });
        }
        switch (method)
        {
            case "agent.task.start":
            {
                var workspaceId = Text("workspace_id", 128, required: true)!;
                var surfaceId = Text("surface_id", 128);
                CheckWorkspace(workspaceId, surfaceId);
                var placement = Text("placement", 32) ?? "runs_with_parent";
                if (!Placements.Contains(placement)) throw new ControlException("invalid_params", $"Unknown placement '{placement}'.");
                return new { agent = Start(Text("agent_id", 128) ?? Guid.NewGuid().ToString().ToUpperInvariant(), Text("parent_id", 128), Text("host", 128, required: true)!,
                    Text("session", 512), Text("task", 2_048), Text("role", 256), Text("summary", 16_384), State("working")!, placement, workspaceId, surfaceId, now).Json() };
            }
            case "agent.task.update":
            {
                var workspaceId = Text("workspace_id", 128);
                var surfaceId = Text("surface_id", 128);
                var id = Text("agent_id", 128, required: true)!;
                CheckWorkspace(workspaceId ?? (surfaceId is null ? null : Find(id)?.WorkspaceId), surfaceId);
                return new { agent = Update(id, State(null), Text("session", 512), Text("task", 2_048), Text("role", 256), null, workspaceId, surfaceId, now).Json() };
            }
            case "agent.task.finish":
                return new { agent = Finish(Text("agent_id", 128, required: true)!, State("completed")!, Text("task", 2_048), Text("summary", 16_384), now).Json() };
            case "agent.task.finish_session":
            {
                var finished = FinishSession(Text("host", 128, required: true)!, Text("session", 512, required: true)!, State("cancelled")!, now);
                return new { agents = finished.Select(helper => helper.Json()).ToList(), count = finished.Count };
            }
            default: // agent.task.list
            {
                var workspaceId = Text("workspace_id", 128);
                CheckWorkspace(workspaceId, null);
                var parentId = Text("parent_id", 128);
                var includeFinished = !(p.ValueKind == JsonValueKind.Object && p.TryGetProperty("include_finished", out var flag) && flag.ValueKind == JsonValueKind.False);
                var listed = Records.Values
                    .Where(helper => (workspaceId is null || Same(helper.WorkspaceId, workspaceId)) && (parentId is null || helper.ParentId == parentId) && (includeFinished || !helper.Finished))
                    .OrderBy(helper => helper.StartedAt).ToList();
                return new { agents = listed.Select(helper => helper.Json()).ToList(), count = listed.Count };
            }
        }
    }
}
