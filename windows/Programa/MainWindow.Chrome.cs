using Microsoft.UI;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Windows.Graphics;

namespace Programa;

/// <summary>Window chrome as on macOS: the toolbar shares the title bar row, with the caption
/// buttons at its right; the sidebar runs up into that row and ends with a footer; and each
/// pane's tab strip ends with controls that act on that pane (the macOS 26 pane header).</summary>
public sealed partial class MainWindow
{
    private const double TitleBarHeight = 48;
    private FrameworkElement? _toolbarButtons;

    private void InitializeTitleBar()
    {
        var bar = AppWindow.TitleBar;
        bar.ExtendsContentIntoTitleBar = true;
        bar.PreferredHeightOption = TitleBarHeightOption.Tall;
        bar.ButtonBackgroundColor = Colors.Transparent;
        bar.ButtonInactiveBackgroundColor = Colors.Transparent;
        Root.SizeChanged += (_, _) => UpdateDragRegions();
    }

    /// <summary>The title bar row drags the window everywhere except the toolbar buttons.</summary>
    private void UpdateDragRegions()
    {
        if (_toolbarButtons is not { XamlRoot: { } xamlRoot } buttons || buttons.ActualWidth == 0) return;
        var scale = xamlRoot.RasterizationScale;
        var height = (int)Math.Round(TitleBarHeight * scale);
        var bounds = buttons.TransformToVisual(Root).TransformBounds(new Windows.Foundation.Rect(0, 0, buttons.ActualWidth, buttons.ActualHeight));
        var left = (int)Math.Floor(bounds.Left * scale);
        var right = (int)Math.Ceiling(bounds.Right * scale);
        var width = (int)Math.Round(Root.ActualWidth * scale) - AppWindow.TitleBar.RightInset;
        AppWindow.TitleBar.SetDragRectangles([new RectInt32(0, 0, left, height), new RectInt32(right, 0, Math.Max(0, width - right), height)]);
    }

    /// <summary>A footer panel (Storage, Ports) is open; a projection does not refocus the terminal.</summary>
    private bool _footerFlyoutOpen;

    /// <summary>Opens a footer panel above its button. Every projection rebuilds the footer, and a flyout
    /// anchored on a button that leaves the tree closes, so it hangs on the window root at the button's place.</summary>
    private void ShowFooterFlyout(Flyout flyout, FrameworkElement button)
    {
        var at = button.TransformToVisual(Root).TransformPoint(new Windows.Foundation.Point(0, 0));
        _footerFlyoutOpen = true;
        flyout.Closed += (_, _) => _footerFlyoutOpen = false;
        flyout.ShowAt(Root, new Microsoft.UI.Xaml.Controls.Primitives.FlyoutShowOptions { Position = at, Placement = Microsoft.UI.Xaml.Controls.Primitives.FlyoutPlacementMode.TopEdgeAlignedLeft });
    }

    /// <summary>Settings, Storage, Ports and (unless turned off) Provider Usage at the foot of the sidebar.</summary>
    private FrameworkElement SidebarFooter()
    {
        var footer = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(4, 0, 4, 6) };
        footer.Children.Add(IconButton("", "Settings", "open_settings", () => _ = ShowSettingsAsync()));
        footer.Children.Add(StorageButton());
        footer.Children.Add(PortsButton());
        if (_showProviderUsage) footer.Children.Add(UsageButton());
        return footer;
    }

    /// <summary>Split Right, Split Down, Zoom Pane and Close Tab for one pane. They act on that pane,
    /// not the focused one; Zoom dims while the workspace has a single pane.</summary>
    private FrameworkElement PaneControls(string workspaceId, string paneId)
    {
        var workspace = _snapshot.Workspaces.First(item => item.Id == workspaceId);
        var zoomed = _zoomedPanes.GetValueOrDefault(workspaceId) == paneId;
        var controls = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Bottom, Margin = new Thickness(0, 0, 4, 2) };
        controls.Children.Add(PaneButton("", "SplitRight", "split_vertical", () => Split("vertical", paneId)));
        controls.Children.Add(PaneButton("", "SplitDown", "split_horizontal", () => Split("horizontal", paneId)));
        var zoom = PaneButton(zoomed ? "" : "", zoomed ? "ExitZoom" : "ZoomPane", "toggle_zoom", () => TogglePaneZoom(paneId));
        zoom.IsEnabled = workspace.Panes.Count > 1;
        controls.Children.Add(zoom);
        controls.Children.Add(PaneButton("", "CloseTab", "close_tab", () => CloseSelectedTab(paneId)));
        return controls;
    }

    private Button PaneButton(string glyph, string labelKey, string action, Action handler)
    {
        var label = Localizer.Get(labelKey);
        var button = new Button
        {
            Content = new FontIcon { Glyph = glyph, FontSize = 12 },
            Width = 30,
            Height = 28,
            Padding = new Thickness(0),
            Background = new SolidColorBrush(Colors.Transparent),
            BorderThickness = new Thickness(0),
            Opacity = 0.75,
            IsTabStop = false,
        };
        AutomationProperties.SetName(button, label);
        ToolTipService.SetToolTip(button, $"{label} ({ShortcutSettings.Display(_shortcuts.Values[action])})");
        button.Click += (_, _) => handler();
        return button;
    }
}
