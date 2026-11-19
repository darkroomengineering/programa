using System.Text.Json;

namespace Programa;

/// <summary>agent.spawn and agent.detection.classify, as on macOS (Sources/TerminalController+
/// AgentSupervision.swift, +AgentDetection.swift). A helper spawns in a workspace of its own nested
/// under its parent's, started in the parent's directory with the initial command and environment;
/// with needs_isolation, in a new git worktree of the parent's repository instead. Neither takes
/// focus. The helper is in the helpers registry (agent.task.list) from the start.</summary>
public sealed partial class MainWindow
{
    private async Task<object?> SpawnAgentAsync(JsonElement p)
    {
        string? Text(string key, int max, bool required = false)
        {
            var value = p.ValueKind == JsonValueKind.Object && p.TryGetProperty(key, out var raw) && raw.ValueKind != JsonValueKind.Null
                ? raw.ValueKind == JsonValueKind.String ? raw.GetString() : throw new ControlException("invalid_params", $"{key} must be a string.")
                : null;
            if (string.IsNullOrWhiteSpace(value)) return required ? throw new ControlException("invalid_params", $"{key} is required.") : null;
            return value.Length <= max ? value.Trim() : throw new ControlException("invalid_params", $"{key} is longer than {max} characters.");
        }
        var parentWorkspaceId = Text("parent_workspace_id", 128, required: true)!;
        var parentAgentId = Text("parent_agent_id", 128);
        var host = Text("host", 128) ?? "programa";
        var session = Text("session", 512);
        var task = Text("task", 2_048);
        var role = Text("role", 256);
        var initialCommand = Text("initial_command", 16_384);
        var environment = new Dictionary<string, string>(StringComparer.Ordinal);
        if (p.TryGetProperty("initial_env", out var rawEnvironment) && rawEnvironment.ValueKind != JsonValueKind.Null)
        {
            if (rawEnvironment.ValueKind != JsonValueKind.Object || rawEnvironment.EnumerateObject().Any(item => item.Value.ValueKind != JsonValueKind.String))
                throw new ControlException("invalid_params", "initial_env must contain string values");
            foreach (var item in rawEnvironment.EnumerateObject()) environment[item.Name] = item.Value.GetString()!;
        }
        var isolated = p.TryGetProperty("needs_isolation", out var rawIsolation) && rawIsolation.ValueKind switch
        {
            JsonValueKind.True => true,
            JsonValueKind.False or JsonValueKind.Null => false,
            _ => throw new ControlException("invalid_params", "needs_isolation must be a boolean."),
        };
        if (!isolated) return await OnUiThread(() => SpawnNested(parentWorkspaceId, parentAgentId, host, session, task, role, initialCommand, environment));

        var repository = Text("repository_path", 4_096);
        var branch = Text("branch", 512);
        var baseRef = Text("base", 4_096);
        var layout = Text("layout", 4_096);
        if (repository is null || branch is null)
            throw new ControlException("invalid_params", "repository_path and branch are required when needs_isolation is true", new { use_method = "worktree.create" });
        if (environment.Count > 0) throw new ControlException("invalid_params", "initial_env is not supported for a separate worktree helper");
        if (p.TryGetProperty("path", out _)) throw new ControlException("invalid_params", "agent.spawn uses Programa's configured worktree folder; omit path");

        var agentId = Guid.NewGuid().ToString().ToUpperInvariant();
        var parentDirectory = await OnUiThread(() =>
        {
            var parent = SpawnParent(parentWorkspaceId, parentAgentId);
            Helpers.Start(agentId, parentAgentId, host, session, task, role, null, "working", "separate_worktree", parent.Id, null, DateTimeOffset.UtcNow);
            return WorkspaceDirectory(parent);
        });
        try
        {
            string parentRepository, requestedRepository;
            try { (parentRepository, requestedRepository) = (Worktrees.RepoRoot((string)parentDirectory!), Worktrees.RepoRoot(repository)); }
            catch (Worktrees.GitException) { throw new ControlException("not_a_git_repo", "The parent workspace is not in that git repository"); }
            if (!Worktrees.SamePath(parentRepository, requestedRepository))
                throw new ControlException("repository_mismatch", "A helper worktree must use the parent workspace's repository", new { parent_repository = parentRepository });
            var created = JsonSerializer.SerializeToElement(await HandleWorktreeAsync("worktree.create",
                JsonSerializer.SerializeToElement(new { repo = parentRepository, branch, @base = baseRef, layout, initial_command = initialCommand })), ControlJson);
            var workspaceId = created.GetProperty("workspace_id").GetString()!;
            return await OnUiThread(() =>
            {
                var workspace = _snapshot.Workspaces.FirstOrDefault(item => item.Id == workspaceId)
                    ?? throw new ControlException("internal_error", "The worktree was created, but its workspace is unavailable", new { workspace_id = workspaceId });
                var surfaceId = workspace.SelectedPane?.SelectedSurfaceId;
                var helper = Helpers.Update(agentId, null, null, task ?? AutomaticHelperTitle(task, role, 1), null, null, workspace.Id, surfaceId, DateTimeOffset.UtcNow);
                var result = JsonSerializer.Deserialize<Dictionary<string, object?>>(created.GetRawText())!;
                result["agent_id"] = agentId;
                result["surface_id"] = surfaceId;
                result["focused"] = false;
                result["agent"] = helper.Json();
                return result;
            });
        }
        catch
        {
            await OnUiThread(() => { Helpers.Discard(agentId); return null; });
            throw;
        }
    }

    private static readonly JsonSerializerOptions ControlJson = new() { PropertyNamingPolicy = JsonNamingPolicy.SnakeCaseLower };

    private WorkspaceSnapshot SpawnParent(string parentWorkspaceId, string? parentAgentId)
    {
        var parent = _snapshot.Workspaces.FirstOrDefault(item => item.Id == parentWorkspaceId)
            ?? throw new ControlException("not_found", "Parent workspace not found", new { parent_workspace_id = parentWorkspaceId });
        if (parentAgentId is not null && (Helpers.Find(parentAgentId) is not { } parentHelper || !string.Equals(parentHelper.WorkspaceId, parentWorkspaceId, StringComparison.OrdinalIgnoreCase)))
            throw new ControlException("not_found", "Parent helper not found in the parent workspace", new { parent_agent_id = parentAgentId });
        return parent;
    }

    private object SpawnNested(string parentWorkspaceId, string? parentAgentId, string host, string? session, string? task, string? role, string? initialCommand, Dictionary<string, string> environment)
    {
        var parent = SpawnParent(parentWorkspaceId, parentAgentId);
        // Children nest one level deep: a helper of a nested workspace sits beside it.
        var nestUnder = parent.ParentId ?? parent.Id;
        var title = AutomaticHelperTitle(task, role, _snapshot.Workspaces.Count(item => item.ParentId == nestUnder) + 1);
        var agentId = Guid.NewGuid().ToString().ToUpperInvariant();
        Helpers.Start(agentId, parentAgentId, host, session, task ?? title, role, null, "working", "nested_workspace", parent.Id, null, DateTimeOffset.UtcNow);
        try
        {
            var (workspaceId, paneId, surfaceId) = (Id("workspace"), Id("pane"), Id("surface"));
            _pendingTerminals[surfaceId] = new TerminalSpec(WorkspaceDirectory(parent), initialCommand, environment.Count > 0 ? environment : null);
            CreateKeepingSelection(new { command = "create_workspace", workspace_id = workspaceId, pane_id = paneId, surface_id = surfaceId, session_id = Id("session") }, workspaceId, surfaceId, null, null);
            Apply(new { command = "rename_workspace", workspace_id = workspaceId, title });
            try { Apply(new { command = "set_workspace_parent", workspace_id = workspaceId, parent_id = nestUnder }); }
            catch (CoreCommandException) { }
            var helper = Helpers.Update(agentId, null, null, null, null, null, workspaceId, surfaceId, DateTimeOffset.UtcNow);
            return new { agent_id = agentId, workspace_id = workspaceId, pane_id = paneId, surface_id = surfaceId, focused = false, agent = helper.Json() };
        }
        catch
        {
            Helpers.Discard(agentId);
            throw;
        }
    }

    /// <summary>The task's first line, else the role, else "Helper N", at most 80 characters, as macOS.</summary>
    internal static string AutomaticHelperTitle(string? task, string? role, int siblingNumber)
    {
        var source = task?.Split('\n', 2)[0] ?? role ?? string.Format(Localizer.Get("HelperNumbered"), siblingNumber);
        return source.Length > 80 ? source[..80] : source;
    }

    /// <summary>The workspace's directory: its focused terminal's, else any of its terminals', else home.</summary>
    private string WorkspaceDirectory(WorkspaceSnapshot workspace) =>
        (workspace.SelectedPane?.SelectedSurfaceId is { } focused ? _terminals.GetValueOrDefault(focused)?.WorkingDirectory ?? _restore.GetValueOrDefault(focused)?.Cwd : null)
        ?? TerminalsOf(workspace).Select(terminal => terminal.WorkingDirectory).FirstOrDefault(directory => directory is not null)
        ?? Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);

    private object DetectionClassifyFromControl(JsonElement p)
    {
        var (workspace, surface, terminal) = TerminalTarget(p);
        terminal.EnsureStarted();
        var result = AgentDetection.Classify(terminal.OutputText(ReadLines(p)), Text(p, "agent")?.Trim() is { Length: > 0 } agent ? agent : null);
        result["workspace_id"] = workspace.Id;
        result["surface_id"] = surface;
        return result;
    }
}
