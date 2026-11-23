using System.Text.Json;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Windows.UI;

namespace Programa;

/// <summary>The workspace context menu and `workspace.action`, as on macOS: pin, rename, description,
/// worktree folder, color, move up/down/to top/to window, close, close others/above/below, mark read.</summary>
public sealed partial class MainWindow
{
    /// <summary>The macOS default workspace color palette (names are palette data, as on macOS).</summary>
    private static readonly (string Name, string Hex)[] WorkspaceColors =
    [
        ("Red", "#C0392B"), ("Crimson", "#922B21"), ("Orange", "#A04000"), ("Amber", "#7D6608"),
        ("Olive", "#4A5C18"), ("Green", "#196F3D"), ("Teal", "#006B6B"), ("Aqua", "#0E6B8C"),
        ("Blue", "#1565C0"), ("Navy", "#1A5276"), ("Indigo", "#283593"), ("Purple", "#6A1B9A"),
        ("Magenta", "#AD1457"), ("Rose", "#880E4F"), ("Brown", "#7B3F00"), ("Charcoal", "#3E4B5E"),
    ];

    private static readonly string SwatchGlyph = char.ConvertFromUtf32(0xE91F);

    private static readonly string[] WorkspaceActions =
    [
        "pin", "unpin", "rename", "clear_name", "set_description", "clear_description", "move_up", "move_down", "move_top",
        "close_others", "close_above", "close_below", "mark_read", "set_color", "clear_color",
    ];

    /// <summary>The row menu, built as it opens, in the macOS order (TabItemView.buildWorkspaceContextMenu).
    /// With several rows picked it acts on all of them; Rename, Move Up/Down and Close Above/Below act on
    /// the row it opened on, and items that would do nothing at the list's edges are disabled.</summary>
    private void FillWorkspaceMenu(MenuFlyout menu, string id)
    {
        menu.Items.Clear();
        var workspaces = _snapshot.Workspaces;
        var index = workspaces.ToList().FindIndex(item => item.Id == id);
        if (index < 0) return;
        var workspace = workspaces[index];
        var targets = MenuTargets(id);
        var multi = targets.Count > 1;
        var pin = !workspace.Pinned;
        menu.Items.Add(RowMenuItem(Localizer.Get(pin ? multi ? "SidebarPinWorkspaces" : "PinWorkspace" : multi ? "SidebarUnpinWorkspaces" : "UnpinWorkspace"),
            // Unpinning goes in reverse: each lands just after the pinned ones, so the rows keep their order.
            () => { foreach (var target in pin ? targets : Enumerable.Reverse(targets)) TryWorkspaceAction(target, pin ? "pin" : "unpin"); }));
        menu.Items.Add(RowMenuItem(Localizer.Get("SidebarRenameWorkspace"), () => _ = RenameWorkspaceAsync(id), shortcut: "rename_workspace"));
        if (workspace.Title is not null) menu.Items.Add(RowMenuItem(Localizer.Get("RemoveCustomWorkspaceName"), () => TryWorkspaceAction(id, "clear_name")));
        if (!multi)
        {
            menu.Items.Add(RowMenuItem(Localizer.Get("EditWorkspaceDescription"), () => _ = EditDescriptionAsync(id), shortcut: "edit_workspace_description"));
            if (workspace.Description is not null) menu.Items.Add(RowMenuItem(Localizer.Get("ClearWorkspaceDescription"), () => TryWorkspaceAction(id, "clear_description")));
        }
        if (!multi && workspace.ParentId is null)
        {
            menu.Items.Add(new MenuFlyoutSeparator());
            if (IsWorktreeFolder(workspace))
            {
                menu.Items.Add(RowMenuItem(Localizer.Get("NewWorktreeWorkspace"), () => _ = NewWorktreeWorkspaceAsync(id)));
                if (HasChildren(workspace))
                {
                    var collapse = !workspace.Collapsed;
                    menu.Items.Add(RowMenuItem(Localizer.Get(collapse ? "CollapseWorktreeFolder" : "ExpandWorktreeFolder"), () => Apply(new { command = "set_workspace_collapsed", workspace_id = id, collapsed = collapse })));
                }
                menu.Items.Add(RowMenuItem(Localizer.Get("StopUsingAsWorktreeFolder"), () => Apply(new { command = "set_workspace_worktree_folder", workspace_id = id, repo = (string?)null })));
            }
            else menu.Items.Add(RowMenuItem(Localizer.Get("UseAsWorktreeFolder"), () => _ = UseAsWorktreeFolderAsync(id)));
        }
        menu.Items.Add(ColorMenu(workspace, targets));
        menu.Items.Add(new MenuFlyoutSeparator());
        menu.Items.Add(RowMenuItem(Localizer.Get("MoveUp"), () => TryWorkspaceAction(id, "move_up"), enabled: index != 0));
        menu.Items.Add(RowMenuItem(Localizer.Get("MoveDown"), () => TryWorkspaceAction(id, "move_down"), enabled: index < workspaces.Count - 1));
        // In reverse, so the picked rows keep their order at the top.
        menu.Items.Add(RowMenuItem(Localizer.Get("MoveToTop"), () => { foreach (var target in Enumerable.Reverse(targets)) TryWorkspaceAction(target, "move_top"); }));
        menu.Items.Add(MoveToWindowMenu(targets));
        menu.Items.Add(new MenuFlyoutSeparator());
        menu.Items.Add(RowMenuItem(Localizer.Get(multi ? "SidebarCloseWorkspaces" : "SidebarCloseWorkspace"), () => _ = CloseWorkspacesAsync(targets), shortcut: "close_workspace"));
        menu.Items.Add(RowMenuItem(Localizer.Get("CloseOtherWorkspaces"), () => _ = CloseWorkspacesAsync([.. workspaces.Select(item => item.Id).Where(other => !targets.Contains(other))]),
            enabled: workspaces.Count > 1 && targets.Count != workspaces.Count));
        menu.Items.Add(RowMenuItem(Localizer.Get("CloseWorkspacesBelow"), () => _ = CloseWorkspacesAsync([.. workspaces.Skip(index + 1).Select(item => item.Id)]), enabled: index < workspaces.Count - 1));
        menu.Items.Add(RowMenuItem(Localizer.Get("CloseWorkspacesAbove"), () => _ = CloseWorkspacesAsync([.. workspaces.Take(index).Select(item => item.Id)]), enabled: index != 0));
    }

    /// <summary>A menu item showing its current shortcut, as macOS menu items do.</summary>
    private MenuFlyoutItem RowMenuItem(string text, Action handler, bool enabled = true, string? shortcut = null)
    {
        var item = MenuItem(text, handler);
        item.IsEnabled = enabled;
        item.Tag = handler; // debug.sidebar.menu runs it
        if (shortcut is not null && _shortcuts.Values.GetValueOrDefault(shortcut) is { Length: > 0 } binding) item.KeyboardAcceleratorTextOverride = ShortcutSettings.Display(binding);
        return item;
    }

    private MenuFlyoutSubItem ColorMenu(WorkspaceSnapshot workspace, List<string> targets)
    {
        var colors = new MenuFlyoutSubItem { Text = Localizer.Get("WorkspaceColor") };
        if (workspace.Color is not null)
            colors.Items.Add(RowMenuItem(Localizer.Get("ClearColor"), () => { foreach (var target in targets) TryWorkspaceAction(target, "clear_color"); }));
        colors.Items.Add(RowMenuItem(Localizer.Get("ChooseCustomColor"), () => _ = ChooseCustomColorAsync(workspace, targets)));
        colors.Items.Add(new MenuFlyoutSeparator());
        foreach (var (name, hex) in WorkspaceColors)
        {
            var item = RowMenuItem(name, () => { foreach (var target in targets) TryWorkspaceAction(target, "set_color", hex); });
            item.Icon = new FontIcon { Glyph = SwatchGlyph, Foreground = new SolidColorBrush(ParseColor(hex)) };
            colors.Items.Add(item);
        }
        return colors;
    }

    /// <summary>#RRGGBB from what was typed (the # is optional), or null.</summary>
    internal static string? NormalizeHexColor(string text)
    {
        var hex = text.Trim().TrimStart('#');
        return hex.Length == 6 && hex.All(char.IsAsciiHexDigit) ? "#" + hex.ToUpperInvariant() : null;
    }

    private async Task ChooseCustomColorAsync(WorkspaceSnapshot workspace, List<string> targets)
    {
        if (_dialogOpen || Root.XamlRoot is null) return;
        var box = new TextBox { Text = workspace.Color ?? string.Empty, PlaceholderText = "#1565C0", MinWidth = 240 };
        box.Loaded += (_, _) => { box.Focus(FocusState.Programmatic); box.SelectAll(); };
        var content = new StackPanel { Spacing = 8 };
        content.Children.Add(new TextBlock { Text = Localizer.Get("CustomColorMessage"), TextWrapping = TextWrapping.Wrap });
        content.Children.Add(box);
        var dialog = new ContentDialog { XamlRoot = Root.XamlRoot, Title = Localizer.Get("CustomColorTitle"), Content = content, PrimaryButtonText = Localizer.Get("CustomColorApply"), CloseButtonText = Localizer.Get("Cancel"), DefaultButton = ContentDialogButton.Primary };
        _dialogOpen = true;
        ContentDialogResult result;
        try { result = await dialog.ShowAsync(); }
        finally { _dialogOpen = false; }
        if (result != ContentDialogResult.Primary) return;
        if (NormalizeHexColor(box.Text) is not { } hex)
        {
            var typed = box.Text.Trim();
            await ShowErrorAsync(Localizer.Get("InvalidColorTitle"), typed.Length == 0 ? Localizer.Get("CustomColorMessage") : string.Format(Localizer.Get("InvalidColorMessage"), typed));
            return;
        }
        foreach (var target in targets) TryWorkspaceAction(target, "set_color", hex);
    }

    /// <summary>Closes the workspaces, asking once for several (macOS closeWorkspacesWithConfirmation)
    /// and as for one workspace when there is one.</summary>
    private async Task CloseWorkspacesAsync(List<string> ids)
    {
        var closing = _snapshot.Workspaces.Where(item => ids.Contains(item.Id)).ToList();
        if (closing.Count == 0) return;
        if (closing.Count == 1)
        {
            CloseWorkspace(closing[0].Id);
            return;
        }
        if (_dialogOpen || Root.XamlRoot is null) return;
        var all = closing.Count == _snapshot.Workspaces.Count;
        var titles = string.Join("\n", closing.Select(item => "• " + WorkspaceTitle(item).ReplaceLineEndings(" ").Trim()));
        var dialog = new ContentDialog
        {
            XamlRoot = Root.XamlRoot,
            Title = Localizer.Get(all ? "CloseWindowTitle" : "CloseWorkspacesTitle"),
            Content = new ScrollViewer { Content = new TextBlock { Text = string.Format(Localizer.Get(all ? "CloseWorkspacesWindowMessage" : "CloseWorkspacesMessage"), closing.Count, titles), TextWrapping = TextWrapping.Wrap }, MaxHeight = 320 },
            PrimaryButtonText = Localizer.Get("Close"),
            CloseButtonText = Localizer.Get("Cancel"),
            DefaultButton = ContentDialogButton.Primary,
        };
        _dialogOpen = true;
        ContentDialogResult result;
        try { result = await dialog.ShowAsync(); }
        finally { _dialogOpen = false; }
        if (result != ContentDialogResult.Primary) return;
        if (all) _closeConfirmed = true;
        try
        {
            foreach (var workspace in closing.Where(item => _snapshot.Workspaces.Any(open => open.Id == item.Id)))
                _snapshot = Dispatch(new { command = "close_workspace", workspace_id = workspace.Id });
        }
        catch (Exception error) { _ = ShowErrorAsync(Localizer.Get("CoreError"), error.Message); }
        if (_snapshot.Workspaces.Count == 0) Close();
        else ProjectSnapshot();
    }

    /// <summary>The main checkout of the repository <paramref name="directory"/> is in, or null outside one. Runs git.</summary>
    private static string? MainCheckout(string? directory)
    {
        if (directory is null) return null;
        try
        {
            var root = Worktrees.RepoRoot(directory);
            return Worktrees.List(root).FirstOrDefault()?.Path ?? root;
        }
        catch (Worktrees.GitException) { return null; }
    }

    private async Task UseAsWorktreeFolderAsync(string workspaceId)
    {
        if (_snapshot.Workspaces.FirstOrDefault(item => item.Id == workspaceId) is not { } workspace) return;
        var directory = WorkspaceDirectory(workspace);
        var repo = await Task.Run(() => MainCheckout(directory));
        if (repo is null)
        {
            await ShowErrorAsync(Localizer.Get("NotGitRepoTitle"), Localizer.Get("NotGitRepoMessage"));
            return;
        }
        TryApply(new { command = "set_workspace_worktree_folder", workspace_id = workspaceId, repo });
    }

    /// <summary>New Worktree Workspace…: asks for a branch, creates its worktree in the repository of
    /// this worktree folder, and opens it as a workspace nested under the folder.</summary>
    private async Task NewWorktreeWorkspaceAsync(string folderId)
    {
        if (_dialogOpen || Root.XamlRoot is null || _snapshot.Workspaces.FirstOrDefault(item => item.Id == folderId) is not { } folder) return;
        var directory = WorkspaceDirectory(folder);
        var repoTask = folder.WorktreeRepo is { } known ? Task.FromResult<string?>(known) : Task.Run(() => MainCheckout(directory));
        var box = new TextBox { PlaceholderText = Localizer.Get("NewWorktreeWorkspacePlaceholder"), MinWidth = 280 };
        box.Loaded += (_, _) => box.Focus(FocusState.Programmatic);
        var content = new StackPanel { Spacing = 8 };
        content.Children.Add(new TextBlock { Text = Localizer.Get("NewWorktreeWorkspaceMessage"), TextWrapping = TextWrapping.Wrap });
        content.Children.Add(box);
        var dialog = new ContentDialog { XamlRoot = Root.XamlRoot, Title = Localizer.Get("NewWorktreeWorkspaceTitle"), Content = content, PrimaryButtonText = Localizer.Get("NewWorktreeWorkspaceCreate"), CloseButtonText = Localizer.Get("Cancel"), DefaultButton = ContentDialogButton.Primary };
        _dialogOpen = true;
        ContentDialogResult result;
        try { result = await dialog.ShowAsync(); }
        finally { _dialogOpen = false; }
        if (result != ContentDialogResult.Primary) return;
        var branch = box.Text.Trim();
        var failed = Localizer.Get("WorktreeCreateFailedTitle");
        if (branch.Length == 0)
        {
            await ShowErrorAsync(failed, Localizer.Get("WorktreeBranchRequired"));
            return;
        }
        if (await repoTask is not { } repo)
        {
            await ShowErrorAsync(Localizer.Get("NotGitRepoTitle"), Localizer.Get("NotGitRepoMessage"));
            return;
        }
        var (entry, code, detail) = await Task.Run<(WorktreeEntry?, string?, string?)>(() =>
        {
            try
            {
                if (Worktrees.List(repo).FirstOrDefault(item => item.Branch == branch) is { } existing) return (null, "branch_checked_out", existing.Path);
                return (Worktrees.Create(repo, branch, null, null), null, null);
            }
            catch (Worktrees.GitException error) { return (null, error.Code, error.Code == "worktree_path_exists" ? Worktrees.DefaultPath(repo, branch) : error.Message); }
        });
        if (entry is null)
        {
            await ShowErrorAsync(failed, code switch
            {
                "branch_checked_out" => string.Format(Localizer.Get("WorktreeBranchCheckedOut"), detail),
                "worktree_path_exists" => string.Format(Localizer.Get("WorktreePathExists"), detail),
                "not_a_git_repo" => Localizer.Get("NotGitRepoMessage"),
                _ => detail ?? string.Empty,
            });
            return;
        }
        if (_snapshot.Workspaces.FirstOrDefault(item => item.Id == folderId) is { Collapsed: true }) TryApply(new { command = "set_workspace_collapsed", workspace_id = folderId, collapsed = false });
        OpenWorktree(repo, entry, focus: true);
        if (WorkspaceOn(entry.Path) is { } child && child != folderId && _snapshot.Workspaces.Any(item => item.Id == folderId))
            TryApply(new { command = "set_workspace_parent", workspace_id = child, parent_id = folderId });
    }

    private void TryApply(object command)
    {
        try { ApplyOrThrow(command); }
        catch (Exception error) { _ = ShowErrorAsync(Localizer.Get("CoreError"), error.Message); }
    }

    internal static Color ParseColor(string hex) =>
        Color.FromArgb(255, Convert.ToByte(hex[1..3], 16), Convert.ToByte(hex[3..5], 16), Convert.ToByte(hex[5..7], 16));

    /// <summary>Runs one workspace action; <paramref name="value"/> is the title, description or color.</summary>
    private void WorkspaceAction(string workspaceId, string action, string? value = null)
    {
        var workspaces = _snapshot.Workspaces;
        var index = workspaces.ToList().FindIndex(item => item.Id == workspaceId);
        if (index < 0) throw NotFound("workspace", workspaceId);
        switch (action)
        {
            case "pin" or "unpin": ApplyOrThrow(new { command = "set_workspace_pinned", workspace_id = workspaceId, pinned = action == "pin" }); break;
            case "rename": ApplyOrThrow(new { command = "rename_workspace", workspace_id = workspaceId, title = value ?? throw new ControlException("invalid_params", "title is required.") }); break;
            case "clear_name": ApplyOrThrow(new { command = "rename_workspace", workspace_id = workspaceId, title = (string?)null }); break;
            case "set_description": ApplyOrThrow(new { command = "set_workspace_description", workspace_id = workspaceId, description = value ?? throw new ControlException("invalid_params", "description is required.") }); break;
            case "clear_description": ApplyOrThrow(new { command = "set_workspace_description", workspace_id = workspaceId, description = (string?)null }); break;
            case "set_color":
                // A palette name ("Blue") or #RRGGBB, as on macOS.
                var named = WorkspaceColors.FirstOrDefault(item => string.Equals(item.Name, value, StringComparison.OrdinalIgnoreCase)).Hex;
                ApplyOrThrow(new { command = "set_workspace_color", workspace_id = workspaceId, color = named ?? value ?? throw new ControlException("invalid_params", "color is required.") });
                break;
            case "clear_color": ApplyOrThrow(new { command = "set_workspace_color", workspace_id = workspaceId, color = (string?)null }); break;
            case "move_up": ApplyOrThrow(new { command = "move_workspace", workspace_id = workspaceId, index = Math.Max(0, index - 1) }); break;
            case "move_down": ApplyOrThrow(new { command = "move_workspace", workspace_id = workspaceId, index = index + 1 }); break;
            case "move_top": ApplyOrThrow(new { command = "move_workspace", workspace_id = workspaceId, index = 0 }); break;
            case "close_others" or "close_above" or "close_below":
                var closing = workspaces.Where((item, position) => item.Id != workspaceId && action switch
                {
                    "close_above" => position < index,
                    "close_below" => position > index,
                    _ => true,
                }).Select(item => item.Id).ToList();
                foreach (var id in closing) ApplyOrThrow(new { command = "close_workspace", workspace_id = id });
                break;
            case "mark_read":
                _notifications.MarkRead(workspaces[index].Panes.SelectMany(pane => pane.Surfaces).Select(surface => surface.Id).ToHashSet());
                RefreshUnreadIndicators();
                break;
            default: throw new ControlException("invalid_params", $"action '{action}' is not one of {string.Join(", ", WorkspaceActions)}.");
        }
    }

    /// <summary>A menu's action: errors show in a dialog instead of reaching a caller.</summary>
    private void TryWorkspaceAction(string workspaceId, string action, string? value = null)
    {
        try { WorkspaceAction(workspaceId, action, value); }
        catch (Exception error) { _ = ShowErrorAsync(Localizer.Get("CoreError"), error.Message); }
    }

    /// <summary>Like Apply, but a core error reaches the caller (`workspace.action` reports it).</summary>
    private void ApplyOrThrow(object command)
    {
        _snapshot = Dispatch(command);
        if (_snapshot.Workspaces.Count == 0) Close();
        else ProjectSnapshot();
    }

    /// <summary>`workspace.action`, on the named workspace or the selected one.</summary>
    private object WorkspaceActionFromControl(JsonElement p)
    {
        var action = Required(p, "action");
        var workspace = WorkspaceTarget(p);
        WorkspaceAction(workspace.Id, action, Text(p, "title") ?? Text(p, "description") ?? Text(p, "color"));
        return new { workspace_id = workspace.Id, action };
    }

    private async Task EditDescriptionAsync(string workspaceId)
    {
        if (_dialogOpen || Root.XamlRoot is null || _snapshot.Workspaces.FirstOrDefault(item => item.Id == workspaceId) is not { } workspace) return;
        var box = new TextBox { Text = workspace.Description ?? string.Empty, MinWidth = 320 };
        box.Loaded += (_, _) => { box.Focus(FocusState.Programmatic); box.SelectAll(); };
        var dialog = new ContentDialog { XamlRoot = Root.XamlRoot, Title = Localizer.Get("EditWorkspaceDescription"), Content = box, PrimaryButtonText = Localizer.Get("Save"), CloseButtonText = Localizer.Get("Cancel"), DefaultButton = ContentDialogButton.Primary };
        _dialogOpen = true;
        ContentDialogResult result;
        try { result = await dialog.ShowAsync(); }
        finally { _dialogOpen = false; }
        // A blank description removes it.
        if (result == ContentDialogResult.Primary) Apply(new { command = "set_workspace_description", workspace_id = workspaceId, description = box.Text });
    }
}
