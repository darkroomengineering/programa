using System.Text;
using System.Text.Json;

namespace Programa;

/// <summary>Its own type, so MainWindow's static method list can read it whatever the file order.</summary>
internal static class TelemetryControl
{
    internal static readonly string[] Methods =
    [
        "surface.report_pwd", "surface.report_shell_state", "surface.report_git_branch", "surface.clear_git_branch",
        "surface.report_pr", "surface.clear_pr", "surface.report_ports", "surface.clear_ports", "surface.ports_kick",
        "surface.report_tty", "surface.resolve_tty", "surface.clear_agent_state",
    ];

    /// <summary>A tty's name as compared: trimmed, the last path component, "not a tty" none (macOS v2NormalizedTTYName).</summary>
    internal static string? NormalizedTty(string? raw)
    {
        var trimmed = raw?.Trim();
        if (string.IsNullOrEmpty(trimmed) || trimmed == "not a tty") return null;
        var last = trimmed.Split('/').LastOrDefault(part => part.Length > 0);
        return last ?? trimmed;
    }

    /// <summary>"prompt", "running", "unknown" for a shell state macOS accepts, else null.</summary>
    internal static string? ShellState(string? raw) => raw?.Trim().ToLowerInvariant() switch
    {
        "prompt" or "idle" => "prompt",
        "running" or "busy" or "command" => "running",
        "unknown" or "clear" => "unknown",
        _ => null,
    };
}

/// <summary>A pull request a shell or tool reported for a tab (surface.report_pr).</summary>
internal sealed record ReportedPullRequest(int Number, string Label, string Url, string State, string? Branch, string? Checks);

/// <summary>Shell telemetry over the control pipe, as on macOS (Sources/TerminalController+Telemetry.swift):
/// reports of a tab's directory, shell state, branch, pull request, ports and tty. Like macOS they are
/// fire and forget: the arguments are checked and echoed, and a report for a tab that is gone does
/// nothing. A reported branch or directory stands until the shell's next prompt reports its own.</summary>
public sealed partial class MainWindow
{
    private readonly Dictionary<string, string> _shellStates = new(StringComparer.Ordinal);
    private readonly Dictionary<string, string> _ttyNames = new(StringComparer.Ordinal);
    private readonly Dictionary<string, bool> _reportedDirty = new(StringComparer.Ordinal);
    private readonly Dictionary<string, ReportedPullRequest> _reportedPullRequests = new(StringComparer.Ordinal);
    private readonly Dictionary<string, List<int>> _reportedPorts = new(StringComparer.Ordinal);

    private static ControlException InvalidParam(string what) => new("invalid_params", $"Missing or invalid {what}");

    private object? TelemetryFromControl(string method, JsonElement p)
    {
        var workspaceId = Text(p, "workspace_id") ?? throw InvalidParam("workspace_id");
        var requested = Text(p, "surface_id");
        var workspace = _snapshot.Workspaces.FirstOrDefault(item => item.Id == workspaceId);
        // A named tab, else (for the reports that allow it) the workspace's focused one; null when it is gone.
        string? Target(bool optional)
        {
            if (requested is null && !optional) throw InvalidParam("surface_id");
            var id = requested ?? workspace?.SelectedPane?.SelectedSurfaceId;
            return id is not null && workspace?.Panes.Any(pane => pane.Surfaces.Any(surface => surface.Id == id)) == true ? id : null;
        }
        void Refresh(string? surface)
        {
            if (surface is not null) UpdateSidebarRow(workspaceId);
        }
        switch (method)
        {
            case "surface.report_pwd":
            {
                var path = Text(p, "path")?.Trim() is { Length: > 0 } given ? given : throw new ControlException("invalid_params", "Missing path");
                Bytes(path, 4 * 1024, "path");
                // Absolute (a Windows path, or a remote one from a shell behind SSH) and plain.
                if (!(Path.IsPathFullyQualified(path) || path.StartsWith('/')) || path.Split('/', '\\').Any(part => part is "." or ".."))
                    throw new ControlException("invalid_params", "path must be absolute, without . or .. components");
                if (Target(optional: false) is { } surface) _terminals.GetValueOrDefault(surface)?.ReportCwd(path);
                return new { workspace_id = workspaceId, surface_id = requested, path };
            }
            case "surface.report_shell_state":
            {
                var raw = Text(p, "state") ?? string.Empty;
                var state = TelemetryControl.ShellState(raw) ?? throw new ControlException("invalid_params", "Invalid shell state — expected prompt or running");
                var surface = Target(optional: false);
                var echoed = raw.Trim().ToLowerInvariant();
                if (surface is not null && _shellStates.GetValueOrDefault(surface) == state)
                    return new { workspace_id = workspaceId, surface_id = requested, state = echoed, deduped = true };
                if (surface is not null) _shellStates[surface] = state;
                return new { workspace_id = workspaceId, surface_id = requested, state = echoed };
            }
            case "surface.report_git_branch":
            {
                var branch = Text(p, "branch")?.Trim() is { Length: > 0 } given ? given : throw new ControlException("invalid_params", "Missing branch");
                Bytes(branch, 1024, "branch");
                bool? dirty = p.TryGetProperty("dirty", out var rawDirty) && rawDirty.ValueKind is JsonValueKind.True or JsonValueKind.False ? rawDirty.GetBoolean() : null;
                if (Target(optional: false) is { } surface)
                {
                    _branches[surface] = branch;
                    if (dirty is { } value) _reportedDirty[surface] = value;
                    Refresh(surface);
                }
                return dirty is null ? new { workspace_id = workspaceId, surface_id = requested, branch } : new { workspace_id = workspaceId, surface_id = requested, branch, dirty };
            }
            case "surface.clear_git_branch":
                if (Target(optional: false) is { } cleared)
                {
                    _branches.Remove(cleared);
                    _reportedDirty.Remove(cleared);
                    Refresh(cleared);
                }
                return new { workspace_id = workspaceId, surface_id = requested };
            case "surface.report_pr":
            {
                var number = Number(p, "number") is { } given && given > 0 ? given : throw InvalidParam("number");
                var url = Text(p, "url")?.Trim() is { } rawUrl && Uri.TryCreate(rawUrl, UriKind.Absolute, out var parsed) && parsed.Scheme is "http" or "https" && parsed.Host.Length > 0
                    ? parsed.AbsoluteUri : throw InvalidParam("url");
                Bytes(url, 4 * 1024, "url");
                var status = Text(p, "state")?.Trim().ToLowerInvariant() is { Length: > 0 } rawState ? rawState : "open";
                var state = status is "open" or "merged" or "closed"
                    ? status : throw new ControlException("invalid_params", "Invalid state — use: open, merged, closed");
                var branch = Text(p, "branch")?.Trim() is { Length: > 0 } rawBranch ? rawBranch : null;
                if (branch is not null) Bytes(branch, 1024, "branch");
                string? checks = null;
                if (Text(p, "checks")?.Trim().ToLowerInvariant() is { Length: > 0 } rawChecks)
                    checks = rawChecks is "pass" or "fail" or "pending" ? rawChecks : throw new ControlException("invalid_params", "Invalid checks — use: pass, fail, pending");
                var label = Text(p, "label")?.Trim() is { } rawLabel ? rawLabel : "PR";
                if (label.Length == 0) throw new ControlException("invalid_params", "Invalid label");
                label = label.Length > 16 ? label[..16] : label;
                if (Target(optional: false) is { } surface)
                {
                    _reportedPullRequests[surface] = new ReportedPullRequest(number, label, url, state, branch, checks);
                    Refresh(surface);
                }
                return new { workspace_id = workspaceId, surface_id = requested, number, url, label, state, branch, checks };
            }
            case "surface.clear_pr":
                if (Target(optional: false) is { } withoutPr && _reportedPullRequests.Remove(withoutPr)) Refresh(withoutPr);
                return new { workspace_id = workspaceId, surface_id = requested };
            case "surface.report_ports":
            {
                if (!p.TryGetProperty("ports", out var raw) || raw.ValueKind is not (JsonValueKind.Array or JsonValueKind.Number)) throw InvalidParam("ports");
                List<JsonElement> values = raw.ValueKind == JsonValueKind.Number ? [raw] : [.. raw.EnumerateArray()];
                if (values.Count > 65535) throw new ControlException("invalid_params", "ports exceeds the limit of 65535 entries");
                if (values.Count == 0 || values.Any(value => value.ValueKind != JsonValueKind.Number || !value.TryGetInt32(out _))) throw InvalidParam("ports");
                var ports = values.Select(value => value.GetInt32()).ToList();
                if (ports.Any(port => port is < 1 or > 65535)) throw new ControlException("invalid_params", "Invalid port — must be 1-65535");
                ports = [.. ports.Distinct().Order()];
                if (Target(optional: false) is { } surface) _reportedPorts[surface] = ports;
                return new { workspace_id = workspaceId, surface_id = requested, ports };
            }
            case "surface.clear_ports":
                if (requested is not null) _reportedPorts.Remove(requested);
                else if (workspace is not null)
                    foreach (var surface in workspace.Panes.SelectMany(pane => pane.Surfaces)) _reportedPorts.Remove(surface.Id);
                return new { workspace_id = workspaceId, surface_id = requested };
            case "surface.ports_kick":
            {
                var reason = (Text(p, "reason") ?? "command").Trim().ToLowerInvariant();
                if (reason is not ("command" or "refresh")) throw new ControlException("invalid_params", "reason must be command or refresh");
                if (Target(optional: true) is not null) RescanPorts();
                return new { workspace_id = workspaceId, surface_id = requested, reason };
            }
            case "surface.report_tty":
            {
                var tty = Text(p, "tty_name")?.Trim() is { Length: > 0 } given ? given : throw new ControlException("invalid_params", "Missing tty_name");
                Bytes(tty, 1024, "tty_name");
                if (Target(optional: true) is { } surface) _ttyNames[surface] = tty;
                return new { workspace_id = workspaceId, surface_id = requested, tty_name = tty };
            }
            default: // surface.clear_agent_state
                if (Target(optional: false) is { } cleared2)
                {
                    _terminals.GetValueOrDefault(cleared2)?.ReportHookState(null, null);
                    // The tab's running helpers end with it, as macOS finishActiveSurface.
                    foreach (var helper in Helpers.InWorkspace(workspaceId).Where(helper => helper.SurfaceId == cleared2 && !helper.Finished).ToList())
                        Helpers.Finish(helper.Id, "completed", null, null, DateTimeOffset.UtcNow);
                }
                return new { workspace_id = workspaceId, surface_id = requested };
        }
    }

    private static void Bytes(string value, int limit, string name)
    {
        if (Encoding.UTF8.GetByteCount(value) > limit) throw new ControlException("invalid_params", $"{name} exceeds the UTF-8 limit of {limit} bytes");
    }

    /// <summary>The tab with this tty in this window (surface.resolve_tty), as the registry asks every window.</summary>
    internal (string WorkspaceId, string SurfaceId)? SurfaceWithTty(string tty) =>
        _ttyNames.Where(item => TelemetryControl.NormalizedTty(item.Value) == tty && !IsPanel(item.Key))
            .Select(item => (WorkspaceId: _snapshot.Workspaces.FirstOrDefault(workspace => workspace.Panes.Any(pane => pane.Surfaces.Any(surface => surface.Id == item.Key)))?.Id, SurfaceId: item.Key))
            .Where(item => item.WorkspaceId is not null).Select(item => ((string, string)?)(item.WorkspaceId!, item.SurfaceId)).FirstOrDefault();

    /// <summary>The pull request the sidebar and sidebar_state show: one reported for the focused tab, else the one looked up for its branch.</summary>
    private ReportedPullRequest? PullRequestFor(WorkspaceSnapshot workspace)
    {
        if (workspace.SelectedPane?.SelectedSurfaceId is { } focused && _reportedPullRequests.TryGetValue(focused, out var reported)) return reported;
        return PullRequestKey(workspace) is { } key && _pullRequests.GetValueOrDefault(key) is { } found ? new ReportedPullRequest(found.Number, "PR", found.Url, found.State, key.Branch, null) : null;
    }

    /// <summary>The ports a workspace's tabs listen on: scanned, plus any its shells reported.</summary>
    private List<int> WorkspacePorts(WorkspaceSnapshot workspace) =>
        _ports.Where(entry => entry.WorkspaceId == workspace.Id).Select(entry => entry.Port)
            .Concat(workspace.Panes.SelectMany(pane => pane.Surfaces).SelectMany(surface => _reportedPorts.GetValueOrDefault(surface.Id) ?? []))
            .Distinct().Order().ToList();
}
