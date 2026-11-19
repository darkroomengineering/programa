using System.Text.Json;
using Microsoft.UI.Windowing;

namespace Programa;

/// <summary>Session restore, as on macOS: relaunch brings back every window with its workspaces,
/// splits, tabs and their names, sidebar, frame, and each terminal's directory, recent output and
/// font size. <see cref="WindowRegistry"/> saves every window every 30 seconds and as windows close,
/// so a crash loses at most half a minute.</summary>
public sealed partial class MainWindow
{
    /// <summary>Saved terminals not created yet (their workspace has not been shown since launch).</summary>
    private Dictionary<string, SessionTerminal> _restore = new(StringComparer.Ordinal);

    /// <summary>Seeds the core with a saved window; false when it does not validate or has no workspace.</summary>
    private bool RestoreSession(SavedSession saved)
    {
        try
        {
            _snapshot = _core.Seed(saved.Core);
        }
        catch (Exception error) when (error is CoreCommandException or JsonException or InvalidDataException)
        {
            LaunchLog.Write($"session: not restored: {error.Message}");
            return false;
        }
        if (_snapshot.Workspaces.Count == 0) return false;
        if (saved.WindowId is { Length: > 0 } windowId) WindowId = windowId;
        _restore = new Dictionary<string, SessionTerminal>(saved.Terminals, StringComparer.Ordinal);
        _restorePanels = new Dictionary<string, string>(saved.MarkdownPanels ?? [], StringComparer.Ordinal);
        _restoreReviews = new Dictionary<string, SessionReview>(saved.ReviewPanels ?? [], StringComparer.Ordinal);
        _sidebarVisible = saved.SidebarVisible;
        _sidebarWidth = Math.Clamp(saved.SidebarWidth, 160, 480);
        if (saved.Window is { } window) ApplyWindowPlacement(window);
        return true;
    }

    /// <summary>The saved terminal for a surface being created, consumed once.</summary>
    private SessionTerminal? TakeRestoredTerminal(string surfaceId) =>
        _restore.Remove(surfaceId, out var saved) ? saved : null;

    /// <summary>This window as the session saves it, or null when it has no workspace.</summary>
    internal SavedSession? CaptureSession()
    {
        if (_snapshot.Workspaces.Count == 0) return null;
        var terminals = new Dictionary<string, SessionTerminal>(StringComparer.Ordinal);
        var busyShells = ProcessTree.ChildrenOf(_terminals.Values.Select(terminal => terminal.ShellPid).Where(pid => pid != 0).ToHashSet()).Keys.ToHashSet();
        foreach (var surface in _snapshot.Workspaces.SelectMany(workspace => workspace.Panes).SelectMany(pane => pane.Surfaces))
        {
            if (_terminals.TryGetValue(surface.Id, out var terminal))
            {
                var text = terminal.OutputText(SessionStore.SavedLines);
                // An idle shell's last line is its prompt, which the restored shell prints again.
                if (terminal.ShellPid != 0 && !busyShells.Contains(terminal.ShellPid)) text = SessionStore.WithoutLastLine(text);
                if (text.Length == 0) text = terminal.PendingRestoreText ?? string.Empty;
                terminals[surface.Id] = new SessionTerminal(terminal.WorkingDirectory, text.Length > 0 ? text : null, terminal.FontSizeOverride, terminal.LastAgentSession);
            }
            else if (_restore.TryGetValue(surface.Id, out var pending))
            {
                terminals[surface.Id] = pending;
            }
        }
        try
        {
            using var core = JsonDocument.Parse(_core.SnapshotJson());
            return new SavedSession(SessionStore.CurrentVersion, core.RootElement.Clone(), _sidebarVisible, _sidebarWidth, CurrentWindowPlacement(), terminals, SavedPanels(), SavedReviews(), WindowId);
        }
        catch (Exception error) when (error is CoreCommandException or JsonException)
        {
            LaunchLog.Write($"session: not saved: {error.Message}");
            return null;
        }
    }

    private SessionWindow CurrentWindowPlacement()
    {
        var position = AppWindow.Position;
        var size = AppWindow.Size;
        var maximized = AppWindow.Presenter is OverlappedPresenter { State: OverlappedPresenterState.Maximized };
        return new SessionWindow(position.X, position.Y, size.Width, size.Height, maximized);
    }

    /// <summary>Puts the window back where it was, unless that spot is no longer on any display.</summary>
    private void ApplyWindowPlacement(SessionWindow saved)
    {
        var frame = new Windows.Graphics.RectInt32(saved.X, saved.Y, saved.Width, saved.Height);
        if (saved.Width < 200 || saved.Height < 150 || DisplayArea.GetFromRect(frame, DisplayAreaFallback.None) is null) return;
        AppWindow.MoveAndResize(frame);
        if (saved.Maximized && AppWindow.Presenter is OverlappedPresenter presenter) presenter.Maximize();
    }
}
