using System.Text.Json;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Windows.UI;

namespace Programa;

/// <summary>The workspace context menu and `workspace.action`, as on macOS: pin, color, description,
/// move up/down/to top, close others/above/below, rename, mark read.</summary>
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

    private static readonly string[] WorkspaceActions =
    [
        "pin", "unpin", "rename", "clear_name", "set_description", "clear_description", "move_up", "move_down", "move_top",
        "close_others", "close_above", "close_below", "mark_read", "set_color", "clear_color",
    ];

    private MenuFlyout WorkspaceMenu(WorkspaceSnapshot workspace)
    {
        var id = workspace.Id;
        var menu = new MenuFlyout();
        menu.Items.Add(MenuItem(Localizer.Get(workspace.Pinned ? "UnpinWorkspace" : "PinWorkspace"), () => TryWorkspaceAction(id, workspace.Pinned ? "unpin" : "pin")));
        menu.Items.Add(MenuItem(Localizer.Get("RenameWorkspace"), () => _ = RenameWorkspaceAsync(id)));
        menu.Items.Add(MenuItem(Localizer.Get("EditWorkspaceDescription"), () => _ = EditDescriptionAsync(id)));
        var colors = new MenuFlyoutSubItem { Text = Localizer.Get("WorkspaceColor") };
        foreach (var (name, hex) in WorkspaceColors)
        {
            var item = new MenuFlyoutItem { Text = name, Icon = new FontIcon { Glyph = "", Foreground = new SolidColorBrush(ParseColor(hex)) } };
            item.Click += (_, _) => WorkspaceAction(id, "set_color", hex);
            colors.Items.Add(item);
        }
        colors.Items.Add(new MenuFlyoutSeparator());
        colors.Items.Add(MenuItem(Localizer.Get("ClearColor"), () => TryWorkspaceAction(id, "clear_color")));
        menu.Items.Add(colors);
        menu.Items.Add(new MenuFlyoutSeparator());
        menu.Items.Add(MenuItem(Localizer.Get("MoveUp"), () => TryWorkspaceAction(id, "move_up")));
        menu.Items.Add(MenuItem(Localizer.Get("MoveDown"), () => TryWorkspaceAction(id, "move_down")));
        menu.Items.Add(MenuItem(Localizer.Get("MoveToTop"), () => TryWorkspaceAction(id, "move_top")));
        menu.Items.Add(MoveToWindowMenu(id));
        menu.Items.Add(new MenuFlyoutSeparator());
        menu.Items.Add(MenuItem(Localizer.Get("CloseOtherWorkspaces"), () => TryWorkspaceAction(id, "close_others")));
        menu.Items.Add(MenuItem(Localizer.Get("CloseWorkspace"), () => CloseWorkspace(id)));
        return menu;
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
