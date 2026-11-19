using System.Text.Json;

namespace Programa;

/// <summary>
/// The control pipe's methods: the Windows subset of the macOS v2 API (contracts/v2/methods.json),
/// with the same names and parameter names, used by the bundled `programa` CLI and agent hooks.
/// As on macOS, a command only moves your focus when that is its point (workspace.select,
/// surface.focus); creating workspaces, tabs and splits leaves the selection where it was.
/// </summary>
public sealed partial class MainWindow
{
    private static readonly string[] ControlMethods =
    [
        "system.ping", "system.identify", "system.capabilities",
        "workspace.list", "workspace.current", "workspace.create", "workspace.select", "workspace.close", "workspace.rename",
        "surface.list", "surface.current", "surface.create", "surface.split", "surface.focus", "surface.close",
        "surface.send_text", "surface.read_text", "surface.report_agent_state",
        "notification.create", "notification.list", "notification.clear",
        "ports.list", "ports.stop", "storage.scan", "storage.clean",
        "worktree.create", "worktree.open", "worktree.remove", "worktree.list",
        "layout.save", "layout.apply", "layout.list",
        "agent.task.start", "agent.task.update", "agent.task.finish", "agent.task.finish_session", "agent.task.list",
        "surface.resume_agent", "workspace.action", "agent.event", "agent.needs_input", "surface.wait", "agent.prompt", "subscribe", "unsubscribe", "routes.list",
        "markdown.open", "review.open", "review.refresh", "review.comment.add", "review.comment.remove", "review.comment.list", "review.send_comments",
        "window.list", "window.current", "window.create", "window.focus", "window.close", "workspace.move_to_window", "surface.move",
        .. SidebarMetadata.Methods, "workspace.sidebar_state", "workspace.reset_sidebar",
        .. PaneControl.Methods, .. SurfaceActionControl.Methods,
        "snapshot.list", "snapshot.restore", "agent.spawn", "agent.detection.list", "agent.detection.classify",
    ];

    /// <summary>Runs one request routed to this window (<see cref="WindowRegistry"/> owns the pipe) on
    /// the UI thread, which owns the core and the terminals; worktree and review methods run git on a
    /// worker thread first (MainWindow.Worktrees.cs, MainWindow.Review.cs).</summary>
    internal Task<object?> HandleControlAsync(string method, JsonElement parameters) =>
        method.StartsWith("worktree.", StringComparison.Ordinal) ? Task.Run(() => HandleWorktreeAsync(method, parameters))
            : method.StartsWith("review.", StringComparison.Ordinal) ? Task.Run(() => HandleReviewAsync(method, parameters))
            // Already on the UI thread (WindowRegistry routes there); these await without blocking it.
            : method == "surface.wait" ? WaitFromControlAsync(parameters)
            : method == "agent.prompt" ? PromptFromControlAsync(parameters)
            // A helper in its own worktree runs git first, off the UI thread.
            : method == "agent.spawn" ? Task.Run(() => SpawnAgentAsync(parameters))
            : OnUiThread(() => HandleControl(method, parameters));

    private Task<object?> OnUiThread(Func<object?> work)
    {
        var done = new TaskCompletionSource<object?>(TaskCreationOptions.RunContinuationsAsynchronously);
        var queued = DispatcherQueue.TryEnqueue(() =>
        {
            try { done.SetResult(work()); }
            catch (CoreCommandException error) { done.SetException(new ControlException(error.Code == "not_found" ? "not_found" : "invalid_params", error.Message)); }
            catch (Exception error) { done.SetException(error); }
        });
        if (!queued) done.SetException(new ControlException("unavailable", "Programa is closing."));
        return done.Task;
    }

    private object? HandleControl(string method, JsonElement p) => method switch
    {
        "system.ping" => new { pong = true },
        "system.capabilities" => new { platform = "windows", methods = ControlMethods },
        "system.identify" => Identify(p),
        "workspace.list" => new { workspaces = DescribeWorkspaces() },
        "workspace.current" => SelectedWorkspace() is { } current ? new { workspace_id = current.Id } : throw NotFound("workspace"),
        "workspace.create" => CreateWorkspaceFromControl(p),
        "workspace.select" => Run(() => Apply(new { command = "select_workspace", workspace_id = Required(p, "workspace_id") })),
        "workspace.close" => Run(() => Apply(new { command = "close_workspace", workspace_id = WorkspaceTarget(p).Id })),
        "workspace.rename" => Run(() => Apply(new { command = "rename_workspace", workspace_id = WorkspaceTarget(p).Id, title = Required(p, "title") })),
        "surface.list" => new { surfaces = DescribeWorkspaces().Where(workspace => Text(p, "workspace_id") is not { } id || workspace.Id == id).SelectMany(workspace => workspace.Surfaces) },
        "surface.current" => SurfaceTarget(default) is var (workspace, pane, surface) ? new { surface_id = surface, pane_id = pane.Id, workspace_id = workspace.Id } : null,
        "surface.create" => CreateSurfaceFromControl(p),
        "surface.split" => SplitFromControl(p),
        "surface.focus" => Run(() => FocusSurfaceFromControl(p)),
        "surface.close" => Run(() =>
        {
            var (workspace, pane, surface) = SurfaceTarget(p);
            Apply(new { command = "close_surface", workspace_id = workspace.Id, pane_id = pane.Id, surface_id = surface });
        }),
        "surface.send_text" => Run(() =>
        {
            var (workspace, _, surface) = SurfaceTarget(p);
            TerminalFor(workspace.Id, surface).SendText(Required(p, "text"));
        }),
        "surface.read_text" => ReadTextFromControl(p),
        "surface.report_agent_state" => Run(() => ReportAgentStateFromControl(p)),
        "notification.create" => Run(() => NotifyFromControl(p)),
        "notification.list" => new
        {
            notifications = _notifications.Items.Select(item => new
            {
                id = item.Id, workspace_id = item.WorkspaceId, surface_id = item.SurfaceId, is_read = item.IsRead,
                title = item.Title, subtitle = (string?)null, body = item.Body,
            }),
        },
        "notification.clear" => Run(() =>
        {
            if (Text(p, "workspace_id") is { } workspaceId) _notifications.Clear(workspaceId);
            else _notifications.Clear();
        }),
        "ports.stop" => StopPortFromControl(p),
        "layout.save" or "layout.apply" or "layout.list" => LayoutFromControl(method, p),
        "markdown.open" => OpenMarkdownFromControl(p),
        "surface.resume_agent" => ResumeAgentFromControl(p),
        "agent.event" => AgentEventFromControl(p),
        "agent.needs_input" => NeedsInputFromControl(p),
        "workspace.action" => WorkspaceActionFromControl(p),
        "workspace.sidebar_state" or "workspace.reset_sidebar" => SidebarFromControl(method, p),
        "agent.detection.list" => AgentDetection.List(),
        "agent.detection.classify" => DetectionClassifyFromControl(p),
        _ when SidebarMetadata.Methods.Contains(method) => SidebarFromControl(method, p),
        _ when PaneControl.Methods.Contains(method) => PaneFromControl(method, p),
        _ when SurfaceActionControl.Methods.Contains(method) => SurfaceActionFromControl(method, p),
        _ => throw new ControlException("method_not_found", $"{method} is not available on Windows yet."),
    };

    private static object Run(Action action)
    {
        action();
        return new { };
    }

    private static string? Text(JsonElement p, string name) =>
        p.ValueKind == JsonValueKind.Object && p.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.String ? value.GetString() : null;

    private static int? Number(JsonElement p, string name) =>
        p.ValueKind == JsonValueKind.Object && p.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.Number && value.TryGetInt32(out var number) ? number : null;

    private static bool Flag(JsonElement p, string name) =>
        p.ValueKind == JsonValueKind.Object && p.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.True;

    private static string Required(JsonElement p, string name) =>
        Text(p, name) is { Length: > 0 } value ? value : throw new ControlException("invalid_params", $"{name} is required.");

    private static ControlException NotFound(string what, string? id = null) =>
        new("not_found", id is null ? $"There is no {what}." : $"{what} '{id}' was not found.");

    private WorkspaceSnapshot WorkspaceTarget(JsonElement p) => Text(p, "workspace_id") is { } id
        ? _snapshot.Workspaces.FirstOrDefault(workspace => workspace.Id == id) ?? throw NotFound("workspace", id)
        : SelectedWorkspace() ?? throw NotFound("workspace");

    /// <summary>The named surface, or the focused one when none is named.</summary>
    private (WorkspaceSnapshot Workspace, PaneSnapshot Pane, string SurfaceId) SurfaceTarget(JsonElement p)
    {
        if (Text(p, "surface_id") is { } id)
        {
            foreach (var workspace in _snapshot.Workspaces)
                foreach (var pane in workspace.Panes)
                    if (pane.Surfaces.Any(surface => surface.Id == id)) return (workspace, pane, id);
            throw NotFound("surface", id);
        }
        var selected = SelectedWorkspace() ?? throw NotFound("workspace");
        var selectedPane = selected.SelectedPane ?? throw NotFound("pane");
        return (selected, selectedPane, selectedPane.SelectedSurfaceId);
    }

    private object Identify(JsonElement p)
    {
        var (workspace, pane, surface) = SurfaceTarget(p);
        return new { surface_id = surface, pane_id = pane.Id, workspace_id = workspace.Id, app = "programa", platform = "windows", version = BuildIdentity.Value };
    }

    private sealed record DescribedSurface(string Id, string PaneId, string WorkspaceId, string Title, string? Cwd, bool Selected);
    private sealed record DescribedWorkspace(string Id, int Index, string Title, bool Selected, IReadOnlyList<DescribedSurface> Surfaces);

    private List<DescribedWorkspace> DescribeWorkspaces() => _snapshot.Workspaces.Select((workspace, index) => new DescribedWorkspace(
        workspace.Id,
        index + 1,
        _sidebarRows.GetValueOrDefault(workspace.Id)?.Title.Text ?? workspace.Title ?? string.Format(Localizer.Get("WorkspaceDefaultTitle"), index + 1),
        workspace.Id == SelectedWorkspace()?.Id,
        workspace.Panes.SelectMany(pane => pane.Surfaces.Select(surface =>
        {
            var terminal = _terminals.GetValueOrDefault(surface.Id);
            // A markdown panel shows as its file: the name as title, the path as directory.
            var panel = _panels.GetValueOrDefault(surface.Id);
            var markdown = (panel as MarkdownPanel)?.FilePath ?? _restorePanels.GetValueOrDefault(surface.Id);
            return new DescribedSurface(
                surface.Id, pane.Id, workspace.Id,
                terminal is not null ? TabTitle(terminal) : surface.Title ?? panel?.Title ?? (markdown is not null ? Path.GetFileName(markdown) : Localizer.Get("Terminal")),
                terminal?.WorkingDirectory ?? markdown ?? _restore.GetValueOrDefault(surface.Id)?.Cwd,
                workspace.SelectedPaneId == pane.Id && pane.SelectedSurfaceId == surface.Id);
        })).ToList())).ToList();

    /// <summary>Runs a creating command, then puts the user's selection back and starts the new
    /// terminal, which may be in a workspace that is not on screen.</summary>
    private void CreateKeepingSelection(object command, string workspaceId, string surfaceId, string? directory, string? initialCommand)
    {
        var previous = SelectedWorkspace();
        var previousPane = previous?.SelectedPane;
        // A workspace not on screen keeps its own selected pane and tab too, as on macOS.
        var target = _snapshot.Workspaces.FirstOrDefault(workspace => workspace.Id == workspaceId && workspace.Id != previous?.Id)?.SelectedPane;
        _snapshot = Dispatch(command);
        if (target is not null && _snapshot.Workspaces.Any(workspace => workspace.Id == workspaceId && workspace.Panes.Any(pane => pane.Id == target.Id)))
            _snapshot = Dispatch(new { command = "select_surface", workspace_id = workspaceId, pane_id = target.Id, surface_id = target.SelectedSurfaceId });
        if (previous is not null && previousPane is not null && _snapshot.Workspaces.Any(workspace => workspace.Id == previous.Id))
            _snapshot = Dispatch(new { command = "select_surface", workspace_id = previous.Id, pane_id = previousPane.Id, surface_id = previousPane.SelectedSurfaceId });
        // Before the projection, so a terminal the projection builds (a visible split) takes them.
        _nextTerminalDirectory = directory;
        _nextTerminalCommand = initialCommand;
        ProjectSnapshot();
        TerminalFor(workspaceId, surfaceId).EnsureStarted();
    }

    private object CreateWorkspaceFromControl(JsonElement p)
    {
        var workspaceId = Id("workspace");
        var surfaceId = Id("surface");
        CreateKeepingSelection(new { command = "create_workspace", workspace_id = workspaceId, pane_id = Id("pane"), surface_id = surfaceId, session_id = Id("session") },
            workspaceId, surfaceId, Text(p, "cwd"), Text(p, "initial_command"));
        if (Text(p, "title") is { Length: > 0 } title) Apply(new { command = "rename_workspace", workspace_id = workspaceId, title });
        return new { workspace_id = workspaceId, surface_id = surfaceId };
    }

    private object CreateSurfaceFromControl(JsonElement p)
    {
        var workspace = WorkspaceTarget(p);
        var paneId = Text(p, "pane_id") ?? workspace.SelectedPaneId;
        if (workspace.Panes.All(pane => pane.Id != paneId)) throw NotFound("pane", paneId);
        var surfaceId = Id("surface");
        var directory = Text(p, "cwd") ?? _terminals.GetValueOrDefault(workspace.Panes.First(pane => pane.Id == paneId).SelectedSurfaceId)?.WorkingDirectory;
        CreateKeepingSelection(new { command = "create_surface", workspace_id = workspace.Id, pane_id = paneId, surface_id = surfaceId, session_id = Id("session") },
            workspace.Id, surfaceId, directory, Text(p, "initial_command"));
        return new { surface_id = surfaceId, pane_id = paneId, workspace_id = workspace.Id };
    }

    private object SplitFromControl(JsonElement p)
    {
        var (workspace, pane, surface) = SurfaceTarget(p);
        return Split(workspace, pane, surface, Text(p, "direction") ?? "right", Text(p, "cwd"), Text(p, "initial_command"));
    }

    /// <summary>A new terminal beside <paramref name="surface"/>'s pane; left and up put it first. The selection stays.</summary>
    private object Split(WorkspaceSnapshot workspace, PaneSnapshot pane, string surface, string requested, string? cwd, string? initialCommand)
    {
        var (direction, insertFirst) = requested.ToLowerInvariant() switch
        {
            "right" or "vertical" => ("vertical", false),
            "left" => ("vertical", true),
            "down" or "horizontal" => ("horizontal", false),
            "up" => ("horizontal", true),
            var other => throw new ControlException("invalid_params", $"direction '{other}' is not left, right, up or down."),
        };
        var newPaneId = Id("pane");
        var surfaceId = Id("surface");
        var directory = cwd ?? _terminals.GetValueOrDefault(surface)?.WorkingDirectory;
        CreateKeepingSelection(new { command = "split_pane", workspace_id = workspace.Id, pane_id = pane.Id, split_id = Id("split"), new_pane_id = newPaneId, new_surface_id = surfaceId, session_id = Id("session"), direction, ratio = 0.5, insert_first = insertFirst },
            workspace.Id, surfaceId, directory, initialCommand);
        return new { surface_id = surfaceId, pane_id = newPaneId, workspace_id = workspace.Id, window_id = WindowId, type = "terminal" };
    }

    private void FocusSurfaceFromControl(JsonElement p)
    {
        var (workspace, pane, surface) = SurfaceTarget(p);
        Apply(new { command = "select_surface", workspace_id = workspace.Id, pane_id = pane.Id, surface_id = surface });
        if (_terminals.TryGetValue(surface, out var terminal)) terminal.FocusTerminal();
    }

    private object ReadTextFromControl(JsonElement p)
    {
        var (workspace, _, surface) = SurfaceTarget(p);
        var terminal = TerminalFor(workspace.Id, surface);
        terminal.EnsureStarted();
        var text = terminal.OutputText(ReadLines(p));
        // The fingerprint surface.send_if_unchanged compares, as on macOS.
        return new { text, fingerprint = Fingerprint(text), workspace_id = workspace.Id, surface_id = surface, window_id = WindowId };
    }

    private static int ReadLines(JsonElement p) => Math.Clamp(Number(p, "lines") ?? (Flag(p, "scrollback") ? 200 : 50), 1, 10_000);

    internal static string Fingerprint(string text) =>
        Convert.ToHexStringLower(System.Security.Cryptography.SHA256.HashData(System.Text.Encoding.UTF8.GetBytes(text)));

    private void ReportAgentStateFromControl(JsonElement p)
    {
        var state = Required(p, "state");
        if (state is not ("working" or "blocked" or "idle" or "done" or "error" or "clear"))
            throw new ControlException("invalid_params", $"state '{state}' is not working, blocked, idle, done, error or clear.");
        var (workspace, _, surface) = SurfaceTarget(p);
        // The badge names the agent (provider); a source other than hooks or inferred names it too, as before.
        var app = Text(p, "provider") ?? (Text(p, "source") is { } source && source is not ("hooks" or "inferred") ? source : null);
        TerminalFor(workspace.Id, surface).ReportHookState(state == "clear" ? null : state, app, Text(p, "session_id"), Flag(p, "route_only"), Flag(p, "resumed"));
    }

    private void NotifyFromControl(JsonElement p)
    {
        var title = Required(p, "title");
        var body = string.Join(" — ", new[] { Text(p, "subtitle"), Text(p, "body") }.Where(part => !string.IsNullOrEmpty(part)));
        var (workspace, _, surface) = Text(p, "surface_id") is null && Text(p, "workspace_id") is { } workspaceId
            ? (WorkspaceTarget(p), null!, WorkspaceTarget(p).SelectedPane?.SelectedSurfaceId ?? throw NotFound("surface"))
            : SurfaceTarget(p);
        // Posted either way, but a terminal you are looking at gets no toast and stays read.
        var looking = IsLookingAt(surface);
        _notifications.Post(workspace.Id, surface, title, body, toast: !looking);
        if (looking) _notifications.MarkRead(new HashSet<string>(StringComparer.Ordinal) { surface });
    }
}
