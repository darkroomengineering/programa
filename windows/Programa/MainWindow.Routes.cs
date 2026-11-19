using System.Globalization;
using System.Text.Json;

namespace Programa;

/// <summary>This window's side of event routes (RouteEngine): agent state and needs_input events from
/// its terminals, with the fields only routes get (cwd, git_branch, worktree), and the notifications
/// and review panels routes open here.</summary>
public sealed partial class MainWindow
{
    private readonly HashSet<string> _routeReviewsOpening = new(StringComparer.Ordinal);

    private void OnRouteTransition(TerminalView terminal, TerminalView.RouteTransition transition)
    {
        var fields = AgentFields(terminal, $"agent/{terminal.SurfaceId}/state/{transition.State ?? "none"}");
        Put(fields, "state", transition.State);
        Put(fields, "previous_state", transition.Previous);
        Put(fields, "source", transition.Source);
        if (transition.Source == "program" && terminal.ProgramStatus is { } record)
        {
            Put(fields, "program_status.state", record.State);
            Put(fields, "program_status.kind", record.Kind);
            Put(fields, "program_status.progress", record.Progress?.ToString(CultureInfo.InvariantCulture));
            Put(fields, "program_status.app", record.App);
            Put(fields, "program_status.has_message", record.Msg is { Length: > 0 } ? "true" : "false");
        }
        RouteEngine.Fire(new RouteEvent(fields["topic"], fields, terminal.WorkspaceId, terminal.SurfaceId, transition.Trusted, transition.SessionNamed, transition.First, transition.Source));
    }

    /// <summary>The fields every agent event has: topic, ids, time, and the surface's place.</summary>
    private Dictionary<string, string> AgentFields(TerminalView terminal, string topic)
    {
        var fields = new Dictionary<string, string>(StringComparer.Ordinal) { ["topic"] = topic, ["surface_id"] = terminal.SurfaceId, ["ts"] = EventHub.Now.ToString(CultureInfo.InvariantCulture) };
        Put(fields, "workspace_id", terminal.WorkspaceId);
        // A reported directory that exists, as the shell last reported it (OSC 7).
        if (terminal.Cwd is { } cwd && Path.IsPathRooted(cwd) && Directory.Exists(cwd))
        {
            fields["cwd"] = Path.GetFullPath(cwd);
            fields["worktree"] = IsLinkedWorktree(cwd) ? "true" : "false";
        }
        else fields["worktree"] = "false";
        Put(fields, "git_branch", _branches.GetValueOrDefault(terminal.SurfaceId));
        return fields;
    }

    private static void Put(Dictionary<string, string> fields, string name, string? value)
    {
        if (!string.IsNullOrEmpty(value)) fields[name] = value;
    }

    /// <summary>Whether a directory is in a linked git worktree (its top has a .git file, not a folder).
    /// ponytail: macOS marks workspaces worktree.create or worktree.open made; a linked worktree is the same tree.</summary>
    private static bool IsLinkedWorktree(string directory)
    {
        for (var folder = new DirectoryInfo(directory); folder is not null; folder = folder.Parent)
        {
            var git = Path.Combine(folder.FullName, ".git");
            if (File.Exists(git)) return true;
            if (Directory.Exists(git)) return false;
        }
        return false;
    }

    /// <summary>needs_input for routes: returns whether the built-in banner gives way. A question's does
    /// when a notify route matches it; a permission's only when a notify route fired for this very call.</summary>
    private bool RouteNeedsInput(TerminalView terminal, JsonElement p, string? kind, string? provider, string title, string? subtitle, string? body)
    {
        var fields = AgentFields(terminal, $"agent/{terminal.SurfaceId}/needs_input/{kind ?? "unknown"}");
        Put(fields, "kind", kind);
        Put(fields, "provider", provider);
        Put(fields, "title", title);
        Put(fields, "subtitle", subtitle);
        Put(fields, "body", body);
        var (matched, fired) = RouteEngine.Fire(new RouteEvent(fields["topic"], fields, terminal.WorkspaceId, terminal.SurfaceId, Trusted: true, SessionNamed: Text(p, "session_id") is not null, Source: "hooks"));
        return kind == "question" ? matched : fired;
    }

    /// <summary>A notify route's notification for a workspace of this window; false when it is gone.</summary>
    internal bool PostRouteNotification(string workspaceId, string? surfaceId, string title, string body)
    {
        if (_snapshot.Workspaces.FirstOrDefault(workspace => workspace.Id == workspaceId) is not { } workspace) return false;
        var surface = surfaceId is not null && OwnsSurface(surfaceId) ? surfaceId : workspace.SelectedPane?.SelectedSurfaceId;
        if (surface is null) return false;
        var looking = IsLookingAt(surface);
        _notifications.Post(workspaceId, surface, title, body, toast: !looking);
        if (looking) _notifications.MarkRead(new HashSet<string>(StringComparer.Ordinal) { surface });
        return true;
    }

    /// <summary>A review route: the review panel beside the event's surface, without focus. Nothing
    /// happens when the workspace already shows one or a route is opening one there.</summary>
    internal async Task OpenReviewForRoute(string workspaceId, string? surfaceId, string mode, string? baseBranch)
    {
        if (_snapshot.Workspaces.FirstOrDefault(workspace => workspace.Id == workspaceId) is not { } workspace) return;
        var surfaces = workspace.Panes.SelectMany(pane => pane.Surfaces).Select(surface => surface.Id).ToList();
        if (surfaces.Any(id => _panels.GetValueOrDefault(id) is ReviewPanel || _restoreReviews.ContainsKey(id)) || !_routeReviewsOpening.Add(workspaceId)) return;
        try
        {
            var source = surfaceId is not null && surfaces.Contains(surfaceId) ? surfaceId : workspace.SelectedPane?.SelectedSurfaceId;
            var request = JsonSerializer.SerializeToElement(new { workspace_id = workspaceId, surface_id = source, mode, base_branch = baseBranch, focus = false });
            await HandleReviewAsync("review.open", request);
        }
        finally { _routeReviewsOpening.Remove(workspaceId); }
    }
}
