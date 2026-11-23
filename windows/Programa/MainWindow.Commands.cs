using System.Text.Json;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Windows.Foundation;
using Windows.System;

namespace Programa;

/// <summary>Every keyboard action in one table that the key handler and the command palette share,
/// plus the navigation they run: tabs, pane zoom and focus, reopening a closed tab, the tab menu.</summary>
public sealed partial class MainWindow
{
    private readonly Dictionary<string, string> _zoomedPanes = new(StringComparer.Ordinal);
    private readonly Dictionary<string, FrameworkElement> _paneElements = new(StringComparer.Ordinal);
    /// <summary>Where each surface lived at the last projection, so a closed one can return there.</summary>
    private Dictionary<string, (string WorkspaceId, string PaneId)> _surfaceLocations = new(StringComparer.Ordinal);
    private readonly List<(TerminalView Terminal, string WorkspaceId, string PaneId, DateTimeOffset ClosedAt)> _closedTerminals = [];
    private static readonly TimeSpan ReopenWindow = TimeSpan.FromSeconds(5);
    private Dictionary<string, Action>? _commands;

    /// <summary>Shortcut action ids and what they do, in palette order.</summary>
    private Dictionary<string, Action> Commands => _commands ??= new Dictionary<string, Action>(StringComparer.Ordinal)
    {
        ["command_palette"] = () => _ = ShowCommandPaletteAsync(),
        ["new_workspace"] = NewWorkspace,
        ["new_claude_workspace"] = NewClaudeWorkspace,
        ["new_window"] = () => WindowRegistry.OpenWindow(),
        ["new_tab"] = () => NewTab(),
        ["split_vertical"] = () => Split("vertical"),
        ["split_horizontal"] = () => Split("horizontal"),
        // Find works in the selected tab, a terminal or a markdown panel.
        ["find"] = () => { ActiveTerminal()?.ShowFind(); ActiveMarkdown()?.ShowFind(); },
        ["show_notifications"] = ShowNotificationsPanel,
        ["jump_to_unread"] = JumpToLatestUnread,
        ["next_tab"] = () => CycleTab(1),
        ["previous_tab"] = () => CycleTab(-1),
        ["next_workspace"] = () => CycleWorkspace(1),
        ["previous_workspace"] = () => CycleWorkspace(-1),
        ["toggle_zoom"] = () => TogglePaneZoom(),
        ["focus_left"] = () => FocusPane(-1, 0),
        ["focus_right"] = () => FocusPane(1, 0),
        ["focus_up"] = () => FocusPane(0, -1),
        ["focus_down"] = () => FocusPane(0, 1),
        ["rename_workspace"] = () => { if (SelectedWorkspace() is { } workspace) _ = RenameWorkspaceAsync(workspace.Id); },
        ["close_tab"] = () => CloseSelectedTab(),
        ["reopen_tab"] = ReopenClosedTab,
        ["close_workspace"] = CloseSelectedWorkspace,
        ["toggle_sidebar"] = ToggleSidebar,
        ["clear_scrollback"] = () => ActiveTerminal()?.ClearScrollback(),
        ["font_bigger"] = () => ActiveTerminal()?.AdjustFontSize(1),
        ["font_smaller"] = () => ActiveTerminal()?.AdjustFontSize(-1),
        ["font_reset"] = () => ActiveTerminal()?.AdjustFontSize(0),
        ["copy"] = () => ActiveTerminal()?.Copy(),
        ["paste"] = () => ActiveTerminal()?.Paste(),
        ["paste_alternate"] = () => ActiveTerminal()?.Paste(),
        ["open_settings"] = () => _ = ShowSettingsAsync(),
        ["select_tab_1"] = () => SelectTab(1), ["select_tab_2"] = () => SelectTab(2), ["select_tab_3"] = () => SelectTab(3),
        ["select_tab_4"] = () => SelectTab(4), ["select_tab_5"] = () => SelectTab(5), ["select_tab_6"] = () => SelectTab(6),
        ["select_tab_7"] = () => SelectTab(7), ["select_tab_8"] = () => SelectTab(8), ["select_tab_9"] = () => SelectTab(9),
        ["select_workspace_1"] = () => SelectWorkspaceByNumber(1), ["select_workspace_2"] = () => SelectWorkspaceByNumber(2),
        ["select_workspace_3"] = () => SelectWorkspaceByNumber(3), ["select_workspace_4"] = () => SelectWorkspaceByNumber(4),
        ["select_workspace_5"] = () => SelectWorkspaceByNumber(5), ["select_workspace_6"] = () => SelectWorkspaceByNumber(6),
        ["select_workspace_7"] = () => SelectWorkspaceByNumber(7), ["select_workspace_8"] = () => SelectWorkspaceByNumber(8),
        ["select_workspace_9"] = () => SelectWorkspaceByNumber(9),
        ["rename_tab"] = () => { if (SelectedWorkspace() is { SelectedPane: { } pane } workspace) _ = RenameTabAsync(workspace.Id, pane.Id, pane.SelectedSurfaceId); },
        ["edit_workspace_description"] = () => { if (SelectedWorkspace() is { } workspace) _ = EditDescriptionAsync(workspace.Id); },
        ["close_other_tabs"] = () => { if (SelectedWorkspace() is { SelectedPane: { } pane } workspace) CloseOtherTabs(workspace.Id, pane.Id, pane.SelectedSurfaceId); },
        ["find_next"] = () => { ActiveTerminal()?.FindAgain(next: true); ActiveMarkdown()?.FindAgain(next: true); },
        ["find_previous"] = () => { ActiveTerminal()?.FindAgain(next: false); ActiveMarkdown()?.FindAgain(next: false); },
        ["hide_find"] = () => { ActiveTerminal()?.CloseFind(); ActiveMarkdown()?.CloseFind(); },
        ["use_selection_for_find"] = () => ActiveTerminal()?.FindSelection(),
        ["trigger_flash"] = () => { if (SelectedWorkspace() is { } workspace) FlashPane(workspace.SelectedPaneId); },
        ["go_to_workspace"] = () => _ = ShowCommandPaletteAsync(workspacesOnly: true),
        ["open_folder"] = () => _ = OpenFolderAsync(),
        ["open_review"] = () => { if (ActiveTerminal() is not null) _ = OpenReviewFromUiAsync(); },
        ["toggle_full_screen"] = ToggleFullScreen,
        ["reload_configuration"] = WindowRegistry.ApplySettings,
        ["send_feedback"] = () => OpenFeedback(),
        ["close_window"] = () => _ = CloseWindowAsync(),
        ["quit"] = () => _ = QuitAsync(),
        ["toggle_terminal_copy_mode"] = () => ActiveTerminal()?.ToggleCopyMode(),
    };

    /// <summary>Open Folder (macOS ⌘O): a new workspace in the folder you pick.</summary>
    private async Task OpenFolderAsync()
    {
        if (_dialogOpen) return;
        // ponytail: the system picker cannot start in the workspace's directory; the newer WinAppSDK picker can, if that matters.
        var picker = new Windows.Storage.Pickers.FolderPicker { SuggestedStartLocation = Windows.Storage.Pickers.PickerLocationId.ComputerFolder };
        picker.FileTypeFilter.Add("*");
        WinRT.Interop.InitializeWithWindow.Initialize(picker, WinRT.Interop.WindowNative.GetWindowHandle(this));
        if (await picker.PickSingleFolderAsync() is not { } folder) return;
        _nextTerminalDirectory = folder.Path;
        NewWorkspace();
    }

    /// <summary>The window's own presenter while it is full screen, so leaving keeps it maximized or where it was.</summary>
    private Microsoft.UI.Windowing.AppWindowPresenter? _windowedPresenter;

    /// <summary>Full screen (macOS ⌃⌘F, F11 here) and back to the window as it was.</summary>
    private void ToggleFullScreen()
    {
        if (_windowedPresenter is { } windowed)
        {
            _windowedPresenter = null;
            AppWindow.SetPresenter(windowed);
            return;
        }
        _windowedPresenter = AppWindow.Presenter;
        AppWindow.SetPresenter(Microsoft.UI.Windowing.AppWindowPresenterKind.FullScreen);
    }

    private void OnKeyDown(object sender, KeyRoutedEventArgs args)
    {
        if (_shortcuts.ActionFor(args.Key) is not { } action || !Commands.TryGetValue(action, out var run)) return;
        run();
        args.Handled = true;
    }

    /// <summary>The name the user gave a tab, or null.</summary>
    private string? SurfaceTitle(string surfaceId) => _snapshot.Workspaces
        .SelectMany(workspace => workspace.Panes).SelectMany(pane => pane.Surfaces)
        .FirstOrDefault(surface => surface.Id == surfaceId)?.Title;

    /// <summary>Tab 1-8 of the focused pane; 9 is its last tab, as on macOS.</summary>
    private void SelectTab(int number)
    {
        if (SelectedWorkspace() is not { } workspace || workspace.SelectedPane is not { } pane || pane.Surfaces.Count == 0) return;
        var index = number == 9 ? pane.Surfaces.Count - 1 : number - 1;
        if (index < pane.Surfaces.Count)
            Apply(new { command = "select_surface", workspace_id = workspace.Id, pane_id = pane.Id, surface_id = pane.Surfaces[index].Id });
    }

    private void CycleTab(int delta)
    {
        if (SelectedWorkspace() is not { } workspace || workspace.SelectedPane is not { } pane || pane.Surfaces.Count < 2) return;
        var index = pane.Surfaces.ToList().FindIndex(surface => surface.Id == pane.SelectedSurfaceId);
        var next = pane.Surfaces[(index + delta + pane.Surfaces.Count) % pane.Surfaces.Count];
        Apply(new { command = "select_surface", workspace_id = workspace.Id, pane_id = pane.Id, surface_id = next.Id });
    }

    private void CloseSelectedWorkspace()
    {
        if (SelectedWorkspace() is { } workspace) CloseWorkspace(workspace.Id);
    }

    /// <summary>The focused pane fills the workspace, or the split layout comes back.</summary>
    private void TogglePaneZoom(string? paneId = null)
    {
        if (SelectedWorkspace() is not { } workspace || workspace.Panes.Count < 2) return;
        if (!_zoomedPanes.Remove(workspace.Id)) _zoomedPanes[workspace.Id] = paneId ?? workspace.SelectedPaneId;
        ProjectSnapshot();
    }

    /// <summary>Moves focus to the nearest pane in a direction, by the panes' on-screen positions.</summary>
    private void FocusPane(int dx, int dy)
    {
        if (SelectedWorkspace() is not { } workspace || !_paneElements.TryGetValue(workspace.SelectedPaneId, out var current)) return;
        Rect Bounds(FrameworkElement element) =>
            element.TransformToVisual(Root).TransformBounds(new Rect(0, 0, element.ActualWidth, element.ActualHeight));
        var from = Bounds(current);
        static double Overlap(double a1, double a2, double b1, double b2) => Math.Min(a2, b2) - Math.Max(a1, b1);
        var target = workspace.Panes
            .Where(pane => pane.Id != workspace.SelectedPaneId && _paneElements.ContainsKey(pane.Id))
            .Select(pane => (Pane: pane, Bounds: Bounds(_paneElements[pane.Id])))
            .Where(candidate => dx != 0
                ? (dx < 0 ? candidate.Bounds.Right <= from.Left + 1 : candidate.Bounds.Left >= from.Right - 1)
                    && Overlap(from.Top, from.Bottom, candidate.Bounds.Top, candidate.Bounds.Bottom) > 0
                : (dy < 0 ? candidate.Bounds.Bottom <= from.Top + 1 : candidate.Bounds.Top >= from.Bottom - 1)
                    && Overlap(from.Left, from.Right, candidate.Bounds.Left, candidate.Bounds.Right) > 0)
            .OrderBy(candidate => dx != 0
                ? Math.Abs(dx < 0 ? from.Left - candidate.Bounds.Right : candidate.Bounds.Left - from.Right)
                : Math.Abs(dy < 0 ? from.Top - candidate.Bounds.Bottom : candidate.Bounds.Top - from.Bottom))
            .Select(candidate => candidate.Pane)
            .FirstOrDefault();
        if (target is null) return;
        Apply(new { command = "select_surface", workspace_id = workspace.Id, pane_id = target.Id, surface_id = target.SelectedSurfaceId });
    }

    /// <summary>Close Other Tabs: pinned tabs stay, as on macOS.</summary>
    private void CloseOtherTabs(string workspaceId, string paneId, string keepSurfaceId)
    {
        try { CloseTabs(workspaceId, paneId, keepSurfaceId, "close_others"); }
        catch (Exception error) { _ = ShowErrorAsync(Localizer.Get("CoreError"), error.Message); }
    }

    private async Task RenameTabAsync(string workspaceId, string paneId, string surfaceId)
    {
        if (_dialogOpen || Root.XamlRoot is null) return;
        var current = _terminals.TryGetValue(surfaceId, out var terminal) ? TabTitle(terminal) : string.Empty;
        var box = new TextBox { Text = SurfaceTitle(surfaceId) ?? string.Empty, PlaceholderText = current, MinWidth = 320 };
        box.Loaded += (_, _) => { box.Focus(FocusState.Programmatic); box.SelectAll(); };
        var dialog = new ContentDialog { XamlRoot = Root.XamlRoot, Title = Localizer.Get("RenameTab"), Content = box, PrimaryButtonText = Localizer.Get("Rename"), CloseButtonText = Localizer.Get("Cancel"), DefaultButton = ContentDialogButton.Primary };
        ContentDialogResult result;
        _dialogOpen = true;
        try { result = await dialog.ShowAsync(); }
        finally { _dialogOpen = false; }
        // A blank name goes back to the program's title.
        if (result == ContentDialogResult.Primary) Apply(new { command = "rename_surface", workspace_id = workspaceId, pane_id = paneId, surface_id = surfaceId, title = box.Text });
    }

    private void RememberSurfaceLocations() =>
        _surfaceLocations = _snapshot.Workspaces
            .SelectMany(workspace => workspace.Panes.SelectMany(pane => pane.Surfaces.Select(surface => (surface.Id, workspace.Id, pane.Id))))
            .ToDictionary(entry => entry.Item1, entry => (entry.Item2, entry.Item3), StringComparer.Ordinal);

    /// <summary>Keeps a closed tab's live terminal for <see cref="ReopenWindow"/>, then ends it.</summary>
    private void KeepClosedTerminal(TerminalView terminal)
    {
        if (terminal.HasExited || !_surfaceLocations.TryGetValue(terminal.SurfaceId, out var location))
        {
            terminal.Close();
            return;
        }
        var entry = (terminal, location.WorkspaceId, location.PaneId, DateTimeOffset.Now);
        _closedTerminals.Add(entry);
        var timer = DispatcherQueue.CreateTimer();
        timer.Interval = ReopenWindow;
        timer.IsRepeating = false;
        timer.Tick += (_, _) =>
        {
            timer.Stop();
            if (_closedTerminals.Remove(entry)) terminal.Close();
        };
        timer.Start();
    }

    /// <summary>Brings back the terminal closed last, within the last few seconds, in its old pane
    /// when that pane still exists, else in the focused pane.</summary>
    private void ReopenClosedTab()
    {
        if (_closedTerminals.Count == 0) return;
        var (terminal, workspaceId, paneId, closedAt) = _closedTerminals[^1];
        _closedTerminals.RemoveAt(_closedTerminals.Count - 1);
        if (DateTimeOffset.Now - closedAt > ReopenWindow) { terminal.Close(); return; }
        var workspace = _snapshot.Workspaces.FirstOrDefault(item => item.Id == workspaceId && item.Panes.Any(pane => pane.Id == paneId));
        var targetWorkspace = workspace ?? SelectedWorkspace();
        var targetPane = workspace is not null ? paneId : targetWorkspace?.SelectedPaneId;
        if (targetWorkspace is null || targetPane is null) { terminal.Close(); return; }
        _terminals[terminal.SurfaceId] = terminal;
        Apply(new { command = "create_surface", workspace_id = targetWorkspace.Id, pane_id = targetPane, surface_id = terminal.SurfaceId, session_id = Id("session") });
    }

    /// <summary>The command palette (macOS ⌘⇧P): every shortcut action, workspaces to go to and tab
    /// commands, filtered as you type; Enter or a click runs the highlighted one. With
    /// <paramref name="workspacesOnly"/> it is the workspace switcher (Go to Workspace, macOS ⌘P).</summary>
    private async Task ShowCommandPaletteAsync(bool workspacesOnly = false)
    {
        if (_dialogOpen || Root.XamlRoot is null) return;
        var entries = new List<(string Label, string Hint, Action Run)>();
        foreach (var (action, run) in workspacesOnly ? new Dictionary<string, Action>() : Commands)
        {
            if (action is "command_palette" or "paste_alternate" or "go_to_workspace" || action.StartsWith("select_tab_", StringComparison.Ordinal) || action.StartsWith("select_workspace_", StringComparison.Ordinal)) continue;
            entries.Add((Localizer.Get($"Shortcut_{action}"), ShortcutSettings.Display(_shortcuts.Values[action]), run));
        }
        if (!workspacesOnly && SelectedWorkspace() is { } current && current.SelectedPane is { } pane)
        {
            var surfaceId = pane.SelectedSurfaceId;
            if (ActiveTerminal() is { LastAgentSession: not null } resumable && !IsBusy(resumable)) entries.Add((Localizer.Get("ResumeAgentSession"), string.Empty, () => ResumeAgentFromPalette(resumable)));
            entries.Add((Localizer.Get("MoveTabToNewWindow"), string.Empty, () => WindowRegistry.MoveSurfaceToNewWindow(current.Id, pane.Id, surfaceId)));
        }
        var allSurfaces = workspacesOnly && AppSettings.Load().CommandPaletteSearchesAllSurfaces;
        foreach (var workspace in _snapshot.Workspaces)
        {
            var id = workspace.Id;
            var name = _sidebarRows.GetValueOrDefault(id)?.Title.Text ?? workspace.Title ?? id;
            entries.Add((workspacesOnly ? name : string.Format(Localizer.Get("GoToWorkspace"), name), string.Empty, () => Apply(new { command = "select_workspace", workspace_id = id })));
            // app.commandPaletteSearchesAllSurfaces: the switcher also matches every tab, as macOS's Cmd+P.
            if (allSurfaces)
                foreach (var tabPane in workspace.Panes)
                    foreach (var surface in tabPane.Surfaces)
                    {
                        var (paneId, surfaceId) = (tabPane.Id, surface.Id);
                        var tab = SurfaceTitle(surfaceId) ?? _tabItems.GetValueOrDefault(surfaceId)?.Header as string ?? surfaceId;
                        entries.Add(($"{tab} — {name}", string.Empty, () => Apply(new { command = "select_surface", workspace_id = id, pane_id = paneId, surface_id = surfaceId })));
                    }
        }
        var keywords = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (var (label, hint, words, run) in workspacesOnly ? [] : ConfigPaletteEntries().Concat(HelpPaletteEntries()).ToList())
        {
            entries.Add((label, hint, run));
            keywords[label] = words;
        }
        if (!workspacesOnly) entries.AddRange(LayoutPaletteEntries());
        if (!workspacesOnly) entries.Add((Localizer.Get("OpenSettingsJson"), string.Empty, OpenSettingsFile));

        var query = new TextBox { PlaceholderText = Localizer.Get(workspacesOnly ? "GoToWorkspacePlaceholder" : "CommandPalettePlaceholder"), MinWidth = 480 };
        AutomationProperties.SetName(query, Localizer.Get(workspacesOnly ? "Shortcut_go_to_workspace" : "Shortcut_command_palette"));
        var list = new ListView { SelectionMode = ListViewSelectionMode.Single, IsItemClickEnabled = true, MaxHeight = 400 };
        Action? chosen = null;
        var dialog = new ContentDialog { XamlRoot = Root.XamlRoot, CloseButtonText = Localizer.Get("Cancel") };

        void Fill()
        {
            list.Items.Clear();
            foreach (var entry in entries.Where(entry => Matches(entry.Label + " " + keywords.GetValueOrDefault(entry.Label), query.Text)))
            {
                var row = new Grid { Tag = entry.Run };
                row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
                row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
                row.Children.Add(new TextBlock { Text = entry.Label, TextTrimming = TextTrimming.CharacterEllipsis });
                var hint = new TextBlock { Text = entry.Hint, Opacity = 0.6, Margin = new Thickness(16, 0, 0, 0) };
                row.Children.Add(hint);
                Grid.SetColumn(hint, 1);
                list.Items.Add(new ListViewItem { Content = row, Tag = entry.Run });
            }
            list.SelectedIndex = list.Items.Count > 0 ? 0 : -1;
        }
        void Run(object? item)
        {
            if (item is FrameworkElement { Tag: Action run }) { chosen = run; dialog.Hide(); }
        }
        query.TextChanged += (_, _) => Fill();
        query.KeyDown += (_, args) =>
        {
            switch (args.Key)
            {
                case VirtualKey.Down when list.Items.Count > 0:
                    list.SelectedIndex = Math.Min(list.SelectedIndex + 1, list.Items.Count - 1);
                    list.ScrollIntoView(list.SelectedItem);
                    args.Handled = true;
                    break;
                case VirtualKey.Up when list.Items.Count > 0:
                    list.SelectedIndex = Math.Max(list.SelectedIndex - 1, 0);
                    list.ScrollIntoView(list.SelectedItem);
                    args.Handled = true;
                    break;
                case VirtualKey.Enter:
                    Run(list.SelectedItem);
                    args.Handled = true;
                    break;
            }
        };
        list.ItemClick += (_, args) => Run(args.ClickedItem);
        Fill();
        var panel = new StackPanel { Spacing = 8 };
        panel.Children.Add(query);
        panel.Children.Add(list);
        dialog.Content = panel;
        query.Loaded += (_, _) => query.Focus(FocusState.Programmatic);

        _dialogOpen = true;
        _palette = (query, list, dialog, Run, Fill);
        try { await dialog.ShowAsync(); }
        finally { _dialogOpen = false; _palette = null; }
        chosen?.Invoke();
    }

    /// <summary>The open palette, for the dev-build debug.command_palette.* and debug.type methods.</summary>
    private (TextBox Query, ListView List, ContentDialog Dialog, Action<object?> Run, Action Fill)? _palette;

    internal bool PaletteOpen => _palette is not null;

    /// <summary>Dev builds: debug.command_palette.toggle opens or closes the palette, .results lists its
    /// rows, debug.type types into its query, a newline running the highlighted row,
    /// debug.shortcut.simulate runs the action a key combination is bound to, and debug.menu.open
    /// opens a tab's or terminal's menu.</summary>
    internal object PaletteDebug(string method, JsonElement p)
    {
        switch (method)
        {
            case "debug.command_palette.toggle":
                if (_palette is { } open) open.Dialog.Hide();
                else _ = ShowCommandPaletteAsync();
                return new { };
            case "debug.command_palette.results":
                var limit = p.ValueKind == JsonValueKind.Object && p.TryGetProperty("limit", out var value) && value.TryGetInt32(out var count) ? count : int.MaxValue;
                return new
                {
                    visible = _palette is not null,
                    query = _palette?.Query.Text ?? string.Empty,
                    selected_index = _palette?.List.SelectedIndex ?? -1,
                    results = (_palette?.List.Items.OfType<ListViewItem>() ?? []).Take(limit)
                        .Select(item => ((Grid)item.Content).Children.OfType<TextBlock>().ToArray())
                        .Select(text => new { title = text[0].Text, subtitle = text[1].Text }).ToList(), // read here, on the UI thread
                };
            case "debug.shortcut.simulate":
                // A binding as settings.json writes it (ctrl-shift-g), or with + as macOS does.
                var combo = (Text(p, "combo") ?? string.Empty).Replace('+', '-');
                if (_shortcuts.ActionForBinding(combo) is not { } action || !Commands.TryGetValue(action, out var run))
                    throw new ControlException("not_found", $"No action is bound to {combo}.");
                run();
                return new { action };
            case "debug.menu.open":
                // A tab's menu, or with kind "terminal" its terminal's, opened as a right-click
                // opens it, for UI Automation to read and invoke.
                var surfaceId = Text(p, "surface_id") ?? SelectedWorkspace()?.SelectedPane?.SelectedSurfaceId ?? throw new ControlException("not_found", "No focused tab.");
                if (Text(p, "kind") == "terminal")
                    (_terminals.GetValueOrDefault(surfaceId) ?? throw new ControlException("not_found", "Not a terminal.")).ShowContextMenu();
                else if (_tabItems.GetValueOrDefault(surfaceId) is { ContextFlyout: { } flyout } tab) flyout.ShowAt(tab);
                else throw new ControlException("not_found", "The tab is not on screen.");
                return new { surface_id = surfaceId };
            default: // debug.type
                // Without a palette, a terminal in copy mode takes the keys (Escape and control characters included).
                if (_palette is null && ActiveTerminal() is { InCopyMode: true } copying)
                {
                    copying.TypeInCopyMode(Text(p, "text") ?? string.Empty);
                    return new { };
                }
                var palette = _palette ?? throw new ControlException("not_found", "No command palette is open.");
                var parts = (Text(p, "text") ?? string.Empty).Split('\n');
                for (var index = 0; index < parts.Length; index++)
                {
                    palette.Query.Text += parts[index].TrimEnd('\r');
                    // TextChanged comes later, so the rows are filtered here before a newline runs one.
                    palette.Fill();
                    if (index < parts.Length - 1) palette.Run(palette.List.SelectedItem);
                }
                return new { };
        }
    }

    /// <summary>Every word of the query appears in the label, in any order, ignoring case.</summary>
    internal static bool Matches(string label, string query) =>
        query.Split(' ', StringSplitOptions.RemoveEmptyEntries).All(word => label.Contains(word, StringComparison.CurrentCultureIgnoreCase));
}
