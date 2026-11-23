using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace Programa;

/// <summary>Worktree workspaces nested under their repository's workspace, as on macOS: the core
/// keeps each child right after its parent (one level deep), the parent's sidebar row shows a folder
/// with a collapse arrow, and its children sit indented below it. A workspace made its repository's
/// worktree folder (Use as Worktree Folder) is a folder even before it has children.</summary>
public sealed partial class MainWindow
{
    private bool HasChildren(WorkspaceSnapshot workspace) =>
        _snapshot.Workspaces.Any(item => item.ParentId == workspace.Id);

    private bool IsWorktreeFolder(WorkspaceSnapshot workspace) => workspace.WorktreeRepo is not null || HasChildren(workspace);

    private bool IsHiddenChild(WorkspaceSnapshot workspace) =>
        workspace.ParentId is { } parentId && _snapshot.Workspaces.FirstOrDefault(item => item.Id == parentId) is { Collapsed: true };

    /// <summary>The folder row's icon: a folder, with an arrow that collapses or expands its children when it has some.</summary>
    private FrameworkElement FolderIcon(WorkspaceSnapshot workspace)
    {
        var folder = new FontIcon { Glyph = char.ConvertFromUtf32(0xE8B7), FontSize = 13 };
        var tooltip = Localizer.Get("SidebarWorktreeFolder");
        if (!HasChildren(workspace))
        {
            ToolTipService.SetToolTip(folder, tooltip);
            AutomationProperties.SetName(folder, tooltip);
            return folder;
        }
        var id = workspace.Id;
        var collapse = !workspace.Collapsed;
        var content = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 3 };
        content.Children.Add(new FontIcon { Glyph = char.ConvertFromUtf32(workspace.Collapsed ? 0xE76C : 0xE70D), FontSize = 9 });
        content.Children.Add(folder);
        var button = new Button
        {
            Content = content,
            Height = 16,
            Padding = new Thickness(0),
            Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent),
            BorderThickness = new Thickness(0),
        };
        AutomationProperties.SetName(button, Localizer.Get(workspace.Collapsed ? "ExpandWorktrees" : "CollapseWorktrees"));
        ToolTipService.SetToolTip(button, tooltip);
        button.Click += (_, _) => Apply(new { command = "set_workspace_collapsed", workspace_id = id, collapsed = collapse });
        return button;
    }

    /// <summary>Nests a worktree's workspace under its repository's worktree folder, else under the
    /// workspace open on the repository's main checkout, when there is one in this window and it is top level.</summary>
    private void NestUnderRepository(string workspaceId, string mainCheckout)
    {
        var folderId = _snapshot.Workspaces.FirstOrDefault(item => item.WorktreeRepo is { } repo && Worktrees.SamePath(repo, mainCheckout))?.Id;
        if ((folderId ?? WorkspaceOn(mainCheckout)) is not { } parentId || parentId == workspaceId) return;
        var parent = _snapshot.Workspaces.FirstOrDefault(item => item.Id == parentId);
        var child = _snapshot.Workspaces.FirstOrDefault(item => item.Id == workspaceId);
        if (parent is null || child is null || parent.ParentId is not null || child.ParentId is not null || HasChildren(child)) return;
        Apply(new { command = "set_workspace_parent", workspace_id = workspaceId, parent_id = parentId });
    }
}
