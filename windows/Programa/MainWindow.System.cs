using System.Diagnostics;
using System.Text;
using System.Text.Json;

namespace Programa;

/// <summary>Its own type, so MainWindow's static method list can read it whatever the file order.</summary>
internal static class SystemControl
{
    internal static readonly string[] Methods =
    [
        "system.tree", "shortcuts.list", "settings.open", "app.reload_config",
        "notification.create_for_surface", "notification.create_for_target", "feedback.open", "feedback.submit",
    ];
}

/// <summary>App introspection over the control pipe, as on macOS (Sources/TerminalController+System.swift,
/// +Notification.swift): system.tree's window nodes (WindowRegistry joins the windows), the shortcuts as
/// resolved, Settings, a configuration reload, notifications for a given tab, and feedback.</summary>
public sealed partial class MainWindow
{
    private object? SystemFromControl(string method, JsonElement p) => method switch
    {
        "shortcuts.list" => new
        {
            shortcuts = _shortcuts.Values.OrderBy(item => item.Key, StringComparer.Ordinal)
                .Select(item => new { id = item.Key, display_string = ShortcutSettings.Display(item.Value) }).ToList(),
        },
        "settings.open" => OpenSettingsFromControl(p),
        "notification.create_for_surface" or "notification.create_for_target" => NotifySurfaceFromControl(method, p),
        "feedback.open" => OpenFeedback(),
        "feedback.submit" => throw new ControlException("feedback_disabled", "feedback submission is disabled; report issues at https://github.com/darkroomengineering/programa/issues"),
        _ => throw new ControlException("method_not_found", $"{method} is not available on Windows yet."),
    };

    private object OpenSettingsFromControl(JsonElement p)
    {
        var target = Text(p, "target");
        if (target is not (null or "keyboardShortcuts")) throw new ControlException("invalid_params", "Unknown settings target", new { target });
        _ = ShowSettingsAsync(target);
        return new { opened = true, target = target ?? "general" };
    }

    private static object OpenFeedback()
    {
        Process.Start(new ProcessStartInfo("https://github.com/darkroomengineering/programa/issues") { UseShellExecute = true });
        return new { opened = true };
    }

    /// <summary>A notification for a given tab; its title gets the tab's name after it when the tab has one, as on macOS.</summary>
    private object NotifySurfaceFromControl(string method, JsonElement p)
    {
        foreach (var (key, limit) in new[] { ("title", 16 * 1024), ("subtitle", 16 * 1024), ("body", 64 * 1024) })
            if (Text(p, key) is { } value && Encoding.UTF8.GetByteCount(value) > limit)
                throw new ControlException("invalid_params", $"{key} exceeds the UTF-8 limit of {limit} bytes");
        var surfaceId = Text(p, "surface_id") ?? throw new ControlException("invalid_params", "surface_id is required.");
        if (method == "notification.create_for_target" && Text(p, "workspace_id") is null) throw new ControlException("invalid_params", "workspace_id is required.");
        var workspace = Text(p, "workspace_id") is { } workspaceId
            ? _snapshot.Workspaces.FirstOrDefault(item => item.Id == workspaceId) ?? throw new ControlException("not_found", "Workspace not found", new { workspace_id = workspaceId })
            : _snapshot.Workspaces.FirstOrDefault(item => item.Panes.Any(pane => pane.Surfaces.Any(surface => surface.Id == surfaceId)))
                ?? throw new ControlException("not_found", "Surface not found", new { surface_id = surfaceId });
        var surface = workspace.Panes.SelectMany(pane => pane.Surfaces).FirstOrDefault(item => item.Id == surfaceId)
            ?? throw new ControlException("not_found", "Surface not found", new { surface_id = surfaceId });
        var title = Text(p, "title") ?? Localizer.Get("NotificationDefaultTitle");
        if (surface.Title is { Length: > 0 } custom) title = $"{title} — {custom}";
        var body = string.Join(" — ", new[] { Text(p, "subtitle"), Text(p, "body") }.Where(part => !string.IsNullOrEmpty(part)));
        var looking = IsLookingAt(surfaceId);
        _notifications.Post(workspace.Id, surfaceId, title, body, toast: !looking);
        if (looking) _notifications.MarkRead(new HashSet<string>(StringComparer.Ordinal) { surfaceId });
        return new { workspace_id = workspace.Id, surface_id = surfaceId, window_id = WindowId };
    }

    /// <summary>Where this window's focus is: its window, workspace, pane and tab.</summary>
    internal Dictionary<string, object?> TreeFocus()
    {
        var focus = new Dictionary<string, object?> { ["window_id"] = WindowId };
        if (SelectedWorkspace() is not { } workspace) return focus;
        var surfaceId = workspace.SelectedPane?.SelectedSurfaceId;
        focus["workspace_id"] = workspace.Id;
        focus["pane_id"] = workspace.SelectedPaneId;
        focus["surface_id"] = focus["tab_id"] = surfaceId;
        focus["surface_type"] = surfaceId is null ? null : SurfaceType(surfaceId);
        return focus;
    }

    /// <summary>A calling terminal's place, when it is in this window.</summary>
    internal Dictionary<string, object?>? TreeCaller(string workspaceId, string? surfaceId)
    {
        if (_snapshot.Workspaces.FirstOrDefault(item => item.Id == workspaceId) is not { } workspace) return null;
        var pane = surfaceId is null ? null : workspace.Panes.FirstOrDefault(item => item.Surfaces.Any(surface => surface.Id == surfaceId));
        return new Dictionary<string, object?>
        {
            ["window_id"] = WindowId, ["workspace_id"] = workspace.Id, ["surface_id"] = pane is null ? null : surfaceId, ["tab_id"] = pane is null ? null : surfaceId,
            ["surface_type"] = pane is null ? null : SurfaceType(surfaceId!), ["pane_id"] = pane?.Id,
        };
    }

    /// <summary>system.tree's node for this window, with every workspace or only <paramref name="onlyWorkspace"/>.</summary>
    internal object TreeWindow(int index, bool key, string? onlyWorkspace)
    {
        var titles = DescribeWorkspaces().ToDictionary(item => item.Id, item => item.Surfaces.ToDictionary(surface => surface.Id, surface => surface.Title), StringComparer.Ordinal);
        var nodes = _snapshot.Workspaces.Select((workspace, at) => (Workspace: workspace, Index: at))
            .Where(item => onlyWorkspace is null || item.Workspace.Id == onlyWorkspace)
            .Select(item => TreeWorkspace(item.Workspace, item.Index, titles[item.Workspace.Id])).ToList();
        return new
        {
            id = WindowId, index, key, visible = AppWindow.IsVisible, workspace_count = nodes.Count,
            selected_workspace_id = _snapshot.SelectedWorkspaceId, workspaces = nodes,
        };
    }

    private object TreeWorkspace(WorkspaceSnapshot workspace, int index, Dictionary<string, string> titles)
    {
        var helpers = Helpers.Of(workspace.Id).Concat(Helpers.InWorkspace(workspace.Id)).DistinctBy(helper => helper.Id).ToList();
        var focusedSurface = workspace.SelectedPane?.SelectedSurfaceId;
        static object? Pr(ReportedPullRequest? pr) => pr is null ? null : new { number = pr.Number, label = pr.Label, url = pr.Url, status = pr.State, branch = pr.Branch, checks = pr.Checks };
        var pullRequest = Pr(PullRequestFor(workspace));
        var states = TerminalsOf(workspace).Select(terminal => terminal.AgentState).Where(state => state.State is not null).ToList();
        var worst = states.OrderBy(state => state.State switch { "blocked" => 0, "working" => 1, _ => 2 }).FirstOrDefault();
        var order = 0;
        var panes = PaneGeometry.Panes(workspace.Layout).Select((paneId, paneIndex) =>
        {
            var pane = PaneIn(workspace, paneId);
            return new
            {
                id = pane.Id, index = paneIndex, focused = pane.Id == workspace.SelectedPaneId,
                surface_ids = pane.Surfaces.Select(surface => surface.Id).ToList(), selected_surface_id = pane.SelectedSurfaceId, surface_count = pane.Surfaces.Count,
                surfaces = pane.Surfaces.Select((surface, inPane) =>
                {
                    var terminal = _terminals.GetValueOrDefault(surface.Id);
                    var (state, source) = terminal?.AgentState ?? (null, null);
                    return new
                    {
                        id = surface.Id, index = order++, type = SurfaceType(surface.Id), title = titles.GetValueOrDefault(surface.Id) ?? string.Empty,
                        focused = surface.Id == focusedSurface, selected = surface.Id == pane.SelectedSurfaceId, selected_in_pane = surface.Id == pane.SelectedSurfaceId,
                        pane_id = pane.Id, index_in_pane = inPane, tty = _ttyNames.GetValueOrDefault(surface.Id),
                        current_directory = terminal?.WorkingDirectory ?? _restore.GetValueOrDefault(surface.Id)?.Cwd ?? _restorePanels.GetValueOrDefault(surface.Id),
                        branch = _branches.GetValueOrDefault(surface.Id), agent_state = state, agent_state_source = source, shell_state = _shellStates.GetValueOrDefault(surface.Id),
                        program_status = terminal?.ProgramStatusJson,
                        helpers = helpers.Where(helper => helper.SurfaceId == surface.Id).Select(helper => helper.Json()).ToList(),
                        pull_request = _reportedPullRequests.TryGetValue(surface.Id, out var reported) ? Pr(reported) : pullRequest,
                    };
                }).ToList(),
            };
        }).ToList();
        return new
        {
            id = workspace.Id, index, title = WorkspaceTitle(workspace), description = workspace.Description, selected = workspace.Id == _snapshot.SelectedWorkspaceId,
            pinned = workspace.Pinned, current_directory = WorkspaceDirectory(workspace),
            branch = focusedSurface is null ? null : _branches.GetValueOrDefault(focusedSurface),
            pull_request = pullRequest, worktree_parent_workspace_id = workspace.ParentId, worktree_folder_id = (string?)null, worktree_folder_repo_root = (string?)null,
            is_worktree_folder = _snapshot.Workspaces.Any(item => item.ParentId == workspace.Id), agent_parent_workspace_id = (string?)null,
            agent_state = worst.State, agent_state_source = worst.Source,
            helper_outcomes = helpers.Where(helper => helper.Finished).GroupBy(helper => helper.State).ToDictionary(group => group.Key, group => group.Count()),
            helpers = helpers.Select(helper => helper.Json()).ToList(), helper_count = helpers.Count, panes,
        };
    }
}
