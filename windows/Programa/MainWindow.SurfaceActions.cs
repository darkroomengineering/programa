using System.Text.Json;
using Microsoft.UI.Xaml;

namespace Programa;

/// <summary>Its own type, so MainWindow's static method list can read it whatever the file order.</summary>
internal static class SurfaceActionControl
{
    internal static readonly string[] Methods =
    [
        "surface.send_key", "surface.send_paste", "surface.send_if_unchanged", "surface.clear_history",
        "surface.trigger_flash", "surface.refresh", "surface.health", "surface.reorder", "surface.action", "tab.action",
    ];

    internal static readonly string[] TabActions =
        ["rename", "clear_name", "close_left", "close_right", "close_others", "new_terminal_right", "pin", "unpin", "mark_read", "mark_unread"];
}

/// <summary>Terminal input and tab actions over the control pipe, as on macOS
/// (Sources/TerminalController+Surface.swift, +SurfacePaste, +SurfaceConditionalSend, and
/// v2TabAction): send_key, send_paste and send_if_unchanged refuse while an agent waits on an
/// approval prompt (unless answer_prompt) or a person has unsent typed input (unless force).</summary>
public sealed partial class MainWindow
{
    private object? SurfaceActionFromControl(string method, JsonElement p) => method switch
    {
        "surface.send_key" => SendKeyFromControl(p),
        "surface.send_paste" => SendPasteFromControl(p),
        "surface.send_if_unchanged" => SendIfUnchangedFromControl(p),
        "surface.clear_history" => ClearHistoryFromControl(p),
        "surface.trigger_flash" => FlashFromControl(p),
        "surface.refresh" => RefreshFromControl(p),
        "surface.health" => HealthFromControl(p),
        "surface.reorder" => ReorderSurfaceFromControl(p),
        "surface.action" or "tab.action" => TabActionFromControl(p),
        _ => throw new ControlException("method_not_found", $"{method} is not available on Windows yet."),
    };

    /// <summary>The named (else focused) surface, which must be a terminal.</summary>
    private (WorkspaceSnapshot Workspace, string SurfaceId, TerminalView Terminal) TerminalTarget(JsonElement p)
    {
        var (workspace, _, surface) = SurfaceTarget(p);
        if (PanelFor(surface) is not null) throw new ControlException("invalid_params", "Surface is not a terminal", new { surface_id = surface });
        return (workspace, surface, TerminalFor(workspace.Id, surface));
    }

    private static void RefuseWrite(JsonElement p, TerminalView terminal, string surfaceId)
    {
        if (!Flag(p, "answer_prompt") && terminal.AgentState.State == "blocked")
            throw new ControlException("agent_awaiting_approval", $"{surfaceId} is waiting on an approval prompt; nothing was sent", new { surface_id = surfaceId });
        if (!Flag(p, "force") && terminal.HasDraft)
            throw new ControlException("draft_in_progress", $"{surfaceId} has unsent typed input; nothing was sent", new { surface_id = surfaceId });
    }

    private object SurfaceResult(WorkspaceSnapshot workspace, string surfaceId) => new { workspace_id = workspace.Id, surface_id = surfaceId, window_id = WindowId };

    private object SendKeyFromControl(JsonElement p)
    {
        var name = Text(p, "key")?.Trim() is { Length: > 0 } key ? key : throw new ControlException("invalid_params", "Missing key");
        var (workspace, surface, terminal) = TerminalTarget(p);
        var parsed = NamedKeys.Parse(name) ?? throw new ControlException("invalid_params", "Unknown key", new { key = name });
        RefuseWrite(p, terminal, surface);
        if (!terminal.SendNamedKey(parsed)) throw new ControlException("invalid_params", "Unknown key", new { key = name });
        return SurfaceResult(workspace, surface);
    }

    /// <summary>One paste that never presses Return, so an agent prompt keeps it as a draft.</summary>
    private object SendPasteFromControl(JsonElement p)
    {
        if (!p.TryGetProperty("text", out var raw) || raw.ValueKind != JsonValueKind.String) throw new ControlException("invalid_params", "Missing text");
        var text = raw.GetString()!;
        if (text.Length == 0) throw new ControlException("invalid_params", "text must not be empty");
        var (workspace, surface, terminal) = TerminalTarget(p);
        RefuseWrite(p, terminal, surface);
        terminal.PasteText(text);
        return SurfaceResult(workspace, surface);
    }

    /// <summary>Sends text, then keys, only while the text read_text would return for the same lines
    /// still has the expected fingerprint; otherwise `mismatch` and nothing is sent.</summary>
    private object SendIfUnchangedFromControl(JsonElement p)
    {
        var expected = Text(p, "expected_fingerprint")?.Trim().ToLowerInvariant() is { Length: > 0 } value ? value : throw new ControlException("invalid_params", "Missing expected_fingerprint");
        var text = string.Empty;
        if (p.TryGetProperty("text", out var rawText) && rawText.ValueKind != JsonValueKind.Null)
            text = rawText.ValueKind == JsonValueKind.String ? rawText.GetString()! : throw new ControlException("invalid_params", "text must be a string");
        var keys = new List<string>();
        if (p.TryGetProperty("keys", out var rawKeys) && rawKeys.ValueKind != JsonValueKind.Null)
        {
            if (rawKeys.ValueKind != JsonValueKind.Array || rawKeys.EnumerateArray().Any(item => item.ValueKind != JsonValueKind.String))
                throw new ControlException("invalid_params", "keys must be an array of key names");
            keys = [.. rawKeys.EnumerateArray().Select(item => item.GetString()!)];
        }
        if (text.Length == 0 && keys.Count == 0) throw new ControlException("invalid_params", "Provide text or keys");
        var (workspace, surface, terminal) = TerminalTarget(p);
        var parsed = keys.Select(key => (Name: key, Key: NamedKeys.Parse(key))).ToList();
        if (parsed.FirstOrDefault(item => item.Key is null) is { Name: { } unknown }) throw new ControlException("invalid_params", "Unknown key", new { key = unknown });
        terminal.EnsureStarted();
        var current = Fingerprint(terminal.OutputText(ReadLines(p)));
        if (current != expected)
            throw new ControlException("mismatch", "Surface text changed since the fingerprint was read", new { current_fingerprint = current, surface_id = surface });
        // After the fingerprint, so a mismatch is reported first, as on macOS.
        RefuseWrite(p, terminal, surface);
        if (text.Length > 0) terminal.SendText(text);
        foreach (var (_, key) in parsed) terminal.SendNamedKey(key!.Value);
        return new { fingerprint = current, workspace_id = workspace.Id, surface_id = surface, window_id = WindowId };
    }

    private object ClearHistoryFromControl(JsonElement p)
    {
        var (workspace, surface, terminal) = TerminalTarget(p);
        terminal.ClearScrollback();
        terminal.Refresh();
        return SurfaceResult(workspace, surface);
    }

    /// <summary>Flashes the pane that shows the surface, as macOS triggerFocusFlash; one not on screen has nothing to flash.</summary>
    private object FlashFromControl(JsonElement p)
    {
        var workspace = PaneRequestWorkspace(p);
        var surface = Text(p, "surface_id") ?? workspace.SelectedPane?.SelectedSurfaceId ?? throw new ControlException("not_found", "No focused surface");
        var pane = workspace.Panes.FirstOrDefault(item => item.Surfaces.Any(candidate => candidate.Id == surface))
            ?? throw new ControlException("not_found", "Surface not found", new { surface_id = surface });
        if (_paneRings.TryGetValue(pane.Id, out var ring))
        {
            ring.Ring.Visibility = Visibility.Visible;
            var timer = DispatcherQueue.CreateTimer();
            timer.Interval = TimeSpan.FromMilliseconds(900);
            timer.IsRepeating = false;
            timer.Tick += (_, _) => RefreshUnreadIndicators();
            timer.Start();
        }
        return SurfaceResult(workspace, surface);
    }

    private object RefreshFromControl(JsonElement p)
    {
        var workspace = PaneRequestWorkspace(p);
        var terminals = TerminalsOf(workspace).ToList();
        foreach (var terminal in terminals) terminal.Refresh();
        return new { window_id = WindowId, workspace_id = workspace.Id, refreshed = terminals.Count };
    }

    private object HealthFromControl(JsonElement p)
    {
        var workspace = PaneRequestWorkspace(p);
        var surfaces = PaneGeometry.Panes(workspace.Layout).Select(id => PaneIn(workspace, id)).SelectMany(pane => pane.Surfaces).ToList();
        return new
        {
            workspace_id = workspace.Id,
            window_id = WindowId,
            surfaces = surfaces.Select((surface, index) => new
            {
                index,
                id = surface.Id,
                type = SurfaceType(surface.Id),
                in_window = PanelFor(surface.Id) is null ? (bool?)(_terminals.GetValueOrDefault(surface.Id)?.InWindow ?? false) : null,
            }).ToList(),
        };
    }

    private string SurfaceType(string surfaceId) =>
        _panels.GetValueOrDefault(surfaceId) is ReviewPanel || _restoreReviews.ContainsKey(surfaceId) ? "review"
        : _panels.GetValueOrDefault(surfaceId) is MarkdownPanel || _restorePanels.ContainsKey(surfaceId) ? "markdown" : "terminal";

    /// <summary>A tab to another place in its own pane: index (its place among the others), or before or after another tab there.</summary>
    private object ReorderSurfaceFromControl(JsonElement p)
    {
        var surfaceId = Required(p, "surface_id");
        var index = Number(p, "index");
        var (before, after) = (Text(p, "before_surface_id"), Text(p, "after_surface_id"));
        if ((index is null ? 0 : 1) + (before is null ? 0 : 1) + (after is null ? 0 : 1) != 1)
            throw new ControlException("invalid_params", "Specify exactly one of index, before_surface_id, or after_surface_id");
        var (workspace, pane, _) = SurfaceTarget(p);
        var others = pane.Surfaces.Select(surface => surface.Id).Where(id => id != surfaceId).ToList();
        string? target;
        if (index is { } at) target = at >= 0 && at < others.Count ? others[at] : null;
        else
        {
            var anchor = others.IndexOf((before ?? after)!);
            if (anchor < 0) throw new ControlException("invalid_params", "Anchor surface must be in the same pane");
            target = before is not null ? others[anchor] : anchor + 1 < others.Count ? others[anchor + 1] : null;
        }
        Apply(new { command = "reorder_surface", workspace_id = workspace.Id, pane_id = pane.Id, surface_id = surfaceId, before_surface_id = target });
        return new { window_id = WindowId, workspace_id = workspace.Id, pane_id = pane.Id, surface_id = surfaceId };
    }

    private object TabActionFromControl(JsonElement p)
    {
        var action = (Text(p, "action")?.Trim().ToLowerInvariant().Replace('-', '_') is { Length: > 0 } name ? name : throw new ControlException("invalid_params", "Missing action")) switch
        {
            "close_to_left" => "close_left",
            "close_to_right" => "close_right",
            "close_other_tabs" => "close_others",
            "mark_as_unread" => "mark_unread",
            "new_terminal_to_right" or "new_terminal_tab_to_right" => "new_terminal_right",
            var other => other,
        };
        if (!SurfaceActionControl.TabActions.Contains(action))
            throw new ControlException("invalid_params", $"Unknown tab action '{action}'. Supported: {string.Join(", ", SurfaceActionControl.TabActions)}",
                new { action, supported_actions = SurfaceActionControl.TabActions });
        var workspace = (Text(p, "surface_id") ?? Text(p, "tab_id")) is { } named
            ? _snapshot.Workspaces.FirstOrDefault(item => item.Panes.Any(pane => pane.Surfaces.Any(surface => surface.Id == named)))
                ?? throw new ControlException("not_found", "Tab not found", new { surface_id = named, tab_id = named })
            : WorkspaceTarget(p);
        var surfaceId = Text(p, "surface_id") ?? Text(p, "tab_id") ?? workspace.SelectedPane?.SelectedSurfaceId ?? throw new ControlException("not_found", "No focused tab");
        var pane = workspace.Panes.First(item => item.Surfaces.Any(surface => surface.Id == surfaceId));
        var extras = new Dictionary<string, object?>();
        switch (action)
        {
            case "rename":
                var title = Text(p, "title")?.Trim() is { Length: > 0 } given ? given : throw new ControlException("invalid_params", "title is required.");
                Apply(new { command = "rename_surface", workspace_id = workspace.Id, pane_id = pane.Id, surface_id = surfaceId, title });
                extras["title"] = title;
                break;
            case "clear_name":
                Apply(new { command = "rename_surface", workspace_id = workspace.Id, pane_id = pane.Id, surface_id = surfaceId, title = (string?)null });
                break;
            case "pin" or "unpin":
                Apply(new { command = "set_surface_pinned", workspace_id = workspace.Id, pane_id = pane.Id, surface_id = surfaceId, pinned = action == "pin" });
                extras["pinned"] = action == "pin";
                break;
            case "mark_read":
                _manualUnread.Remove(surfaceId);
                _notifications.MarkRead(new HashSet<string>(StringComparer.Ordinal) { surfaceId });
                RefreshUnreadIndicators();
                break;
            case "mark_unread":
                _manualUnread.Add(surfaceId);
                RefreshUnreadIndicators();
                break;
            case "new_terminal_right":
                var created = Id("surface");
                var next = pane.Surfaces.SkipWhile(surface => surface.Id != surfaceId).Skip(1).FirstOrDefault()?.Id;
                CreateKeepingSelection(new { command = "create_surface", workspace_id = workspace.Id, pane_id = pane.Id, surface_id = created, session_id = Id("session") },
                    workspace.Id, created, _terminals.GetValueOrDefault(surfaceId)?.WorkingDirectory, null);
                if (next is not null) Apply(new { command = "reorder_surface", workspace_id = workspace.Id, pane_id = pane.Id, surface_id = created, before_surface_id = next });
                extras["created_surface_id"] = extras["created_tab_id"] = created;
                break;
            default:
                // close_left, close_right, close_others: pinned tabs stay, and the workspace keeps at least one tab.
                var ids = pane.Surfaces.Select(surface => surface.Id).ToList();
                var at = ids.IndexOf(surfaceId);
                var targets = action switch
                {
                    "close_left" => ids[..at],
                    "close_right" => ids[(at + 1)..],
                    _ => ids.Where(id => id != surfaceId).ToList(),
                };
                int closed = 0, skippedPinned = 0;
                foreach (var id in targets)
                {
                    if (pane.Surfaces.First(surface => surface.Id == id).IsPinned) { skippedPinned++; continue; }
                    if (_snapshot.Workspaces.First(item => item.Id == workspace.Id).Panes.Sum(item => item.Surfaces.Count) <= 1) break;
                    _snapshot = Dispatch(new { command = "close_surface", workspace_id = workspace.Id, pane_id = pane.Id, surface_id = id });
                    closed++;
                }
                if (closed > 0) ProjectSnapshot();
                extras["closed"] = closed;
                extras["skipped_pinned"] = skippedPinned;
                break;
        }
        var result = new Dictionary<string, object?>
        {
            ["action"] = action, ["window_id"] = WindowId, ["workspace_id"] = workspace.Id,
            ["surface_id"] = surfaceId, ["tab_id"] = surfaceId, ["pane_id"] = pane.Id,
        };
        foreach (var (key, value) in extras) result[key] = value;
        return result;
    }
}
