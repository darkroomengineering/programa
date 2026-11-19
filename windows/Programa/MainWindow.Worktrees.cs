using System.Text.Json;

namespace Programa;

/// <summary>`worktree.create/open/remove/list`, as on macOS: a git worktree opens as its own
/// workspace, named after its branch and started in its directory. A workspace is open on a
/// worktree when one of its terminals is inside it. Nothing takes focus unless `focus` is true.</summary>
public sealed partial class MainWindow
{
    private async Task<object?> HandleWorktreeAsync(string method, JsonElement p)
    {
        try
        {
            var repo = Worktrees.RepoRoot(Required(p, "repo"));
            switch (method)
            {
                case "worktree.list":
                    var entries = Worktrees.List(repo);
                    return await OnUiThread(() => new
                    {
                        repo,
                        worktrees = entries.Select(entry =>
                        {
                            var id = WorkspaceOn(entry.Path);
                            return new { path = entry.Path, branch = entry.Branch, head = entry.Head, is_open = id is not null, workspace_id = id };
                        }).ToList(),
                    });
                case "worktree.create":
                    // The layout is checked first, so a missing one creates nothing.
                    LayoutNode? layout = null;
                    if (Text(p, "layout") is { } name)
                        layout = Layouts.Find(name)?.Layout ?? throw new ControlException("layout_not_found", $"No layout named '{name}'.");
                    var created = Worktrees.Create(repo, Required(p, "branch"), Text(p, "base"), Text(p, "path"));
                    // The first worktree git lists is the main checkout, whose workspace the new one nests under.
                    var mainCheckout = Worktrees.List(repo)[0].Path;
                    return await OnUiThread(() => OpenWorktree(repo, created, Flag(p, "focus"), layout, Text(p, "initial_command"), mainCheckout));
                case "worktree.open":
                    var found = Worktrees.Find(repo, Text(p, "path"), Text(p, "branch") ?? (Text(p, "path") is null ? Required(p, "branch") : null));
                    var main = Worktrees.List(repo)[0].Path;
                    return await OnUiThread(() => OpenWorktree(repo, found, Flag(p, "focus"), null, Text(p, "initial_command"), main));
                default: // worktree.remove
                    var target = Worktrees.Find(repo, Text(p, "path"), Text(p, "branch") ?? (Text(p, "path") is null ? Required(p, "branch") : null));
                    if (Worktrees.SamePath(target.Path, Worktrees.List(repo)[0].Path))
                        throw new ControlException("invalid_params", "The repository's main worktree cannot be removed.");
                    if (!Flag(p, "force") && Worktrees.IsDirty(target.Path))
                        throw new ControlException("worktree_dirty", $"{target.Path} has uncommitted changes; pass force to remove it anyway.");
                    // Its shells hold the directory open on Windows, so the workspace closes first.
                    var closed = await OnUiThread(() => CloseWorkspacesOn(target.Path));
                    Worktrees.Remove(repo, target, Flag(p, "force"));
                    return new { removed = true, closed_workspace_id = closed };
            }
        }
        catch (Worktrees.GitException error)
        {
            throw new ControlException(error.Code, error.Message);
        }
    }

    /// <summary>The first workspace with a terminal inside <paramref name="path"/>.</summary>
    private string? WorkspaceOn(string path) =>
        _snapshot.Workspaces.FirstOrDefault(workspace => workspace.Panes.SelectMany(pane => pane.Surfaces)
            .Any(surface => Worktrees.Contains(path, _terminals.GetValueOrDefault(surface.Id)?.WorkingDirectory ?? _restore.GetValueOrDefault(surface.Id)?.Cwd)))?.Id;

    /// <summary>Opens the worktree as a workspace (or finds the one on it), with a saved layout rooted at
    /// the worktree if given, and runs <paramref name="initialCommand"/> (a Windows extension `race`
    /// uses) in its focused terminal once the shell is ready.</summary>
    private object OpenWorktree(string repo, WorktreeEntry entry, bool focus, LayoutNode? layout = null, string? initialCommand = null, string? mainCheckout = null)
    {
        var workspaceId = WorkspaceOn(entry.Path);
        if (workspaceId is null && layout is not null)
        {
            workspaceId = ApplyLayout(layout, null, entry.Path, focus, title: entry.Branch ?? Path.GetFileName(entry.Path));
        }
        else if (workspaceId is null)
        {
            workspaceId = Id("workspace");
            var create = new { command = "create_workspace", workspace_id = workspaceId, pane_id = Id("pane"), surface_id = Id("surface"), session_id = Id("session") };
            if (focus)
            {
                _nextTerminalDirectory = entry.Path;
                Apply(create);
            }
            else
            {
                var surfaceId = create.surface_id;
                CreateKeepingSelection(create, workspaceId, surfaceId, entry.Path, null);
            }
            Apply(new { command = "rename_workspace", workspace_id = workspaceId, title = entry.Branch ?? Path.GetFileName(entry.Path) });
        }
        else if (focus)
        {
            Apply(new { command = "select_workspace", workspace_id = workspaceId });
        }
        // A worktree other than the main checkout nests under the main checkout's workspace.
        if (mainCheckout is not null && !Worktrees.SamePath(mainCheckout, entry.Path)) NestUnderRepository(workspaceId, mainCheckout);
        var id = workspaceId;
        if (initialCommand is { Length: > 0 } && _snapshot.Workspaces.First(item => item.Id == id).SelectedPane?.SelectedSurfaceId is { } focused && !IsPanel(focused))
            TerminalFor(workspaceId, focused).QueueCommand(initialCommand);
        return new { worktree = new { path = entry.Path, branch = entry.Branch, repo }, workspace_id = workspaceId };
    }

    /// <summary>Closes every workspace open on the worktree; the window keeps a fresh one if that was all.</summary>
    private string? CloseWorkspacesOn(string path)
    {
        string? first = null;
        while (WorkspaceOn(path) is { } id)
        {
            first ??= id;
            if (_snapshot.Workspaces.Count == 1) NewWorkspace();
            Apply(new { command = "close_workspace", workspace_id = id });
            // Not kept for Reopen Tab: their shells would hold the worktree open.
            foreach (var closed in _closedTerminals.Where(item => item.WorkspaceId == id).ToList())
            {
                _closedTerminals.Remove(closed);
                closed.Terminal.Dispose();
            }
        }
        return first;
    }
}
