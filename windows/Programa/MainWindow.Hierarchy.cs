using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace Programa;

/// <summary>Worktree workspaces nested under their repository's workspace, as on macOS: the core
/// keeps each child right after its parent (one level deep), the parent's sidebar row shows a folder
/// with a collapse arrow, and its children sit indented below it.</summary>
public sealed partial class MainWindow
{
    private bool HasChildren(WorkspaceSnapshot workspace) =>
        _snapshot.Workspaces.Any(item => item.ParentId == workspace.Id);

    private bool IsHiddenChild(WorkspaceSnapshot workspace) =>
        workspace.ParentId is { } parentId && _snapshot.Workspaces.FirstOrDefault(item => item.Id == parentId) is { Collapsed: true };

    /// <summary>The folder row's icon: an arrow that collapses or expands its children.</summary>
    private FrameworkElement FolderToggle(WorkspaceSnapshot workspace)
    {
        var id = workspace.Id;
        var collapse = !workspace.Collapsed;
        var button = new Button
        {
            Content = new FontIcon { Glyph = workspace.Collapsed ? "" : "", FontSize = 10 },
            Width = 16,
            Height = 16,
            Padding = new Thickness(0),
            Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent),
            BorderThickness = new Thickness(0),
        };
        var label = Localizer.Get(workspace.Collapsed ? "ExpandWorktrees" : "CollapseWorktrees");
        AutomationProperties.SetName(button, label);
        ToolTipService.SetToolTip(button, label);
        button.Click += (_, _) => Apply(new { command = "set_workspace_collapsed", workspace_id = id, collapsed = collapse });
        return button;
    }

    /// <summary>Nests a worktree's workspace under the workspace open on its repository's main
    /// checkout, when there is one in this window and it is top level.</summary>
    private void NestUnderRepository(string workspaceId, string mainCheckout)
    {
        if (WorkspaceOn(mainCheckout) is not { } parentId || parentId == workspaceId) return;
        var parent = _snapshot.Workspaces.FirstOrDefault(item => item.Id == parentId);
        var child = _snapshot.Workspaces.FirstOrDefault(item => item.Id == workspaceId);
        if (parent is null || child is null || parent.ParentId is not null || child.ParentId is not null || HasChildren(child)) return;
        Apply(new { command = "set_workspace_parent", workspace_id = workspaceId, parent_id = parentId });
    }
}
