using Microsoft.UI.Xaml.Controls;

namespace Programa;

/// <summary>Asks before ending running programs, as on macOS: closing the window (which quits on
/// Windows) or a workspace asks when a shell still runs something, a pinned workspace always asks, and
/// closing a workspace's last tab asks (app.confirmCloseLastPane). Closing other tabs, a shell exiting,
/// and control commands close without asking.</summary>
public sealed partial class MainWindow
{
    private bool _closeConfirmed;

    private void InitializeCloseConfirmation()
    {
        AppWindow.Closing += async (_, args) =>
        {
            if (_closeConfirmed) return;
            // With other windows open, closing this one ends only its workspaces (macOS Close Window);
            // the last window closing is a quit, which ends only what the terminal host does not run.
            var last = WindowRegistry.Windows.Count <= 1;
            var running = RunningPrograms(last ? _terminals.Values.Where(terminal => !terminal.Hosted) : _terminals.Values);
            if (running.Count == 0) return;
            args.Cancel = true;
            if (!await ConfirmEndingAsync(Localizer.Get(last ? "QuitTitle" : "CloseWindowTitle"), Localizer.Get(last ? "QuitMessage" : "CloseWindowMessage"), Localizer.Get(last ? "Quit" : "Close"), running)) return;
            _closeConfirmed = true;
            Close();
        };
    }

    /// <summary>The palette's Close Window: asks like the close button, then ends this window's workspaces.</summary>
    private async Task CloseWindowAsync()
    {
        var last = WindowRegistry.Windows.Count <= 1;
        var running = RunningPrograms(last ? _terminals.Values.Where(terminal => !terminal.Hosted) : _terminals.Values);
        if (running.Count > 0 && !await ConfirmEndingAsync(Localizer.Get(last ? "QuitTitle" : "CloseWindowTitle"), Localizer.Get(last ? "QuitMessage" : "CloseWindowMessage"), Localizer.Get(last ? "Quit" : "Close"), running)) return;
        CloseWithoutAsking();
    }

    /// <summary>Quit: asks once (always with app.warnBeforeQuit, else only about programs a quit would
    /// end: those not running in the terminal host), then saves every window and closes them all.</summary>
    private async Task QuitAsync()
    {
        var running = RunningPrograms(WindowRegistry.Windows.SelectMany(window => window._terminals.Values).Where(terminal => !terminal.Hosted));
        var ask = running.Count > 0 || AppSettings.Load().WarnBeforeQuit;
        if (ask && !await ConfirmEndingAsync(Localizer.Get("QuitTitle"), Localizer.Get(running.Count > 0 ? "QuitMessage" : "QuitPlainMessage"), Localizer.Get("Quit"), running)) return;
        WindowRegistry.Quit();
    }

    /// <summary>One program name per terminal whose shell has a child process.</summary>
    private static List<string> RunningPrograms(IEnumerable<TerminalView> terminals)
    {
        var shells = terminals.Select(terminal => terminal.ShellPid).Where(pid => pid != 0).ToHashSet();
        return ProcessTree.ChildrenOf(shells).Values.Select(names => Path.GetFileNameWithoutExtension(names[0])).ToList();
    }

    private async Task<bool> ConfirmEndingAsync(string title, string messageFormat, string action, List<string> running)
    {
        if (_dialogOpen || Root.XamlRoot is null) return false;
        var programs = string.Join(", ", running.Distinct(StringComparer.OrdinalIgnoreCase).Take(3));
        var dialog = new ContentDialog
        {
            XamlRoot = Root.XamlRoot,
            Title = title,
            Content = string.Format(messageFormat, programs, running.Count),
            PrimaryButtonText = action,
            CloseButtonText = Localizer.Get("Cancel"),
            DefaultButton = ContentDialogButton.Close,
        };
        _dialogOpen = true;
        try { return await dialog.ShowAsync() == ContentDialogResult.Primary; }
        finally { _dialogOpen = false; }
    }

    /// <summary>Whether a workspace may close, asked as macOS asks (TabManager.closeWorkspaceWithConfirmation):
    /// a pinned workspace always, one whose shells run something, and, when what closes is its last tab,
    /// an idle one too unless app.confirmCloseLastPane is off. The last workspace closes the window.</summary>
    private async Task<bool> MayCloseWorkspaceAsync(WorkspaceSnapshot workspace, bool fromLastTab = false)
    {
        var last = _snapshot.Workspaces.Count <= 1;
        var terminals = workspace.Panes.SelectMany(pane => pane.Surfaces).Select(surface => _terminals.GetValueOrDefault(surface.Id)).OfType<TerminalView>();
        var running = RunningPrograms(terminals);
        var (title, message) =
            workspace.Pinned ? ("ClosePinnedWorkspaceTitle", "ClosePinnedWorkspaceMessage")
            : running.Count > 0 ? (last ? ("CloseLastWorkspaceTitle", "CloseLastWorkspaceMessage") : ("CloseWorkspaceTitle", "CloseWorkspaceMessage"))
            : fromLastTab && AppSettings.Load().ConfirmCloseLastPane ? (last ? ("CloseWindowTitle", "CloseLastTabWindowMessage") : ("CloseWorkspaceTitle", "CloseLastTabMessage"))
            : (null, null);
        if (title is null || message is null) return true;
        if (!await ConfirmEndingAsync(Localizer.Get(title), Localizer.Get(message), Localizer.Get("Close"), running)) return false;
        if (last) _closeConfirmed = true;
        return true;
    }

    private async void CloseWorkspace(string workspaceId)
    {
        if (_snapshot.Workspaces.FirstOrDefault(item => item.Id == workspaceId) is not { } workspace) return;
        if (await MayCloseWorkspaceAsync(workspace)) Apply(new { command = "close_workspace", workspace_id = workspaceId });
    }

    /// <summary>Closes a tab; closing a workspace's last tab closes the workspace, and asks first.</summary>
    private async void CloseSurface(string workspaceId, string paneId, string surfaceId)
    {
        if (_snapshot.Workspaces.FirstOrDefault(item => item.Id == workspaceId) is not { } workspace) return;
        var onlyTab = workspace.Panes.Count == 1 && workspace.Panes[0].Surfaces.Count == 1;
        if (onlyTab && !await MayCloseWorkspaceAsync(workspace, fromLastTab: true)) return;
        Apply(new { command = "close_surface", workspace_id = workspaceId, pane_id = paneId, surface_id = surfaceId });
    }
}
