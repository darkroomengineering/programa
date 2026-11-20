using System.Text.Json;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Windows.ApplicationModel.DataTransfer;

namespace Programa;

/// <summary>Dragging a tab onto a pane, as macOS bonsplit: near an edge it splits that pane and the
/// tab takes the new side; in the middle it joins the pane. A placeholder shows where it goes. The
/// edge a pane shares with the tab's own pane means "into this pane", so a neighbour's tab is easy
/// to move. surface.drag_to_split does the same split for a tab in its own pane.</summary>
public sealed partial class MainWindow
{
    /// <summary>Makes a pane's content area a drop target for tabs, with its placeholder overlay.</summary>
    private void AddDropTarget(Grid paneGrid, Border host, string workspaceId, string paneId)
    {
        var placeholder = new Border
        {
            Background = new SolidColorBrush(ThemeColor("SystemAccentColor", 0.25)),
            BorderBrush = ThemeBrush("AccentFillColorDefaultBrush"),
            BorderThickness = new Thickness(2),
            CornerRadius = new CornerRadius(10),
            HorizontalAlignment = HorizontalAlignment.Left,
            VerticalAlignment = VerticalAlignment.Top,
            IsHitTestVisible = false,
            Visibility = Visibility.Collapsed,
        };
        paneGrid.Children.Add(placeholder);
        Grid.SetRow(placeholder, 1);
        host.AllowDrop = true;
        string? Zone(DragEventArgs args, TabDragPayload payload)
        {
            var point = args.GetPosition(host);
            var zone = PaneGeometry.DropZone(point.X, point.Y, host.ActualWidth, host.ActualHeight);
            // The edge shared with the tab's own pane moves the tab here instead.
            if (zone is "left" or "right" && payload.WorkspaceId == workspaceId && payload.PaneId != paneId && SharesEdge(payload.PaneId, paneId, zone)) zone = "center";
            // A tab already here, dropped in the middle: nothing to do.
            if (payload.PaneId == paneId && zone == "center") return null;
            return zone;
        }
        host.DragOver += (_, args) =>
        {
            if (!TryGetDragPayload(args, out var payload) || (payload.WorkspaceId != workspaceId && !FromAnotherWindow(payload)) || Zone(args, payload) is not { } zone)
            {
                placeholder.Visibility = Visibility.Collapsed;
                return;
            }
            args.AcceptedOperation = DataPackageOperation.Move;
            var frame = PaneGeometry.DropPlaceholder(zone, host.ActualWidth, host.ActualHeight);
            placeholder.Margin = new Thickness(frame.X, frame.Y, 0, 0);
            (placeholder.Width, placeholder.Height) = (Math.Max(0, frame.Width), Math.Max(0, frame.Height));
            placeholder.Visibility = Visibility.Visible;
        };
        host.DragLeave += (_, _) => placeholder.Visibility = Visibility.Collapsed;
        host.Drop += (_, args) =>
        {
            placeholder.Visibility = Visibility.Collapsed;
            if (!TryGetDragPayload(args, out var payload) || (payload.WorkspaceId != workspaceId && !FromAnotherWindow(payload)) || Zone(args, payload) is not { } zone) return;
            args.AcceptedOperation = DataPackageOperation.Move;
            args.Handled = true;
            // After the drag finishes: the moves rebuild the tab strips the drag came from.
            DispatcherQueue.TryEnqueue(() =>
            {
                try
                {
                    if (FromAnotherWindow(payload))
                    {
                        WindowRegistry.MoveTab(payload.WorkspaceId, payload.PaneId, payload.SurfaceId, this, workspaceId, paneId, null);
                        if (zone != "center") SplitWithSurface(workspaceId, paneId, payload.SurfaceId, paneId, zone);
                    }
                    else if (zone == "center")
                        Apply(new { command = "move_surface", workspace_id = workspaceId, source_pane_id = payload.PaneId, target_pane_id = paneId, surface_id = payload.SurfaceId, before_surface_id = (string?)null });
                    else SplitWithSurface(workspaceId, payload.PaneId, payload.SurfaceId, paneId, zone);
                }
                catch (Exception error) when (error is CoreCommandException or ControlException) { _ = ShowErrorAsync(Localizer.Get("CoreError"), error.Message); }
            });
        };
    }

    /// <summary>Whether the tab's pane sits right next to the target, across the target's <paramref name="zone"/> edge.</summary>
    private bool SharesEdge(string sourcePaneId, string targetPaneId, string zone)
    {
        if (!_paneElements.TryGetValue(sourcePaneId, out var source) || !_paneElements.TryGetValue(targetPaneId, out var target)) return false;
        var from = source.TransformToVisual(Root).TransformBounds(new Windows.Foundation.Rect(0, 0, source.ActualWidth, source.ActualHeight));
        var to = target.TransformToVisual(Root).TransformBounds(new Windows.Foundation.Rect(0, 0, target.ActualWidth, target.ActualHeight));
        var touching = zone == "left" ? Math.Abs(to.Left - from.Right) <= PaneGeometry.Divider + 2 : Math.Abs(from.Left - to.Right) <= PaneGeometry.Divider + 2;
        return touching && Math.Min(from.Bottom, to.Bottom) - Math.Max(from.Top, to.Top) > 0;
    }

    /// <summary>Splits <paramref name="targetPaneId"/> towards <paramref name="direction"/> with an existing
    /// tab in the new pane, which gets the focus. The core only splits with a new tab, so the split
    /// takes a placeholder that is closed once the tab has moved in; it never starts a shell. A pane's
    /// only tab split off its own pane leaves a new terminal behind, as bonsplit leaves a tab there.</summary>
    private string SplitWithSurface(string workspaceId, string sourcePaneId, string surfaceId, string targetPaneId, string direction)
    {
        var (orientation, insertFirst) = direction switch
        {
            "left" => ("vertical", true),
            "right" => ("vertical", false),
            "up" => ("horizontal", true),
            "down" => ("horizontal", false),
            _ => throw new ControlException("invalid_params", "direction (left|right|up|down)"),
        };
        if (sourcePaneId == targetPaneId && SurfacesOf(workspaceId, targetPaneId).Count == 1)
        {
            var kept = Id("surface");
            _snapshot = Dispatch(new { command = "create_surface", workspace_id = workspaceId, pane_id = targetPaneId, surface_id = kept, session_id = Id("session") });
            _nextTerminalDirectory = _terminals.GetValueOrDefault(surfaceId)?.WorkingDirectory;
        }
        var newPaneId = Id("pane");
        var placeholder = Id("surface");
        _snapshot = Dispatch(new { command = "split_pane", workspace_id = workspaceId, pane_id = targetPaneId, split_id = Id("split"), new_pane_id = newPaneId, new_surface_id = placeholder, session_id = Id("session"), direction = orientation, ratio = 0.5, insert_first = insertFirst });
        _snapshot = Dispatch(new { command = "move_surface", workspace_id = workspaceId, source_pane_id = sourcePaneId, target_pane_id = newPaneId, surface_id = surfaceId, before_surface_id = (string?)null });
        _snapshot = Dispatch(new { command = "close_surface", workspace_id = workspaceId, pane_id = newPaneId, surface_id = placeholder });
        _snapshot = Dispatch(new { command = "select_surface", workspace_id = workspaceId, pane_id = newPaneId, surface_id = surfaceId });
        ProjectSnapshot();
        return newPaneId;
    }

    /// <summary>surface.drag_to_split: the tab out of its pane into a new split beside it.</summary>
    private object DragToSplitFromControl(JsonElement p)
    {
        var surfaceId = Required(p, "surface_id");
        var direction = Text(p, "direction")?.Trim().ToLowerInvariant() ?? string.Empty;
        if (direction is not ("left" or "right" or "up" or "down")) throw new ControlException("invalid_params", "direction (left|right|up|down) is required.");
        var workspace = _snapshot.Workspaces.FirstOrDefault(item => item.Panes.Any(pane => pane.Surfaces.Any(surface => surface.Id == surfaceId)))
            ?? throw new ControlException("not_found", "Surface not found", new { surface_id = surfaceId });
        var pane = workspace.Panes.First(item => item.Surfaces.Any(surface => surface.Id == surfaceId));
        var newPaneId = SplitWithSurface(workspace.Id, pane.Id, surfaceId, pane.Id, direction);
        return new { window_id = WindowId, workspace_id = workspace.Id, surface_id = surfaceId, pane_id = newPaneId };
    }

    private static Windows.UI.Color ThemeColor(string key, double opacity)
    {
        var color = (Windows.UI.Color)Application.Current.Resources[key];
        color.A = (byte)Math.Round(255 * opacity);
        return color;
    }
}
