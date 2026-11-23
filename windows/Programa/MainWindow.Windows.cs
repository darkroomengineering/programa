using System.Text.Json;
using System.Text.Json.Nodes;
using Microsoft.UI.Xaml.Controls;

namespace Programa;

/// <summary>A workspace on its way to another window: its core JSON with every id, its live
/// terminals, and what its terminals and panels would bring back from the session.</summary>
internal sealed record WorkspaceTransfer(
    JsonElement Workspace,
    Dictionary<string, TerminalView> Terminals,
    Dictionary<string, SessionTerminal> Pending,
    Dictionary<string, string> Markdown,
    Dictionary<string, SessionReview> Reviews,
    Dictionary<string, string?> Branches);

/// <summary>This window's part in a multi-window app (see <see cref="WindowRegistry"/>).</summary>
public sealed partial class MainWindow
{
    internal string WindowId { get; private set; } = Id("window");
    internal int WorkspaceCount => _snapshot.Workspaces.Count;
    internal string? SelectedWorkspaceId => _snapshot.SelectedWorkspaceId;

    /// <summary>Every directory a terminal of this window is in, or will start in.</summary>
    internal IEnumerable<string> OpenDirectories() =>
        _terminals.Values.Select(terminal => terminal.WorkingDirectory).Concat(_restore.Values.Select(saved => saved.Cwd)).OfType<string>().ToList();

    internal bool OwnsWorkspace(string id) => _snapshot.Workspaces.Any(workspace => workspace.Id == id);

    internal (string WorkspaceId, string PaneId) LocateSurface(string surfaceId)
    {
        var workspace = WorkspaceOf(surfaceId) ?? throw NotFound("surface", surfaceId);
        return (workspace.Id, workspace.Panes.First(pane => pane.Surfaces.Any(surface => surface.Id == surfaceId)).Id);
    }

    internal bool OwnsSurface(string id) =>
        _snapshot.Workspaces.Any(workspace => workspace.Panes.Any(pane => pane.Surfaces.Any(surface => surface.Id == id)));

    /// <summary>Opens 32 pixels below and right of <paramref name="anchor"/>, at its size.</summary>
    internal void CascadeFrom(MainWindow anchor)
    {
        var position = anchor.AppWindow.Position;
        var size = anchor.AppWindow.Size;
        AppWindow.MoveAndResize(new Windows.Graphics.RectInt32(position.X + 32, position.Y + 32, size.Width, size.Height));
    }

    /// <summary>Move a tab to a new window, as on macOS: a tab released past the edge of every Programa
    /// window opens in a new window under the release point, its terminal still running. Released over
    /// a window (but not on a tab strip), it stays; Escape cancels; the app's only tab stays put.</summary>
    private void OnTabDroppedOutside(TabView sender, TabViewTabDroppedOutsideEventArgs args)
    {
        if (args.Tab.Tag is not SurfaceTag tag || (GetAsyncKeyState(0x1B) & 0x8000) != 0 || !GetCursorPos(out var cursor)) return;
        var point = new Windows.Graphics.PointInt32(cursor.X, cursor.Y);
        if (WindowRegistry.IsOverAnyWindow(point)) return;
        if (WindowRegistry.Windows.Count == 1 && IsOnlyTab(tag.SurfaceId)) return;
        DispatcherQueue.TryEnqueue(() => WindowRegistry.MoveSurfaceToNewWindow(tag.WorkspaceId, tag.PaneId, tag.SurfaceId, point));
    }

    [System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)]
    private struct CursorPoint { public int X; public int Y; }

    [System.Runtime.InteropServices.LibraryImport("user32.dll")]
    [return: System.Runtime.InteropServices.MarshalAs(System.Runtime.InteropServices.UnmanagedType.Bool)]
    private static partial bool GetCursorPos(out CursorPoint point);

    [System.Runtime.InteropServices.LibraryImport("user32.dll")]
    private static partial short GetAsyncKeyState(int key);

    /// <summary>Puts the window under a screen point, as a torn-off tab lands under the release point:
    /// the point falls on its tab row, a little in from the left, and the window stays on that display.</summary>
    internal void PlaceUnder(Windows.Graphics.PointInt32 point)
    {
        var size = AppWindow.Size;
        var area = Microsoft.UI.Windowing.DisplayArea.GetFromPoint(point, Microsoft.UI.Windowing.DisplayAreaFallback.Nearest).WorkArea;
        var scale = (Content?.XamlRoot?.RasterizationScale) ?? 1;
        var x = Math.Clamp(point.X - (int)(120 * scale), area.X, Math.Max(area.X, area.X + area.Width - size.Width));
        var y = Math.Clamp(point.Y - (int)(64 * scale), area.Y, Math.Max(area.Y, area.Y + area.Height - size.Height));
        AppWindow.Move(new Windows.Graphics.PointInt32(x, y));
    }

    /// <summary>Closes the window and its workspaces without asking (window.close, an emptied window, quit).</summary>
    internal void CloseWithoutAsking()
    {
        _closeConfirmed = true;
        Close();
    }

    /// <summary>Selects a surface of this window and focuses its terminal.</summary>
    internal void JumpHere(string surfaceId)
    {
        if (WorkspaceOf(surfaceId) is not { } workspace) return;
        var pane = workspace.Panes.First(item => item.Surfaces.Any(surface => surface.Id == surfaceId));
        Apply(new { command = "select_surface", workspace_id = workspace.Id, pane_id = pane.Id, surface_id = surfaceId });
        _terminals.GetValueOrDefault(surfaceId)?.FocusTerminal();
    }

    /// <summary>Takes a workspace out of this window, its terminals still running, for another
    /// window to adopt. The caller closes this window if that leaves it empty.</summary>
    internal WorkspaceTransfer TakeWorkspace(string workspaceId)
    {
        var workspace = _snapshot.Workspaces.FirstOrDefault(item => item.Id == workspaceId) ?? throw NotFound("workspace", workspaceId);
        using var document = JsonDocument.Parse(_core.SnapshotJson());
        var json = document.RootElement.GetProperty("workspaces").EnumerateArray().First(item => item.GetProperty("id").GetString() == workspaceId).Clone();
        var transfer = Release(json, workspace.Panes.SelectMany(pane => pane.Surfaces).Select(surface => surface.Id));
        _zoomedPanes.Remove(workspaceId);
        _snapshot = Dispatch(new { command = "close_workspace", workspace_id = workspaceId });
        if (_snapshot.Workspaces.Count > 0) ProjectSnapshot();
        return transfer;
    }

    /// <summary>The core's JSON for one surface (its id, session, pin and title).</summary>
    private JsonElement SurfaceJson(string workspaceId, string paneId, string surfaceId)
    {
        using var document = JsonDocument.Parse(_core.SnapshotJson());
        var surface = document.RootElement.GetProperty("workspaces").EnumerateArray()
            .Where(item => item.GetProperty("id").GetString() == workspaceId)
            .SelectMany(item => item.GetProperty("panes").EnumerateArray())
            .Where(pane => pane.GetProperty("id").GetString() == paneId)
            .SelectMany(pane => pane.GetProperty("surfaces").EnumerateArray())
            .FirstOrDefault(item => item.GetProperty("id").GetString() == surfaceId);
        if (surface.ValueKind != JsonValueKind.Object) throw NotFound("surface", surfaceId);
        return surface.Clone();
    }

    /// <summary>Takes one tab out of this window for a pane of another window; the transfer's
    /// Workspace holds the surface's JSON. The caller closes this window if that leaves it empty.</summary>
    internal WorkspaceTransfer TakeTab(string workspaceId, string paneId, string surfaceId)
    {
        var transfer = Release(SurfaceJson(workspaceId, paneId, surfaceId), [surfaceId]);
        _snapshot = Dispatch(new { command = "close_surface", workspace_id = workspaceId, pane_id = paneId, surface_id = surfaceId });
        if (_snapshot.Workspaces.Count > 0) ProjectSnapshot();
        return transfer;
    }

    /// <summary>Takes in a tab from another window, before <paramref name="beforeSurfaceId"/> (or last)
    /// in one of this window's panes, selected, its terminal carrying on here.</summary>
    internal void AdoptTab(string workspaceId, string paneId, WorkspaceTransfer tab, string? beforeSurfaceId)
    {
        _snapshot = Dispatch(new { command = "adopt_surface", workspace_id = workspaceId, pane_id = paneId, surface = tab.Workspace, before_surface_id = beforeSurfaceId });
        foreach (var terminal in tab.Terminals.Values) terminal.WorkspaceId = workspaceId;
        Absorb(tab);
        ProjectSnapshot();
    }

    internal TerminalView? TerminalById(string surfaceId) => _terminals.GetValueOrDefault(surfaceId);

    internal IEnumerable<string> SurfaceIds() => _snapshot.Workspaces.SelectMany(workspace => workspace.Panes).SelectMany(pane => pane.Surfaces).Select(surface => surface.Id);

    /// <summary>Each workspace with the name given to it (renames) and the title it shows, for workspace lifecycle frames.</summary>
    internal IEnumerable<(string Id, string? Name, string Shown)> WorkspaceNames() =>
        _snapshot.Workspaces.Select(workspace => (workspace.Id, workspace.Title, WorkspaceTitle(workspace)));

    /// <summary>The workspace holding a pane of this window, or null.</summary>
    internal string? PaneWorkspace(string paneId) =>
        _snapshot.Workspaces.FirstOrDefault(workspace => workspace.Panes.Any(pane => pane.Id == paneId))?.Id;

    /// <summary>The selected tab of one of this window's panes, or null.</summary>
    internal string? SelectedSurfaceOfPane(string paneId) =>
        _snapshot.Workspaces.SelectMany(workspace => workspace.Panes).FirstOrDefault(pane => pane.Id == paneId)?.SelectedSurfaceId;

    internal string SelectedPaneOf(string workspaceId)
    {
        var workspace = _snapshot.Workspaces.FirstOrDefault(item => item.Id == workspaceId) ?? throw NotFound("workspace", workspaceId);
        return workspace.SelectedPane?.Id ?? workspace.Panes[0].Id;
    }

    internal List<string> SurfacesOf(string workspaceId, string paneId) =>
        _snapshot.Workspaces.FirstOrDefault(workspace => workspace.Id == workspaceId)?.Panes.FirstOrDefault(pane => pane.Id == paneId)?.Surfaces.Select(surface => surface.Id).ToList() ?? [];

    /// <summary>A tab to another pane of its workspace, or to a new place in its own pane.</summary>
    internal void MoveWithinWorkspace(string workspaceId, string sourcePaneId, string targetPaneId, string surfaceId, string? beforeSurfaceId) =>
        Apply(new { command = "move_surface", workspace_id = workspaceId, source_pane_id = sourcePaneId, target_pane_id = targetPaneId, surface_id = surfaceId, before_surface_id = beforeSurfaceId });

    /// <summary>Whether the window would be left empty without this tab (its only tab).</summary>
    internal bool IsOnlyTab(string surfaceId) =>
        _snapshot.Workspaces.Count == 1 && _snapshot.Workspaces[0].Panes.Count == 1 && _snapshot.Workspaces[0].Panes[0].Surfaces.Count == 1
        && _snapshot.Workspaces[0].Panes[0].Surfaces[0].Id == surfaceId;

    /// <summary>Takes one tab out of this window as a workspace of its own (new workspace and pane
    /// ids, the same surface and session).</summary>
    internal WorkspaceTransfer TakeSurface(string workspaceId, string paneId, string surfaceId)
    {
        var surface = SurfaceJson(workspaceId, paneId, surfaceId);
        var newWorkspace = Id("workspace");
        var newPane = Id("pane");
        var node = new JsonObject
        {
            ["id"] = newWorkspace,
            ["selected_pane_id"] = newPane,
            ["panes"] = new JsonArray(new JsonObject
            {
                ["id"] = newPane,
                ["selected_surface_id"] = surfaceId,
                ["surfaces"] = new JsonArray(JsonNode.Parse(surface.GetRawText())),
            }),
            ["layout"] = new JsonObject { ["type"] = "pane", ["pane_id"] = newPane },
        };
        using var built = JsonDocument.Parse(node.ToJsonString());
        var transfer = Release(built.RootElement.Clone(), [surfaceId]);
        foreach (var terminal in transfer.Terminals.Values) terminal.WorkspaceId = newWorkspace;
        _snapshot = Dispatch(new { command = "close_surface", workspace_id = workspaceId, pane_id = paneId, surface_id = surfaceId });
        if (_snapshot.Workspaces.Count > 0) ProjectSnapshot();
        return transfer;
    }

    /// <summary>Lets go of these surfaces' terminals and panels without ending them.</summary>
    private WorkspaceTransfer Release(JsonElement workspace, IEnumerable<string> surfaceIds)
    {
        var transfer = new WorkspaceTransfer(workspace, new(StringComparer.Ordinal), new(StringComparer.Ordinal), new(StringComparer.Ordinal), new(StringComparer.Ordinal), new(StringComparer.Ordinal));
        foreach (var id in surfaceIds)
        {
            if (_terminals.Remove(id, out var terminal))
            {
                Unwire(terminal);
                if (terminal.Parent is Border host) host.Child = null;
                transfer.Terminals[id] = terminal;
            }
            if (_restore.Remove(id, out var pending)) transfer.Pending[id] = pending;
            if (_panels.Remove(id, out var panel))
            {
                if (panel is MarkdownPanel markdown) transfer.Markdown[id] = markdown.FilePath;
                if (panel is ReviewPanel review) transfer.Reviews[id] = new SessionReview(review.SourceSurfaceId, review.Mode, review.BaseBranch);
                panel.Dispose();
            }
            if (_restorePanels.Remove(id, out var path)) transfer.Markdown[id] = path;
            if (_restoreReviews.Remove(id, out var saved)) transfer.Reviews[id] = saved;
            if (_branches.Remove(id, out var branch)) transfer.Branches[id] = branch;
            _tabItems.Remove(id);
            _lastStatusState.Remove(id);
            _detectedAgents.Remove(id);
        }
        return transfer;
    }

    /// <summary>Takes in a workspace from another window, selected, its terminals carrying on here.</summary>
    internal void AdoptWorkspace(WorkspaceTransfer transfer)
    {
        _snapshot = Dispatch(new { command = "adopt_workspace", workspace = transfer.Workspace });
        Absorb(transfer);
        ProjectSnapshot();
    }

    /// <summary>The terminals, pending restores and panels that came with a transfer.</summary>
    private void Absorb(WorkspaceTransfer transfer)
    {
        foreach (var (id, terminal) in transfer.Terminals)
        {
            _terminals[id] = terminal;
            Wire(terminal);
        }
        foreach (var (id, pending) in transfer.Pending) _restore[id] = pending;
        foreach (var (id, path) in transfer.Markdown) _restorePanels[id] = path;
        foreach (var (id, review) in transfer.Reviews) _restoreReviews[id] = review;
        foreach (var (id, branch) in transfer.Branches) _branches[id] = branch;
    }

    private void Wire(TerminalView terminal)
    {
        terminal.CwdChanged += OnTerminalCwdChanged;
        terminal.Exited += OnTerminalExited;
        terminal.TitleChanged += OnTerminalHeaderChanged;
        terminal.ProgramStatusChanged += OnTerminalHeaderChanged;
        terminal.NotificationRequested += OnTerminalNotification;
        terminal.RouteStateChanged += OnRouteTransition;
    }

    private void Unwire(TerminalView terminal)
    {
        terminal.CwdChanged -= OnTerminalCwdChanged;
        terminal.Exited -= OnTerminalExited;
        terminal.TitleChanged -= OnTerminalHeaderChanged;
        terminal.ProgramStatusChanged -= OnTerminalHeaderChanged;
        terminal.NotificationRequested -= OnTerminalNotification;
        terminal.RouteStateChanged -= OnRouteTransition;
    }

    /// <summary>The sidebar's Move to Window menu, as on macOS: a new window, then every window (this
    /// one disabled). Several workspaces go together, into one new window.</summary>
    private MenuFlyoutSubItem MoveToWindowMenu(List<string> workspaceIds)
    {
        var menu = new MenuFlyoutSubItem { Text = Localizer.Get(workspaceIds.Count > 1 ? "MoveWorkspacesToWindow" : "MoveToWindow") };
        void Move(MainWindow? target)
        {
            foreach (var id in workspaceIds) target = WindowRegistry.MoveWorkspace(id, target);
        }
        menu.Items.Add(MenuItem(Localizer.Get("NewWindow"), () => Move(null)));
        var windows = WindowRegistry.Windows.ToList();
        if (windows.Count > 1) menu.Items.Add(new MenuFlyoutSeparator());
        for (var index = 0; windows.Count > 1 && index < windows.Count; index++)
        {
            var target = windows[index];
            var title = target.SelectedWorkspaceTitle;
            var item = MenuItem(title is null ? string.Format(Localizer.Get("WindowNumber"), index + 1) : string.Format(Localizer.Get("WindowNumberTitled"), index + 1, title), () => Move(target));
            item.IsEnabled = target != this;
            menu.Items.Add(item);
        }
        return menu;
    }

    internal string? SelectedWorkspaceTitle => SelectedWorkspace() is { } workspace ? WorkspaceTitle(workspace) : null;
}
