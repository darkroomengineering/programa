using System.Diagnostics;
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
        if (_restorePanels.Remove(surfaceId, out var path)) return _panels[surfaceId] = NewMarkdownPanel(path);
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
        var (workspace, pane, _) = SplitSource(p);
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

    /// <summary>The surface a panel splits from: the named surface, else the named workspace's focused
    /// one (as macOS resolves `workspace_id`), else the focused surface.</summary>
    private (WorkspaceSnapshot Workspace, PaneSnapshot Pane, string SurfaceId) SplitSource(JsonElement p)
    {
        if (Text(p, "surface_id") is not null || Text(p, "workspace_id") is null) return SurfaceTarget(p);
        var workspace = WorkspaceTarget(p);
        var pane = workspace.SelectedPane ?? throw NotFound("pane");
        return (workspace, pane, pane.SelectedSurfaceId);
    }

    /// <summary>`markdown.open`: the file in a new pane beside the source surface, with macOS's checks
    /// and reply.</summary>
    private object OpenMarkdownFromControl(JsonElement p)
    {
        var path = Path.GetFullPath(Required(p, "path"));
        if (Directory.Exists(path)) throw new ControlException("invalid_params", $"Path is a directory, not a file: {path}", new { path });
        if (!File.Exists(path)) throw new ControlException("not_found", $"File not found: {path}", new { path });
        try { File.OpenHandle(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete).Dispose(); }
        catch (UnauthorizedAccessException) { throw new ControlException("permission_denied", $"File not readable: {path}", new { path }); }
        var (_, sourcePane, sourceSurface) = SplitSource(p);
        var panel = NewMarkdownPanel(path);
        try
        {
            var (surfaceId, paneId, workspaceId) = SplitPanel(p, panel, Flag(p, "focus"));
            return new { surface_id = surfaceId, pane_id = paneId, workspace_id = workspaceId, source_surface_id = sourceSurface, source_pane_id = sourcePane.Id, target_pane_id = paneId, path };
        }
        catch
        {
            panel.Dispose();
            throw;
        }
    }

    /// <summary>A markdown panel whose links this window opens.</summary>
    private MarkdownPanel NewMarkdownPanel(string path)
    {
        var panel = new MarkdownPanel(path);
        panel.LinkRequested += OnMarkdownLink;
        return panel;
    }

    /// <summary>The selected tab's markdown panel, or null.</summary>
    private MarkdownPanel? ActiveMarkdown() =>
        SelectedWorkspace()?.SelectedPane?.SelectedSurfaceId is { } id ? _panels.GetValueOrDefault(id) as MarkdownPanel : null;

    /// <summary>A clicked link that is not a web link, as macOS MarkdownLinkRouter: a markdown file opens
    /// in a new tab in the panel's pane; any other file or scheme opens in its default app after asking.</summary>
    private void OnMarkdownLink(MarkdownPanel panel, Uri target)
    {
        var surfaceId = _panels.FirstOrDefault(item => ReferenceEquals(item.Value, panel)).Key;
        var owner = _snapshot.Workspaces.SelectMany(workspace => workspace.Panes.Select(pane => (Workspace: workspace, Pane: pane)))
            .FirstOrDefault(item => item.Pane.Surfaces.Any(surface => surface.Id == surfaceId));
        if (target.IsFile && Path.GetExtension(target.LocalPath).ToLowerInvariant() is ".md" or ".markdown" && owner.Pane is not null)
        {
            var id = Id("surface");
            _panels[id] = NewMarkdownPanel(target.LocalPath);
            Apply(new { command = "create_surface", workspace_id = owner.Workspace.Id, pane_id = owner.Pane.Id, surface_id = id, session_id = Id("session") });
            return;
        }
        _ = ConfirmOpenAsync(target);
    }

    /// <summary>macOS ExternalOpenPolicy's prompt: "Open in the default app?" with the target.</summary>
    private async Task ConfirmOpenAsync(Uri target)
    {
        if (_dialogOpen || Root.XamlRoot is null) return;
        var shown = target.IsFile ? target.LocalPath : target.AbsoluteUri;
        _dialogOpen = true;
        try
        {
            var dialog = new ContentDialog
            {
                XamlRoot = Root.XamlRoot,
                Title = string.Format(Localizer.Get("ExternalOpenTitle"), Localizer.Get("ExternalOpenDefaultApp")),
                Content = new TextBlock { Text = shown, TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true },
                PrimaryButtonText = Localizer.Get("ExternalOpenOpen"),
                CloseButtonText = Localizer.Get("Cancel"),
                DefaultButton = ContentDialogButton.Close,
            };
            if (await dialog.ShowAsync() != ContentDialogResult.Primary) return;
        }
        finally { _dialogOpen = false; }
        try
        {
            if (target.IsFile) Process.Start(new ProcessStartInfo(target.LocalPath) { UseShellExecute = true })?.Dispose();
            else await Windows.System.Launcher.LaunchUriAsync(target);
        }
        catch (Exception error) when (error is System.ComponentModel.Win32Exception or InvalidOperationException)
        {
            await ShowErrorAsync(shown, error.Message);
        }
    }

    /// <summary>The markdown file of every markdown panel, for the session.</summary>
    private Dictionary<string, string> SavedPanels() =>
        _panels.Where(item => item.Value is MarkdownPanel).ToDictionary(item => item.Key, item => ((MarkdownPanel)item.Value).FilePath, StringComparer.Ordinal)
            .Concat(_restorePanels).ToDictionary(item => item.Key, item => item.Value, StringComparer.Ordinal);
}
