using System.Text.Json;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;

namespace Programa;

/// <summary>Panels: tabs that show something other than a terminal (markdown files, diff reviews).
/// The core's surfaces are all terminals, so the window keeps which ones are panels, and saves
/// that with the session.</summary>
public sealed partial class MainWindow
{
    private readonly Dictionary<string, IPanel> _panels = new(StringComparer.Ordinal);
    /// <summary>Saved markdown panels not created yet (their workspace has not been shown since launch).</summary>
    private Dictionary<string, string> _restorePanels = new(StringComparer.Ordinal);

    private IPanel? PanelFor(string surfaceId)
    {
        if (_panels.TryGetValue(surfaceId, out var panel)) return panel;
        if (_restorePanels.Remove(surfaceId, out var path)) return _panels[surfaceId] = new MarkdownPanel(path);
        if (_restoreReviews.Remove(surfaceId, out var review)) return _panels[surfaceId] = CreateReviewPanel(review.Source, review.Mode, review.BaseBranch);
        return null;
    }

    private bool IsPanel(string surfaceId) =>
        _panels.ContainsKey(surfaceId) || _restorePanels.ContainsKey(surfaceId) || _restoreReviews.ContainsKey(surfaceId);

    /// <summary>What a pane's host shows for a surface: its terminal or its panel.</summary>
    private FrameworkElement? SurfaceElement(string surfaceId) =>
        _terminals.GetValueOrDefault(surfaceId) as FrameworkElement ?? _panels.GetValueOrDefault(surfaceId) as FrameworkElement;

    private TabViewItem PanelTab(string workspaceId, string paneId, string surfaceId, IPanel panel)
    {
        var title = SurfaceTitle(surfaceId) ?? panel.Title;
        var item = new TabViewItem
        {
            Header = title,
            IconSource = new FontIconSource { Glyph = panel.Glyph },
            IsClosable = true,
            Tag = new SurfaceTag(workspaceId, paneId, surfaceId),
            ContextFlyout = TabMenu(workspaceId, paneId, surfaceId),
        };
        AutomationProperties.SetName(item, title);
        if (panel.Tooltip is { } tooltip) ToolTipService.SetToolTip(item, tooltip);
        _tabItems[surfaceId] = item;
        return item;
    }

    /// <summary>Splits a new pane holding <paramref name="panel"/> beside the target surface, keeping the
    /// selection where it was unless <paramref name="focus"/>. Windows splits only right or down, so
    /// left and up open right and down.</summary>
    private (string SurfaceId, string PaneId, string WorkspaceId) SplitPanel(JsonElement p, IPanel panel, bool focus)
    {
        var (workspace, pane, _) = SurfaceTarget(p);
        var direction = (Text(p, "direction") ?? "right") switch
        {
            "right" or "left" => "vertical",
            "down" or "up" => "horizontal",
            var other => throw new ControlException("invalid_params", $"direction '{other}' is not right, down, left or up."),
        };
        var previous = SelectedWorkspace();
        var previousPane = previous?.SelectedPane;
        var newPane = Id("pane");
        var surfaceId = Id("surface");
        _panels[surfaceId] = panel;
        _snapshot = Dispatch(new { command = "split_pane", workspace_id = workspace.Id, pane_id = pane.Id, split_id = Id("split"), new_pane_id = newPane, new_surface_id = surfaceId, session_id = Id("session"), direction, ratio = 0.5 });
        if (focus) _snapshot = Dispatch(new { command = "select_workspace", workspace_id = workspace.Id });
        else if (previous is not null && previousPane is not null)
            _snapshot = Dispatch(new { command = "select_surface", workspace_id = previous.Id, pane_id = previousPane.Id, surface_id = previousPane.SelectedSurfaceId });
        ProjectSnapshot();
        return (surfaceId, newPane, workspace.Id);
    }

    /// <summary>`markdown.open`: the file in a new pane beside the source surface.</summary>
    private object OpenMarkdownFromControl(JsonElement p)
    {
        var path = Path.GetFullPath(Required(p, "path"));
        if (!File.Exists(path)) throw new ControlException("not_found", $"{path} does not exist.");
        var (surfaceId, paneId, workspaceId) = SplitPanel(p, new MarkdownPanel(path), Flag(p, "focus"));
        return new { surface_id = surfaceId, pane_id = paneId, workspace_id = workspaceId, path };
    }

    /// <summary>The markdown file of every markdown panel, for the session.</summary>
    private Dictionary<string, string> SavedPanels() =>
        _panels.Where(item => item.Value is MarkdownPanel).ToDictionary(item => item.Key, item => ((MarkdownPanel)item.Value).FilePath, StringComparer.Ordinal)
            .Concat(_restorePanels).ToDictionary(item => item.Key, item => item.Value, StringComparer.Ordinal);
}
