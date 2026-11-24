using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Windows.UI;

namespace Programa;

/// <summary>The pane tab menu as on macOS (bonsplit TabItemView.buildMenu, Workspace+Bonsplit's
/// context actions): rename, close to the left/right/others, Move Tab…, move to the pane beside,
/// a new terminal to the right, zoom, pin and the tab color; plus how a tab shows its pin, color
/// and agent logo.</summary>
public sealed partial class MainWindow
{
    /// <summary>The menu is filled again each time it opens, so it describes the tab as it is then
    /// (macOS builds its NSMenu at click time).</summary>
    private MenuFlyout TabMenu(string workspaceId, string paneId, string surfaceId)
    {
        var menu = new MenuFlyout();
        FillTabMenu(menu, workspaceId, paneId, surfaceId);
        menu.Opening += (_, _) => FillTabMenu(menu, workspaceId, paneId, surfaceId);
        return menu;
    }

    private void FillTabMenu(MenuFlyout menu, string workspaceId, string paneId, string surfaceId)
    {
        menu.Items.Clear();
        var workspace = _snapshot.Workspaces.FirstOrDefault(item => item.Id == workspaceId);
        var pane = workspace?.Panes.FirstOrDefault(item => item.Id == paneId);
        var surface = pane?.Surfaces.FirstOrDefault(item => item.Id == surfaceId);
        if (workspace is null || pane is null || surface is null) return;
        void Add(string key, Action run, bool enabled = true)
        {
            var item = MenuItem(Localizer.Get(key), () =>
            {
                try { run(); }
                catch (Exception error) { _ = ShowErrorAsync(Localizer.Get("CoreError"), error.Message); }
            });
            item.IsEnabled = enabled;
            menu.Items.Add(item);
        }
        var at = pane.Surfaces.ToList().FindIndex(item => item.Id == surfaceId);
        Add("RenameTab", () => _ = RenameTabAsync(workspaceId, paneId, surfaceId));
        if (surface.Title is not null)
            Add("RemoveCustomTabName", () => Apply(new { command = "rename_surface", workspace_id = workspaceId, pane_id = paneId, surface_id = surfaceId, title = (string?)null }));
        menu.Items.Add(new MenuFlyoutSeparator());
        Add("CloseTab", () => CloseSurface(workspaceId, paneId, surfaceId));
        // Pinned tabs stay, so each is offered only when it would close something.
        Add("CloseTabsToLeft", () => CloseTabs(workspaceId, paneId, surfaceId, "close_left"), pane.Surfaces.Take(at).Any(tab => !tab.IsPinned));
        Add("CloseTabsToRight", () => CloseTabs(workspaceId, paneId, surfaceId, "close_right"), pane.Surfaces.Skip(at + 1).Any(tab => !tab.IsPinned));
        Add("CloseOtherTabs", () => CloseTabs(workspaceId, paneId, surfaceId, "close_others"), pane.Surfaces.Any(tab => tab.Id != surfaceId && !tab.IsPinned));
        Add("MoveTab", () => _ = MoveTabAsync(workspaceId, paneId, surfaceId));
        if (!IsPanel(surfaceId))
        {
            var left = PaneGeometry.Adjacent(workspace.Layout, paneId, -1, 0);
            var right = PaneGeometry.Adjacent(workspace.Layout, paneId, 1, 0);
            Add("MoveToLeftPane", () => MoveWithinWorkspace(workspaceId, paneId, left!, surfaceId, null), left is not null);
            Add("MoveToRightPane", () => MoveWithinWorkspace(workspaceId, paneId, right!, surfaceId, null), right is not null);
        }
        menu.Items.Add(new MenuFlyoutSeparator());
        Add("NewTerminalTabToRight", () => NewTerminalToRight(workspaceId, paneId, surfaceId, focus: true));
        menu.Items.Add(new MenuFlyoutSeparator());
        if (workspace.Panes.Count > 1) Add(_zoomedPanes.ContainsKey(workspaceId) ? "ExitZoom" : "ZoomPane", () => TogglePaneZoom(paneId));
        Add(surface.IsPinned ? "UnpinTab" : "PinTab", () => Apply(new { command = "set_surface_pinned", workspace_id = workspaceId, pane_id = paneId, surface_id = surfaceId, pinned = !surface.IsPinned }));
        menu.Items.Add(TabReadMenuItem(surfaceId));
        menu.Items.Add(new MenuFlyoutSeparator());
        menu.Items.Add(TabColorMenu(workspaceId, paneId, surface));
    }

    /// <summary>close_left, close_right, close_others: pinned tabs stay, and the workspace keeps at least one tab.</summary>
    private (int Closed, int SkippedPinned) CloseTabs(string workspaceId, string paneId, string surfaceId, string action)
    {
        var pane = PaneIn(_snapshot.Workspaces.First(item => item.Id == workspaceId), paneId);
        var ids = pane.Surfaces.Select(surface => surface.Id).ToList();
        var at = ids.IndexOf(surfaceId);
        var targets = action switch
        {
            "close_left" => ids[..at],
            "close_right" => ids[(at + 1)..],
            _ => ids.Where(id => id != surfaceId).ToList(),
        };
        int closed = 0, skippedPinned = 0;
        foreach (var id in targets)
        {
            if (pane.Surfaces.First(surface => surface.Id == id).IsPinned) { skippedPinned++; continue; }
            if (_snapshot.Workspaces.First(item => item.Id == workspaceId).Panes.Sum(item => item.Surfaces.Count) <= 1) break;
            _snapshot = Dispatch(new { command = "close_surface", workspace_id = workspaceId, pane_id = paneId, surface_id = id });
            closed++;
        }
        if (closed > 0) ProjectSnapshot();
        return (closed, skippedPinned);
    }

    /// <summary>A terminal right after a tab, in the tab's directory. The menu selects it, as macOS;
    /// tab.action keeps the selection, as socket commands do.</summary>
    private string NewTerminalToRight(string workspaceId, string paneId, string surfaceId, bool focus)
    {
        var pane = PaneIn(_snapshot.Workspaces.First(item => item.Id == workspaceId), paneId);
        var created = Id("surface");
        var next = pane.Surfaces.SkipWhile(surface => surface.Id != surfaceId).Skip(1).FirstOrDefault()?.Id;
        var directory = _terminals.GetValueOrDefault(surfaceId)?.WorkingDirectory;
        var create = new { command = "create_surface", workspace_id = workspaceId, pane_id = paneId, surface_id = created, session_id = Id("session") };
        if (focus)
        {
            _snapshot = Dispatch(create);
            _nextTerminalDirectory = directory;
        }
        else CreateKeepingSelection(create, workspaceId, created, directory, null);
        if (next is not null) Apply(new { command = "reorder_surface", workspace_id = workspaceId, pane_id = paneId, surface_id = created, before_surface_id = next });
        else if (focus) ProjectSnapshot();
        return created;
    }

    /// <summary>Move Tab… (macOS promptMovePanel): to a new workspace in this window, a new window,
    /// or any other workspace of any window.</summary>
    private async Task MoveTabAsync(string workspaceId, string paneId, string surfaceId)
    {
        if (_dialogOpen || Root.XamlRoot is null) return;
        var options = new List<(string Label, Func<bool> Move)>
        {
            (Localizer.Get("MoveTabNewWorkspace"), () =>
            {
                AdoptWorkspace(TakeSurface(workspaceId, paneId, surfaceId));
                return true;
            }),
            (Localizer.Get("NewWindow"), () =>
            {
                // The app's only tab stays in its window, as when it is dragged out.
                if (WindowRegistry.Windows.Count == 1 && IsOnlyTab(surfaceId)) return false;
                WindowRegistry.MoveSurfaceToNewWindow(workspaceId, paneId, surfaceId);
                return true;
            }),
        };
        var windows = WindowRegistry.Windows.ToList();
        foreach (var window in windows)
            foreach (var (id, _, shown) in window.WorkspaceNames().Where(entry => entry.Id != workspaceId).ToList())
            {
                var target = window;
                var label = window == this ? shown : $"{shown} ({string.Format(Localizer.Get("WindowNumber"), windows.IndexOf(window) + 1)})";
                options.Add((label, () =>
                {
                    WindowRegistry.MoveTab(workspaceId, paneId, surfaceId, target, id, target.SelectedPaneOf(id), null);
                    return true;
                }));
            }
        var picker = new ComboBox { ItemsSource = options.Select(option => option.Label).ToList(), SelectedIndex = 0, MinWidth = 320 };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(picker, Localizer.Get("MoveTabTitle"));
        var content = new StackPanel { Spacing = 12 };
        content.Children.Add(new TextBlock { Text = Localizer.Get("MoveTabMessage"), TextWrapping = TextWrapping.Wrap });
        content.Children.Add(picker);
        var dialog = new ContentDialog { XamlRoot = Root.XamlRoot, Title = Localizer.Get("MoveTabTitle"), Content = content, PrimaryButtonText = Localizer.Get("Move"), CloseButtonText = Localizer.Get("Cancel"), DefaultButton = ContentDialogButton.Primary };
        ContentDialogResult result;
        _dialogOpen = true;
        try { result = await dialog.ShowAsync(); }
        finally { _dialogOpen = false; }
        if (result != ContentDialogResult.Primary) return;
        bool moved;
        try { moved = options[Math.Max(0, picker.SelectedIndex)].Move(); }
        catch (Exception) { moved = false; }
        if (!moved) await ShowErrorAsync(Localizer.Get("MoveTabFailedTitle"), Localizer.Get("MoveTabFailedMessage"));
    }

    /// <summary>Tab Color: Clear Color while it has one, Choose Custom Color…, then the palette
    /// the workspace colors use.</summary>
    private MenuFlyoutSubItem TabColorMenu(string workspaceId, string paneId, SurfaceSnapshot surface)
    {
        var colors = new MenuFlyoutSubItem { Text = Localizer.Get("TabColor") };
        if (surface.Color is not null) colors.Items.Add(MenuItem(Localizer.Get("ClearColor"), () => SetTabColor(workspaceId, paneId, surface.Id, null)));
        colors.Items.Add(MenuItem(Localizer.Get("ChooseCustomColor"), () => _ = ChooseTabColorAsync(workspaceId, paneId, surface.Id, surface.Color)));
        colors.Items.Add(new MenuFlyoutSeparator());
        foreach (var (name, hex) in WorkspaceColors)
        {
            var item = new MenuFlyoutItem { Text = name, Icon = new FontIcon { Glyph = char.ConvertFromUtf32(0xE91F), Foreground = new SolidColorBrush(ParseColor(hex)) } };
            item.Click += (_, _) => SetTabColor(workspaceId, paneId, surface.Id, hex);
            colors.Items.Add(item);
        }
        return colors;
    }

    private void SetTabColor(string workspaceId, string paneId, string surfaceId, string? hex) =>
        Apply(new { command = "set_surface_color", workspace_id = workspaceId, pane_id = paneId, surface_id = surfaceId, color = hex });

    /// <summary>Choose Custom Color… (macOS promptCustomTabColor): a #RRGGBB typed in.</summary>
    private async Task ChooseTabColorAsync(string workspaceId, string paneId, string surfaceId, string? current)
    {
        if (_dialogOpen || Root.XamlRoot is null) return;
        var box = new TextBox { Text = current ?? string.Empty, PlaceholderText = "#1565C0", MinWidth = 240 };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(box, Localizer.Get("CustomTabColorTitle"));
        box.Loaded += (_, _) => { box.Focus(FocusState.Programmatic); box.SelectAll(); };
        var content = new StackPanel { Spacing = 12 };
        content.Children.Add(new TextBlock { Text = Localizer.Get("CustomColorMessage"), TextWrapping = TextWrapping.Wrap });
        content.Children.Add(box);
        var dialog = new ContentDialog { XamlRoot = Root.XamlRoot, Title = Localizer.Get("CustomTabColorTitle"), Content = content, PrimaryButtonText = Localizer.Get("Apply"), CloseButtonText = Localizer.Get("Cancel"), DefaultButton = ContentDialogButton.Primary };
        ContentDialogResult result;
        _dialogOpen = true;
        try { result = await dialog.ShowAsync(); }
        finally { _dialogOpen = false; }
        if (result != ContentDialogResult.Primary) return;
        if (NormalizedHex(box.Text) is { } hex) SetTabColor(workspaceId, paneId, surfaceId, hex);
        else
        {
            var typed = box.Text.Trim();
            await ShowErrorAsync(Localizer.Get("InvalidColorTitle"), typed.Length == 0 ? Localizer.Get("CustomColorMessage") : string.Format(Localizer.Get("InvalidColorMessage"), typed));
        }
    }

    /// <summary>#RRGGBB in upper case from what was typed, with or without the #, or null (macOS normalizedHex).</summary>
    internal static string? NormalizedHex(string raw)
    {
        var trimmed = raw.Trim();
        var body = trimmed.StartsWith('#') ? trimmed[1..] : trimmed;
        return body.Length == 6 && body.All(Uri.IsHexDigit) ? "#" + body.ToUpperInvariant() : null;
    }

    /// <summary>Pinned tabs show a pin instead of the close button and ignore middle-click (a
    /// TabViewItem closes on one only while closable). A colored tab gets macOS's 20% wash: the
    /// selected tab draws its usual fill under the same background, so it stays opaque.</summary>
    private static void StyleTab(TabViewItem item, SurfaceSnapshot surface)
    {
        item.IsClosable = !surface.IsPinned;
        if (surface.Color is not { } hex || NormalizedHex(hex) is null) return;
        var color = ParseColor(hex);
        SolidColorBrush Tint(double opacity) => new(Color.FromArgb((byte)(255 * opacity), color.R, color.G, color.B));
        item.Background = Tint(0.2);
        item.Resources["TabViewItemHeaderBackground"] = Tint(0.2);
        item.Resources["TabViewItemHeaderBackgroundPointerOver"] = Tint(0.3);
        item.Resources["TabViewItemHeaderBackgroundPressed"] = Tint(0.38);
    }

    /// <summary>Agent logos by asset and light/dark, shared by every tab and row.</summary>
    private static readonly Dictionary<(string Asset, bool Dark), SvgImageSource> AgentLogos = [];

    private bool _logosFollowTheme;

    /// <summary>The logo of a known agent (macOS TerminalTabAgentIconResolver), or null.</summary>
    private SvgImageSource? AgentLogoSource(string? app)
    {
        if (AgentIndicator.LogoAsset(app) is not { } asset) return null;
        if (!_logosFollowTheme)
        {
            // The monochrome logos have a light and a dark file; a theme change redraws with the other.
            _logosFollowTheme = true;
            Root.ActualThemeChanged += (_, _) => ProjectSnapshot();
        }
        var key = (asset, Root.ActualTheme != ElementTheme.Light);
        if (AgentLogos.TryGetValue(key, out var cached)) return cached;
        // Rasterized larger than shown so it stays sharp at 200% scaling.
        var source = new SvgImageSource { RasterizePixelWidth = 48, RasterizePixelHeight = 48 };
        _ = source.SetSourceAsync(new MemoryStream(AgentIndicator.LogoSvg(asset, key.Item2)).AsRandomAccessStream());
        return AgentLogos[key] = source;
    }
}
