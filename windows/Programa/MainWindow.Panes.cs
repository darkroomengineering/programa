using System.Text.Json;
using Microsoft.UI.Xaml;

namespace Programa;

/// <summary>pane.* and workspace navigation over the control pipe, as on macOS
/// (Sources/TerminalController+Pane.swift, +Workspace.swift). Only the focus-intent methods
/// (pane.focus, pane.last, workspace.next, previous, last) move the selection; swap, break and
/// create keep it, as macOS does for socket commands. pane.join is surface.move (WindowRegistry).</summary>
/// <summary>Its own type, so MainWindow's static method list can read it whatever the file order.</summary>
internal static class PaneControl
{
    internal static readonly string[] Methods =
    [
        "pane.list", "pane.focus", "pane.last", "pane.surfaces", "pane.create", "pane.resize", "pane.swap", "pane.break", "pane.join",
        "workspace.next", "workspace.previous", "workspace.last", "workspace.reorder", "workspace.equalize_splits",
    ];
}

public sealed partial class MainWindow
{

    /// <summary>The element holding the selected workspace's panes, for pane frames.</summary>
    private FrameworkElement? _layoutElement;

    /// <summary>Workspaces selected before the current one, most recent last (workspace.last).</summary>
    private readonly List<string> _workspaceHistory = [];
    private string? _historyCurrent;
    private bool _navigatingHistory;

    /// <summary>Called on each projection: a new selection puts the one before it in the history.</summary>
    private void NoteSelectedWorkspace()
    {
        var now = _snapshot.SelectedWorkspaceId;
        if (now == _historyCurrent) return;
        if (_historyCurrent is not null && !_navigatingHistory)
        {
            _workspaceHistory.Remove(_historyCurrent);
            _workspaceHistory.Add(_historyCurrent);
            if (_workspaceHistory.Count > 64) _workspaceHistory.RemoveAt(0);
        }
        _historyCurrent = now;
    }

    private object? PaneFromControl(string method, JsonElement p) => method switch
    {
        "pane.list" => PaneList(PaneRequestWorkspace(p)),
        "pane.focus" => FocusPaneFromControl(p),
        "pane.last" => LastPaneFromControl(p),
        "pane.surfaces" => PaneSurfaces(p),
        "pane.create" => CreatePaneFromControl(p),
        "pane.resize" => ResizePaneFromControl(p),
        "pane.swap" => SwapPanesFromControl(p),
        "pane.break" => BreakPaneFromControl(p),
        "workspace.next" or "workspace.previous" => SelectAdjacentWorkspace(method == "workspace.next" ? 1 : -1),
        "workspace.last" => LastWorkspaceFromControl(),
        "workspace.reorder" => ReorderWorkspaceFromControl(p),
        "workspace.equalize_splits" => EqualizeFromControl(p),
        _ => throw new ControlException("method_not_found", $"{method} is not available on Windows yet."),
    };

    /// <summary>The workspace a pane request names: its workspace_id, else the surface's or the pane's, else the selected one.</summary>
    private WorkspaceSnapshot PaneRequestWorkspace(JsonElement p) =>
        Text(p, "workspace_id") is not null ? WorkspaceTarget(p)
        : Text(p, "surface_id") is not null ? SurfaceTarget(p).Workspace
        : Text(p, "pane_id") is { } paneId && _snapshot.Workspaces.FirstOrDefault(workspace => workspace.Panes.Any(pane => pane.Id == paneId)) is { } owner ? owner
        : WorkspaceTarget(p);

    private static PaneSnapshot PaneIn(WorkspaceSnapshot workspace, string paneId) =>
        workspace.Panes.FirstOrDefault(pane => pane.Id == paneId) ?? throw new ControlException("not_found", "Pane not found", new { pane_id = paneId });

    /// <summary>The selected workspace's pane area; one not on screen would fill the same.</summary>
    private PaneGeometry.Frame ContainerFrame()
    {
        var (width, height) = (_layoutElement?.ActualWidth ?? 0, _layoutElement?.ActualHeight ?? 0);
        if (width <= 0 || height <= 0)
            (width, height) = (Math.Max(0, Root.ActualWidth - (_sidebarVisible ? _sidebarWidth : 0)), Math.Max(0, Root.ActualHeight - TitleBarHeight));
        return new PaneGeometry.Frame(0, 0, width, height);
    }

    private object PaneList(WorkspaceSnapshot workspace)
    {
        var container = ContainerFrame();
        var frames = PaneGeometry.Frames(workspace.Layout, container);
        return new
        {
            workspace_id = workspace.Id,
            window_id = WindowId,
            container_frame = new { x = container.X, y = container.Y, width = container.Width, height = container.Height },
            panes = PaneGeometry.Panes(workspace.Layout).Select((paneId, index) =>
            {
                var pane = PaneIn(workspace, paneId);
                var frame = frames[paneId];
                var grid = _terminals.GetValueOrDefault(pane.SelectedSurfaceId)?.GridMetrics;
                return new
                {
                    id = pane.Id,
                    index,
                    focused = pane.Id == workspace.SelectedPaneId,
                    surface_ids = pane.Surfaces.Select(surface => surface.Id).ToList(),
                    selected_surface_id = pane.SelectedSurfaceId,
                    surface_count = pane.Surfaces.Count,
                    pixel_frame = new { x = frame.X, y = frame.Y, width = frame.Width, height = frame.Height },
                    columns = grid?.Columns,
                    rows = grid?.Rows,
                    cell_width_px = grid is { } metrics ? (int?)Math.Round(metrics.CellWidth * metrics.Scale) : null,
                    cell_height_px = grid is { } size ? (int?)Math.Round(size.CellHeight * size.Scale) : null,
                    // In DIPs, the unit pane.resize takes for `amount`.
                    cell_width = grid?.CellWidth,
                    cell_height = grid?.CellHeight,
                };
            }).ToList(),
        };
    }

    private void FocusPane(WorkspaceSnapshot workspace, PaneSnapshot pane)
    {
        Apply(new { command = "select_surface", workspace_id = workspace.Id, pane_id = pane.Id, surface_id = pane.SelectedSurfaceId });
        _terminals.GetValueOrDefault(pane.SelectedSurfaceId)?.FocusTerminal();
    }

    private object FocusPaneFromControl(JsonElement p)
    {
        var paneId = Required(p, "pane_id");
        var workspace = PaneRequestWorkspace(p);
        var pane = PaneIn(workspace, paneId);
        FocusPane(workspace, pane);
        return new { window_id = WindowId, workspace_id = workspace.Id, pane_id = pane.Id };
    }

    /// <summary>As macOS: the first pane in layout order that is not the focused one.</summary>
    private object LastPaneFromControl(JsonElement p)
    {
        var workspace = PaneRequestWorkspace(p);
        var target = PaneGeometry.Panes(workspace.Layout).FirstOrDefault(id => id != workspace.SelectedPaneId)
            ?? throw new ControlException("not_found", "No alternate pane available");
        var pane = PaneIn(workspace, target);
        FocusPane(workspace, pane);
        return new { window_id = WindowId, workspace_id = workspace.Id, pane_id = pane.Id, surface_id = pane.SelectedSurfaceId };
    }

    private object PaneSurfaces(JsonElement p)
    {
        var workspace = PaneRequestWorkspace(p);
        var pane = Text(p, "pane_id") is { } paneId ? PaneIn(workspace, paneId) : workspace.SelectedPane ?? throw NotFound("pane");
        var titles = DescribeWorkspaces().First(item => item.Id == workspace.Id).Surfaces.ToDictionary(surface => surface.Id, surface => surface.Title, StringComparer.Ordinal);
        return new
        {
            workspace_id = workspace.Id,
            pane_id = pane.Id,
            window_id = WindowId,
            surfaces = pane.Surfaces.Select((surface, index) => new
            {
                id = surface.Id,
                index,
                title = titles.GetValueOrDefault(surface.Id) ?? string.Empty,
                type = _panels.GetValueOrDefault(surface.Id) is ReviewPanel || _restoreReviews.ContainsKey(surface.Id) ? "review"
                    : _panels.GetValueOrDefault(surface.Id) is MarkdownPanel || _restorePanels.ContainsKey(surface.Id) ? "markdown" : "terminal",
                selected = surface.Id == pane.SelectedSurfaceId,
            }).ToList(),
        };
    }

    /// <summary>Splits the workspace's focused pane, as macOS pane.create; the selection stays.</summary>
    private object CreatePaneFromControl(JsonElement p)
    {
        var direction = Text(p, "direction") ?? throw new ControlException("invalid_params", "direction (left|right|up|down) is required.");
        if (Text(p, "type") is { } type && type != "terminal") throw new ControlException("invalid_params", "type must be terminal.");
        var workspace = PaneRequestWorkspace(p);
        var pane = workspace.SelectedPane ?? throw new ControlException("not_found", "No focused surface to split");
        return Split(workspace, pane, pane.SelectedSurfaceId, direction, Text(p, "cwd"), Text(p, "initial_command"));
    }

    private object ResizePaneFromControl(JsonElement p)
    {
        var direction = (Text(p, "direction") ?? string.Empty).ToLowerInvariant();
        var amount = 1;
        if (p.TryGetProperty("amount", out var raw) && raw.ValueKind != JsonValueKind.Null)
            amount = Number(p, "amount") ?? throw new ControlException("invalid_params", "amount must be an integer");
        if (direction is not ("left" or "right" or "up" or "down") || amount <= 0)
            throw new ControlException("invalid_params", "direction must be one of left|right|up|down and amount must be > 0");
        var workspace = PaneRequestWorkspace(p);
        var pane = PaneIn(workspace, Text(p, "pane_id") ?? workspace.SelectedPaneId);
        var resized = PaneGeometry.Resize(workspace.Layout, pane.Id, direction, amount, ContainerFrame());
        Apply(new { command = "resize_split", workspace_id = workspace.Id, split_id = resized.SplitId, ratio = resized.New });
        return new
        {
            window_id = WindowId, workspace_id = workspace.Id, pane_id = pane.Id, split_id = resized.SplitId,
            direction, amount, old_divider_position = resized.Old, new_divider_position = resized.New,
        };
    }

    /// <summary>Swaps the two panes' selected tabs, each taking the other's place, as on macOS. A pane
    /// with one tab gets a placeholder tab meanwhile, so neither pane closes; it never starts a shell.</summary>
    private object SwapPanesFromControl(JsonElement p)
    {
        var sourceId = Required(p, "pane_id");
        var targetId = Required(p, "target_pane_id");
        if (sourceId == targetId) throw new ControlException("invalid_params", "pane_id and target_pane_id must be different");
        var workspace = _snapshot.Workspaces.FirstOrDefault(item => item.Panes.Any(pane => pane.Id == sourceId))
            ?? throw new ControlException("not_found", "Source pane not found", new { pane_id = sourceId });
        var source = PaneIn(workspace, sourceId);
        var target = workspace.Panes.FirstOrDefault(pane => pane.Id == targetId)
            ?? throw new ControlException("not_found", "Target pane not found in source workspace", new { target_pane_id = targetId });
        var (sourceSurface, targetSurface) = (source.SelectedSurfaceId, target.SelectedSurfaceId);
        var sourceIndex = source.Surfaces.ToList().FindIndex(surface => surface.Id == sourceSurface);
        var sourceNext = sourceIndex + 1 < source.Surfaces.Count ? source.Surfaces[sourceIndex + 1].Id : null;
        var (selectedWorkspace, focusedPane) = (_snapshot.SelectedWorkspaceId, workspace.SelectedPaneId);

        string? Placeholder(PaneSnapshot pane)
        {
            if (pane.Surfaces.Count > 1) return null;
            var id = Id("surface");
            _snapshot = Dispatch(new { command = "create_surface", workspace_id = workspace.Id, pane_id = pane.Id, surface_id = id, session_id = Id("session") });
            return id;
        }
        var placeholders = new[] { (source.Id, Placeholder(source)), (target.Id, Placeholder(target)) };
        _snapshot = Dispatch(new { command = "move_surface", workspace_id = workspace.Id, source_pane_id = source.Id, target_pane_id = target.Id, surface_id = sourceSurface, before_surface_id = targetSurface });
        _snapshot = Dispatch(new { command = "move_surface", workspace_id = workspace.Id, source_pane_id = target.Id, target_pane_id = source.Id, surface_id = targetSurface, before_surface_id = sourceNext });
        foreach (var (paneId, placeholder) in placeholders)
            if (placeholder is not null) _snapshot = Dispatch(new { command = "close_surface", workspace_id = workspace.Id, pane_id = paneId, surface_id = placeholder });
        // Each swapped tab is its pane's selected one; the focused pane and workspace stay as they were.
        _snapshot = Dispatch(new { command = "select_surface", workspace_id = workspace.Id, pane_id = target.Id, surface_id = sourceSurface });
        _snapshot = Dispatch(new { command = "select_surface", workspace_id = workspace.Id, pane_id = source.Id, surface_id = targetSurface });
        if (focusedPane != source.Id && _snapshot.Workspaces.First(item => item.Id == workspace.Id).Panes.FirstOrDefault(pane => pane.Id == focusedPane) is { } focused)
            _snapshot = Dispatch(new { command = "select_surface", workspace_id = workspace.Id, pane_id = focused.Id, surface_id = focused.SelectedSurfaceId });
        if (selectedWorkspace is not null && selectedWorkspace != workspace.Id)
            _snapshot = Dispatch(new { command = "select_workspace", workspace_id = selectedWorkspace });
        ProjectSnapshot();
        return new
        {
            window_id = WindowId, workspace_id = workspace.Id, pane_id = source.Id, target_pane_id = target.Id,
            source_surface_id = sourceSurface, target_surface_id = targetSurface,
        };
    }

    /// <summary>A tab out of its pane into a new workspace of its own, its terminal carrying on.</summary>
    private object BreakPaneFromControl(JsonElement p)
    {
        var workspace = PaneRequestWorkspace(p);
        var pane = Text(p, "pane_id") is { } paneId ? PaneIn(workspace, paneId) : workspace.SelectedPane ?? throw new ControlException("not_found", "No source surface to break");
        var surfaceId = Text(p, "surface_id") ?? pane.SelectedSurfaceId;
        var owner = workspace.Panes.FirstOrDefault(item => item.Surfaces.Any(surface => surface.Id == surfaceId))
            ?? throw new ControlException("not_found", "Surface not found", new { surface_id = surfaceId });
        var selected = _snapshot.SelectedWorkspaceId;
        var transfer = TakeSurface(workspace.Id, owner.Id, surfaceId);
        var newWorkspace = transfer.Workspace.GetProperty("id").GetString()!;
        var newPane = transfer.Workspace.GetProperty("selected_pane_id").GetString()!;
        _snapshot = Dispatch(new { command = "adopt_workspace", workspace = transfer.Workspace });
        Absorb(transfer);
        if (selected is not null && _snapshot.Workspaces.Any(item => item.Id == selected))
            _snapshot = Dispatch(new { command = "select_workspace", workspace_id = selected });
        ProjectSnapshot();
        return new { window_id = WindowId, workspace_id = newWorkspace, pane_id = newPane, surface_id = surfaceId };
    }

    private object SelectAdjacentWorkspace(int delta)
    {
        if (SelectedWorkspace() is null) throw new ControlException("not_found", "No workspace selected");
        CycleWorkspace(delta);
        return new { workspace_id = _snapshot.SelectedWorkspaceId, window_id = WindowId };
    }

    /// <summary>Back to the workspace selected before, and on to the one before that, as macOS navigateBack.</summary>
    private object LastWorkspaceFromControl()
    {
        var current = _snapshot.SelectedWorkspaceId;
        var at = _workspaceHistory.FindLastIndex(id => id != current && _snapshot.Workspaces.Any(workspace => workspace.Id == id));
        if (at < 0) throw new ControlException("not_found", "No previous workspace in history");
        var target = _workspaceHistory[at];
        _workspaceHistory.RemoveRange(at, _workspaceHistory.Count - at);
        _navigatingHistory = true;
        try { Apply(new { command = "select_workspace", workspace_id = target }); }
        finally { _navigatingHistory = false; }
        return new { workspace_id = target, window_id = WindowId };
    }

    private object ReorderWorkspaceFromControl(JsonElement p)
    {
        var workspaceId = Required(p, "workspace_id");
        var index = Number(p, "index");
        var (before, after) = (Text(p, "before_workspace_id"), Text(p, "after_workspace_id"));
        if ((index is null ? 0 : 1) + (before is null ? 0 : 1) + (after is null ? 0 : 1) != 1)
            throw new ControlException("invalid_params", "Specify exactly one target: index, before_workspace_id, or after_workspace_id");
        var order = _snapshot.Workspaces.Select(workspace => workspace.Id).ToList();
        if (!order.Contains(workspaceId)) throw new ControlException("not_found", "Workspace not found", new { workspace_id = workspaceId });
        if (index is null)
        {
            var others = order.Where(id => id != workspaceId).ToList();
            var anchor = others.IndexOf((before ?? after)!);
            if (anchor < 0) throw new ControlException("not_found", "Workspace not found", new { workspace_id = before ?? after });
            index = before is not null ? anchor : anchor + 1;
        }
        Apply(new { command = "move_workspace", workspace_id = workspaceId, index = Math.Clamp(index.Value, 0, order.Count - 1) });
        return new { workspace_id = workspaceId, window_id = WindowId, index = _snapshot.Workspaces.ToList().FindIndex(workspace => workspace.Id == workspaceId) };
    }

    private object EqualizeFromControl(JsonElement p)
    {
        var workspace = PaneRequestWorkspace(p);
        var ratios = PaneGeometry.Equalized(workspace.Layout, Text(p, "orientation"));
        foreach (var (splitId, ratio) in ratios)
            _snapshot = Dispatch(new { command = "resize_split", workspace_id = workspace.Id, split_id = splitId, ratio });
        if (ratios.Count > 0) ProjectSnapshot();
        return new { workspace_id = workspace.Id, equalized = ratios.Count > 0 };
    }
}
