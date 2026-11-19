using Microsoft.UI.Xaml.Controls;

namespace Programa;

/// <summary>Turn checkpoints, as on macOS: when an agent starts a turn (its status goes to Working
/// from idle or done, not from a prompt it was waiting on), its repository's files are saved
/// (<see cref="Checkpoints"/>), and the review panel's Revert Files to Before Last Turn puts them back.
/// Closing a workspace deletes its checkpoints.</summary>
public sealed partial class MainWindow
{
    /// <summary>The last agent state seen per terminal, to find where a turn starts.</summary>
    private readonly Dictionary<string, string?> _turnStates = new(StringComparer.Ordinal);

    private void NoteTurn(TerminalView terminal)
    {
        var state = terminal.EffectiveStatus?.State;
        var previous = _turnStates.GetValueOrDefault(terminal.SurfaceId);
        _turnStates[terminal.SurfaceId] = state;
        // A prompt answered mid-turn (blocked to working) is the same turn.
        if (state != "working" || previous is "working" or "blocked" || terminal.WorkingDirectory is not { } directory) return;
        var (workspaceId, surfaceId) = (terminal.WorkspaceId, terminal.SurfaceId);
        _ = Task.Run(async () =>
        {
            await Checkpoints.Gate.WaitAsync();
            try { Checkpoints.Save(directory, workspaceId, surfaceId, Checkpoints.TurnStart); }
            catch (Checkpoints.CheckpointException error) { LaunchLog.Write($"checkpoint: not saved: {error.Message}"); }
            finally { Checkpoints.Gate.Release(); }
        });
    }

    /// <summary>The review panel's revert button: asks, then puts the reviewed terminal's files back
    /// as its newest checkpoint has them, and refreshes the panel.</summary>
    private async Task RevertToCheckpointAsync(ReviewPanel panel)
    {
        if (_dialogOpen || Root.XamlRoot is null || panel.CheckpointKind is not { } kind) return;
        if (_terminals.GetValueOrDefault(panel.SourceSurfaceId) is not { WorkingDirectory: { } directory } terminal) return;
        var undo = kind == Checkpoints.BeforeRevert;
        var dialog = new ContentDialog
        {
            XamlRoot = Root.XamlRoot,
            Title = Localizer.Get(undo ? "ReviewUndoRevert" : "ReviewRevert"),
            Content = Localizer.Get(undo ? "ReviewUndoMessage" : "ReviewRevertMessage"),
            PrimaryButtonText = Localizer.Get("ReviewRevertConfirm"),
            CloseButtonText = Localizer.Get("Cancel"),
            DefaultButton = ContentDialogButton.Close,
        };
        _dialogOpen = true;
        try { if (await dialog.ShowAsync() != ContentDialogResult.Primary) return; }
        finally { _dialogOpen = false; }
        var (workspaceId, surfaceId) = (terminal.WorkspaceId, terminal.SurfaceId);
        try
        {
            await Task.Run(async () =>
            {
                await Checkpoints.Gate.WaitAsync();
                try { Checkpoints.RestoreNewest(directory, workspaceId, surfaceId); }
                finally { Checkpoints.Gate.Release(); }
            });
        }
        catch (Checkpoints.CheckpointException error)
        {
            await ShowErrorAsync(Localizer.Get("ReviewRevertFailed"), error.Message);
        }
        await panel.RefreshAsync();
    }

    /// <summary>Deletes the checkpoints of workspaces that closed, in each closed terminal's repository.</summary>
    private void DeleteCheckpointsOfClosedWorkspaces(IEnumerable<TerminalView> closed)
    {
        var alive = _snapshot.Workspaces.Select(workspace => workspace.Id).ToHashSet(StringComparer.Ordinal);
        var gone = closed.Where(terminal => !alive.Contains(terminal.WorkspaceId) && terminal.WorkingDirectory is not null)
            .Select(terminal => (terminal.WorkspaceId, Directory: terminal.WorkingDirectory!)).Distinct().ToList();
        foreach (var terminal in closed) _turnStates.Remove(terminal.SurfaceId);
        if (gone.Count == 0) return;
        _ = Task.Run(async () =>
        {
            await Checkpoints.Gate.WaitAsync();
            try { foreach (var (workspaceId, directory) in gone) Checkpoints.DeleteWorkspace(directory, workspaceId); }
            catch (Checkpoints.CheckpointException) { }
            finally { Checkpoints.Gate.Release(); }
        });
    }
}
