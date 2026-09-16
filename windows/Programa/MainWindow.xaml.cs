using System.Text.Json;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Windows.ApplicationModel.DataTransfer;
using Windows.Foundation;
using Windows.System;

namespace Programa;

public sealed partial class MainWindow : Window
{
    private const string TabDragDataKey = "com.darkroom.programa.surface-drag";
    private readonly CoreClient _core = new();
    private readonly Dictionary<string, TerminalView> _terminals = new(StringComparer.Ordinal);
    private CoreSnapshot _snapshot;
    private ShortcutSettings _shortcuts;
    private string? _startupSettingsError;
    private bool _dialogOpen;
    private bool _projecting;

    public MainWindow()
    {
        InitializeComponent();
        _shortcuts = LoadSettingsOrDefaults();
        _snapshot = _core.Snapshot();
        if (_snapshot.Workspaces.Count == 0)
            _snapshot = Dispatch(new { command = "create_workspace", workspace_id = Id("workspace"), pane_id = Id("pane"), surface_id = Id("surface"), session_id = Id("session") });
        Root.AddHandler(UIElement.KeyDownEvent, new KeyEventHandler(OnKeyDown), true);
        Root.Loaded += OnRootLoaded;
        Closed += OnClosed;
        ProjectSnapshot();
    }

    private static string Id(string prefix) => $"{prefix}-{Guid.NewGuid():N}";

    private ShortcutSettings LoadSettingsOrDefaults()
    {
        try { return ShortcutSettings.Load(); }
        catch (Exception error)
        {
            _startupSettingsError = error.Message;
            return ShortcutSettings.Create(ShortcutSettings.Defaults);
        }
    }

    private void OnRootLoaded(object sender, RoutedEventArgs args)
    {
        if (_startupSettingsError is not { } message) return;
        _startupSettingsError = null;
        _ = ShowErrorAsync(Localizer.Get("ShortcutError"), message);
    }

    private void ProjectSnapshot()
    {
        _projecting = true;
        try
        {
            foreach (var child in Root.Children) DetachTerminals(child);
            Root.Children.Clear();
            Root.RowDefinitions.Clear();
            Root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            Root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
            var toolbar = BuildToolbar();
            Root.Children.Add(toolbar);
            Grid.SetRow(toolbar, 0);

            var workspace = _snapshot.Workspaces.FirstOrDefault(item => item.Id == _snapshot.SelectedWorkspaceId)
                ?? _snapshot.Workspaces.FirstOrDefault();
            if (workspace is not null)
            {
                var layout = BuildLayout(workspace, workspace.Layout);
                Root.Children.Add(layout);
                Grid.SetRow(layout, 1);
            }
            RemoveClosedTerminals();
        }
        finally { _projecting = false; }
    }

    private static void DetachTerminals(DependencyObject node)
    {
        if (node is TabView tabs)
        {
            foreach (var item in tabs.TabItems.OfType<TabViewItem>())
                if (item.Content is TerminalView) item.Content = null;
        }
        if (node is Panel panel)
            foreach (var child in panel.Children) DetachTerminals(child);
        else if (node is ContentControl { Content: DependencyObject content })
            DetachTerminals(content);
    }

    private CommandBar BuildToolbar()
    {
        var bar = new CommandBar { DefaultLabelPosition = CommandBarDefaultLabelPosition.Right };
        bar.PrimaryCommands.Add(CommandButton(Localizer.Get("NewTab"), Symbol.Add, (_, _) => NewTab()));
        bar.PrimaryCommands.Add(CommandButton(Localizer.Get("SplitVertical"), Symbol.Add, (_, _) => Split("vertical")));
        bar.PrimaryCommands.Add(CommandButton(Localizer.Get("SplitHorizontal"), Symbol.Add, (_, _) => Split("horizontal")));
        bar.SecondaryCommands.Add(CommandButton(Localizer.Get("Settings"), Symbol.Setting, async (_, _) => await ShowSettingsAsync()));
        return bar;
    }

    private static AppBarButton CommandButton(string label, Symbol symbol, RoutedEventHandler handler)
    {
        var button = new AppBarButton { Label = label, Icon = new SymbolIcon(symbol), MinWidth = 44, MinHeight = 44 };
        AutomationProperties.SetName(button, label);
        button.Click += handler;
        return button;
    }

    private FrameworkElement BuildLayout(WorkspaceSnapshot workspace, LayoutSnapshot node)
    {
        if (node.Type == "pane" && node.PaneId is not null)
        {
            var pane = workspace.Panes.FirstOrDefault(item => item.Id == node.PaneId)
                ?? throw new InvalidDataException($"Layout refers to missing pane '{node.PaneId}'.");
            return BuildPane(workspace.Id, pane);
        }
        if (node.Type != "split" || node.Id is null || node.First is null || node.Second is null)
            throw new InvalidDataException("Core returned an invalid layout node.");

        var grid = new Grid();
        var first = BuildLayout(workspace, node.First);
        var second = BuildLayout(workspace, node.Second);
        var ratio = Math.Clamp(node.Ratio, 0.1, 0.9);
        var divider = new Thumb { Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent) };
        AutomationProperties.SetName(divider, node.Direction == "vertical" ? Localizer.Get("SplitVertical") : Localizer.Get("SplitHorizontal"));

        if (node.Direction == "vertical")
        {
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(ratio, GridUnitType.Star) });
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(8) });
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1 - ratio, GridUnitType.Star) });
            grid.Children.Add(first); grid.Children.Add(divider); grid.Children.Add(second);
            Grid.SetColumn(first, 0); Grid.SetColumn(divider, 1); Grid.SetColumn(second, 2);
        }
        else
        {
            grid.RowDefinitions.Add(new RowDefinition { Height = new GridLength(ratio, GridUnitType.Star) });
            grid.RowDefinitions.Add(new RowDefinition { Height = new GridLength(8) });
            grid.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1 - ratio, GridUnitType.Star) });
            grid.Children.Add(first); grid.Children.Add(divider); grid.Children.Add(second);
            Grid.SetRow(first, 0); Grid.SetRow(divider, 1); Grid.SetRow(second, 2);
        }
        divider.DragDelta += (_, args) => ResizeVisualSplit(grid, node.Direction!, args);
        divider.DragCompleted += (_, _) => CommitSplitSize(workspace.Id, node.Id, grid, node.Direction!);
        return grid;
    }

    private FrameworkElement BuildPane(string workspaceId, PaneSnapshot pane)
    {
        var tabs = new TabView
        {
            AllowDropTabs = true,
            CanDragTabs = true,
            CanReorderTabs = true,
            CanTearOutTabs = false,
            IsAddTabButtonVisible = true,
            Tag = new PaneTag(workspaceId, pane.Id),
        };
        AutomationProperties.SetName(tabs, Localizer.Get("Terminal"));
        tabs.AddTabButtonClick += (_, _) => NewTab(pane.Id);
        tabs.TabCloseRequested += OnTabCloseRequested;
        tabs.TabDragStarting += OnTabDragStarting;
        tabs.SelectionChanged += OnTabSelectionChanged;
        tabs.TabDragCompleted += OnTabDragCompleted;
        tabs.TabStripDragOver += OnTabStripDragOver;
        tabs.TabStripDrop += OnTabStripDrop;
        tabs.GotFocus += OnPaneGotFocus;

        for (var surfaceIndex = 0; surfaceIndex < pane.Surfaces.Count; surfaceIndex++)
        {
            var surface = pane.Surfaces[surfaceIndex];
            if (!_terminals.TryGetValue(surface.Id, out var terminal))
            {
                terminal = new TerminalView(surface.Id, surface.SessionId);
                _terminals.Add(surface.Id, terminal);
            }
            var item = new TabViewItem
            {
                Header = Localizer.Get("Terminal"),
                IconSource = new SymbolIconSource { Symbol = Symbol.Document },
                IsClosable = true,
                Content = terminal,
                Tag = new SurfaceTag(workspaceId, pane.Id, surface.Id),
            };
            AutomationProperties.SetName(item, $"{Localizer.Get("Terminal")} {surfaceIndex + 1}");
            tabs.TabItems.Add(item);
            if (surface.Id == pane.SelectedSurfaceId) tabs.SelectedItem = item;
        }
        return tabs;
    }

    private static void ResizeVisualSplit(Grid grid, string direction, DragDeltaEventArgs args)
    {
        if (direction == "vertical")
        {
            var available = grid.ColumnDefinitions[0].ActualWidth + grid.ColumnDefinitions[2].ActualWidth;
            if (available <= 0) return;
            var ratio = Math.Clamp((grid.ColumnDefinitions[0].ActualWidth + args.HorizontalChange) / available, 0.1, 0.9);
            grid.ColumnDefinitions[0].Width = new GridLength(ratio, GridUnitType.Star);
            grid.ColumnDefinitions[2].Width = new GridLength(1 - ratio, GridUnitType.Star);
        }
        else if (direction == "horizontal")
        {
            var available = grid.RowDefinitions[0].ActualHeight + grid.RowDefinitions[2].ActualHeight;
            if (available <= 0) return;
            var ratio = Math.Clamp((grid.RowDefinitions[0].ActualHeight + args.VerticalChange) / available, 0.1, 0.9);
            grid.RowDefinitions[0].Height = new GridLength(ratio, GridUnitType.Star);
            grid.RowDefinitions[2].Height = new GridLength(1 - ratio, GridUnitType.Star);
        }
    }

    private void CommitSplitSize(string workspaceId, string splitId, Grid grid, string direction)
    {
        var ratio = direction == "vertical"
            ? grid.ColumnDefinitions[0].ActualWidth / Math.Max(1, grid.ColumnDefinitions[0].ActualWidth + grid.ColumnDefinitions[2].ActualWidth)
            : grid.RowDefinitions[0].ActualHeight / Math.Max(1, grid.RowDefinitions[0].ActualHeight + grid.RowDefinitions[2].ActualHeight);
        Apply(new { command = "resize_split", workspace_id = workspaceId, split_id = splitId, ratio });
    }

    private void NewTab(string? paneId = null)
    {
        var workspace = SelectedWorkspace();
        var pane = paneId is null ? workspace.SelectedPane : workspace.Panes.FirstOrDefault(item => item.Id == paneId);
        if (pane is null) return;
        Apply(new { command = "create_surface", workspace_id = workspace.Id, pane_id = pane.Id, surface_id = Id("surface"), session_id = Id("session") });
    }

    private void Split(string direction)
    {
        var workspace = SelectedWorkspace();
        var pane = workspace.SelectedPane;
        if (pane is null) return;
        Apply(new { command = "split_pane", workspace_id = workspace.Id, pane_id = pane.Id, split_id = Id("split"), new_pane_id = Id("pane"), new_surface_id = Id("surface"), session_id = Id("session"), direction, ratio = 0.5 });
    }

    private void OnTabCloseRequested(TabView sender, TabViewTabCloseRequestedEventArgs args)
    {
        if (args.Tab.Tag is SurfaceTag tag)
            Apply(new { command = "close_surface", workspace_id = tag.WorkspaceId, pane_id = tag.PaneId, surface_id = tag.SurfaceId });
    }

    private static void OnTabDragStarting(TabView sender, TabViewTabDragStartingEventArgs args)
    {
        if (args.Tab.Tag is not SurfaceTag tag)
        {
            args.Cancel = true;
            return;
        }
        args.Data.Properties[TabDragDataKey] = JsonSerializer.Serialize(new TabDragPayload(tag.WorkspaceId, tag.PaneId, tag.SurfaceId));
        args.Data.RequestedOperation = DataPackageOperation.Move;
    }

    private static void OnTabStripDragOver(object sender, DragEventArgs args)
    {
        if (sender is not TabView { Tag: PaneTag target } || !TryGetDragPayload(args, out var payload)) return;
        if (payload.WorkspaceId == target.WorkspaceId)
            args.AcceptedOperation = DataPackageOperation.Move;
    }

    private void OnTabStripDrop(object sender, DragEventArgs args)
    {
        if (sender is not TabView { Tag: PaneTag target } tabs || !TryGetDragPayload(args, out var payload)) return;
        if (payload.WorkspaceId != target.WorkspaceId || payload.PaneId == target.PaneId) return;
        var beforeSurfaceId = SurfaceBeforeDropPoint(tabs, args.GetPosition(tabs));
        args.AcceptedOperation = DataPackageOperation.Move;
        args.Handled = true;
        Apply(new
        {
            command = "move_surface",
            workspace_id = payload.WorkspaceId,
            source_pane_id = payload.PaneId,
            surface_id = payload.SurfaceId,
            target_pane_id = target.PaneId,
            before_surface_id = beforeSurfaceId,
        });
    }

    private static bool TryGetDragPayload(DragEventArgs args, out TabDragPayload payload)
    {
        payload = null!;
        if (!args.DataView.Properties.TryGetValue(TabDragDataKey, out var value) || value is not string json) return false;
        try
        {
            payload = JsonSerializer.Deserialize<TabDragPayload>(json)!;
            return payload is not null;
        }
        catch (JsonException) { return false; }
    }

    private static string? SurfaceBeforeDropPoint(TabView tabs, Point point)
    {
        foreach (var item in tabs.TabItems.OfType<TabViewItem>())
        {
            if (item.Tag is not SurfaceTag tag || item.ActualWidth <= 0) continue;
            var origin = item.TransformToVisual(tabs).TransformPoint(new Point(0, 0));
            if (point.X < origin.X + item.ActualWidth / 2) return tag.SurfaceId;
        }
        return null;
    }

    private void OnTabSelectionChanged(object sender, SelectionChangedEventArgs args)
    {
        if (_projecting || sender is not TabView tabs || tabs.SelectedItem is not TabViewItem { Tag: SurfaceTag tag }) return;
        SelectSurfaceWithoutProjection(tag, focusTerminal: true);
    }

    private void OnPaneGotFocus(object sender, RoutedEventArgs args)
    {
        if (_projecting || sender is not TabView tabs || tabs.SelectedItem is not TabViewItem { Tag: SurfaceTag tag }) return;
        var workspace = SelectedWorkspace();
        if (workspace.SelectedPaneId != tag.PaneId || workspace.SelectedPane?.SelectedSurfaceId != tag.SurfaceId)
            SelectSurfaceWithoutProjection(tag, focusTerminal: false);
    }

    private void SelectSurfaceWithoutProjection(SurfaceTag tag, bool focusTerminal)
    {
        try
        {
            _snapshot = Dispatch(new { command = "select_surface", workspace_id = tag.WorkspaceId, pane_id = tag.PaneId, surface_id = tag.SurfaceId });
            if (focusTerminal) _terminals[tag.SurfaceId].FocusTerminal();
        }
        catch (Exception error) { _ = ShowErrorAsync(Localizer.Get("CoreError"), error.Message); }
    }

    private void OnTabDragCompleted(TabView sender, TabViewTabDragCompletedEventArgs args)
    {
        if (_projecting || sender.Tag is not PaneTag pane) return;
        if (args.Tab.Tag is SurfaceTag dragged && SurfacePaneId(dragged.SurfaceId) is { } currentPaneId && currentPaneId != dragged.PaneId)
            return;
        try
        {
            CoreSnapshot result = _snapshot;
            for (var index = sender.TabItems.Count - 1; index >= 0; index--)
            {
                if (sender.TabItems[index] is not TabViewItem { Tag: SurfaceTag item }) continue;
                var before = index + 1 < sender.TabItems.Count && sender.TabItems[index + 1] is TabViewItem { Tag: SurfaceTag next } ? next.SurfaceId : null;
                result = Dispatch(new { command = "reorder_surface", workspace_id = pane.WorkspaceId, pane_id = pane.PaneId, surface_id = item.SurfaceId, before_surface_id = before });
            }
            _snapshot = result;
            ProjectSnapshot();
        }
        catch (Exception error)
        {
            try { _snapshot = _core.Snapshot(); ProjectSnapshot(); }
            catch (Exception snapshotError) { System.Diagnostics.Debug.WriteLine($"Core recovery failed: {snapshotError}"); }
            _ = ShowErrorAsync(Localizer.Get("CoreError"), error.Message);
        }
    }

    private void OnKeyDown(object sender, KeyRoutedEventArgs args)
    {
        if (_shortcuts.Matches("new_tab", args.Key)) NewTab();
        else if (_shortcuts.Matches("close_tab", args.Key)) CloseSelectedTab();
        else if (_shortcuts.Matches("split_vertical", args.Key)) Split("vertical");
        else if (_shortcuts.Matches("split_horizontal", args.Key)) Split("horizontal");
        else if (_shortcuts.Matches("open_settings", args.Key)) _ = ShowSettingsAsync();
        else if (_shortcuts.Matches("copy", args.Key)) ActiveTerminal()?.Copy();
        else if (_shortcuts.Matches("paste", args.Key) || _shortcuts.Matches("paste_alternate", args.Key)) ActiveTerminal()?.Paste();
        else
        {
            for (var index = 1; index <= 9; index++)
                if (_shortcuts.Matches($"select_tab_{index}", args.Key)) { SelectTab(index - 1); args.Handled = true; return; }
            return;
        }
        args.Handled = true;
    }

    private void CloseSelectedTab()
    {
        var workspace = SelectedWorkspace();
        var pane = workspace.SelectedPane;
        if (pane?.SelectedSurface is not null)
            Apply(new { command = "close_surface", workspace_id = workspace.Id, pane_id = pane.Id, surface_id = pane.SelectedSurface.Id });
    }

    private void SelectTab(int index)
    {
        var workspace = SelectedWorkspace();
        var pane = workspace.SelectedPane;
        if (pane is not null && index < pane.Surfaces.Count)
            Apply(new { command = "select_surface", workspace_id = workspace.Id, pane_id = pane.Id, surface_id = pane.Surfaces[index].Id });
    }

    private TerminalView? ActiveTerminal()
    {
        var id = SelectedWorkspace().SelectedPane?.SelectedSurfaceId;
        return id is not null && _terminals.TryGetValue(id, out var terminal) ? terminal : null;
    }

    private WorkspaceSnapshot SelectedWorkspace() =>
        _snapshot.Workspaces.First(item => item.Id == _snapshot.SelectedWorkspaceId);

    private CoreSnapshot Dispatch(object command) => _core.Dispatch(command);

    private string? SurfacePaneId(string surfaceId) => _snapshot.Workspaces
        .SelectMany(workspace => workspace.Panes)
        .FirstOrDefault(pane => pane.Surfaces.Any(surface => surface.Id == surfaceId))?.Id;

    private void Apply(object command)
    {
        try
        {
            _snapshot = Dispatch(command);
            if (_snapshot.Workspaces.Count == 0) Close();
            else ProjectSnapshot();
        }
        catch (Exception error) { _ = ShowErrorAsync(Localizer.Get("CoreError"), error.Message); }
    }

    private async Task ShowSettingsAsync()
    {
        if (_dialogOpen || Root.XamlRoot is null) return;
        var panel = new StackPanel { Spacing = 8, MinWidth = 420 };
        var editors = new Dictionary<string, TextBox>(StringComparer.Ordinal);
        foreach (var pair in _shortcuts.Values)
        {
            var editor = new TextBox { Header = Localizer.Get($"Shortcut_{pair.Key}"), Text = pair.Value };
            editors[pair.Key] = editor;
            panel.Children.Add(editor);
        }
        var scroll = new ScrollViewer { Content = panel, MaxHeight = 520 };
        var dialog = new ContentDialog { XamlRoot = Root.XamlRoot, Title = Localizer.Get("Settings"), Content = scroll, PrimaryButtonText = Localizer.Get("Save"), CloseButtonText = Localizer.Get("Cancel"), DefaultButton = ContentDialogButton.Primary };
        ContentDialogResult result;
        _dialogOpen = true;
        try { result = await dialog.ShowAsync(); }
        finally { _dialogOpen = false; }
        if (result != ContentDialogResult.Primary) return;
        try
        {
            var candidate = ShortcutSettings.Create(editors.ToDictionary(pair => pair.Key, pair => pair.Value.Text, StringComparer.Ordinal));
            candidate.Save();
            _shortcuts = candidate;
        }
        catch (Exception error) { await ShowErrorAsync(Localizer.Get("ShortcutError"), error.Message); }
    }

    private async Task ShowErrorAsync(string title, string message)
    {
        System.Diagnostics.Debug.WriteLine($"{title}: {message}");
        if (_dialogOpen || Root.XamlRoot is null) return;
        _dialogOpen = true;
        try { await new ContentDialog { XamlRoot = Root.XamlRoot, Title = title, Content = message, CloseButtonText = Localizer.Get("OK") }.ShowAsync(); }
        finally { _dialogOpen = false; }
    }

    private void RemoveClosedTerminals()
    {
        var alive = _snapshot.Workspaces.SelectMany(workspace => workspace.Panes).SelectMany(pane => pane.Surfaces).Select(surface => surface.Id).ToHashSet(StringComparer.Ordinal);
        foreach (var id in _terminals.Keys.Where(id => !alive.Contains(id)).ToArray())
        {
            _terminals[id].Dispose();
            _terminals.Remove(id);
        }
    }

    private void OnClosed(object sender, WindowEventArgs args)
    {
        foreach (var terminal in _terminals.Values) terminal.Dispose();
        _core.Dispose();
    }

    private sealed record PaneTag(string WorkspaceId, string PaneId);
    private sealed record SurfaceTag(string WorkspaceId, string PaneId, string SurfaceId);
    private sealed record TabDragPayload(string WorkspaceId, string PaneId, string SurfaceId);
}
