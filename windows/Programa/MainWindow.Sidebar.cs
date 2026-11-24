using System.Text.Json;
using Microsoft.UI.Input;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Documents;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Markup;
using Microsoft.UI.Xaml.Media;
using Windows.ApplicationModel.DataTransfer;
using Windows.System;

namespace Programa;

/// <summary>The workspace list, as on macOS (Sources/TabItemView.swift, Sources/VerticalTabsSidebar.swift):
/// one row per workspace with its status line, description, metadata, a branch and directory line per
/// panel, every pull request and the listening ports. Hovering shows ••• and close; middle-click closes;
/// rows drag to reorder and take a dropped pane tab; Ctrl/Shift-click picks several rows for the menu;
/// double-clicking below the rows adds a workspace at the end; holding Ctrl shows the digit shortcuts.
/// The list is rebuilt on every projection, so a row only updates in place between them, and its
/// branch, pull request and port lines only redraw when what they show changed.</summary>
public sealed partial class MainWindow
{
    private const string WorkspaceDragDataKey = "com.darkroom.programa.sidebar-tab-reorder";
    /// <summary>macOS SessionPersistencePolicy: 238 to 600, and never more than a third of the window.</summary>
    internal const double SidebarMinWidth = 238, SidebarMaxWidth = 600;

    private ListView? _sidebarList;
    private double _sidebarScroll;
    /// <summary>Rows picked with Ctrl- or Shift-click, for the menu; they belong to <see cref="_pickedFor"/>,
    /// the workspace selected when they were picked, and reset when another gets selected some other way.</summary>
    private readonly HashSet<string> _pickedWorkspaces = new(StringComparer.Ordinal);
    private string? _pickedFor;
    private string? _pressedWorkspace;
    private bool _shortcutHints;
    private Microsoft.UI.Dispatching.DispatcherQueueTimer? _hintTimer;

    private sealed class SidebarRow
    {
        public required ListViewItem Item;
        public required ContentControl Icon;
        public required TextBlock Title;
        public required InfoBadge Unread;
        public required TextBlock Elapsed;
        public required Button More;
        public required Button CloseButton;
        public required Border Hint;
        public required Border Pill;
        public required FontIcon PillIcon;
        public required TextBlock PillLabel;
        public required TextBlock Message;
        public required HyperlinkButton Helpers;
        public required StackPanel Metadata;
        public required StackPanel Branches;
        public required StackPanel PullRequests;
        public required StackPanel Ports;
        public required Border DropLine;
        public bool Hovered;
        public string? BranchStamp, PullRequestStamp, PortStamp;
    }

    internal static double ClampSidebarWidth(double width, double windowWidth) =>
        Math.Clamp(width, SidebarMinWidth, Math.Max(SidebarMinWidth, Math.Min(SidebarMaxWidth, windowWidth > 0 ? windowWidth / 3 : SidebarMaxWidth)));

    private FrameworkElement BuildSidebar()
    {
        // The scroll position survives the rebuild.
        if (_sidebarList is not null && Descendant<ScrollViewer>(_sidebarList) is { } scroller) _sidebarScroll = scroller.VerticalOffset;
        _sidebarRows.Clear();
        _pressedWorkspace = null;
        var selectedId = SelectedWorkspace()?.Id;
        _pickedWorkspaces.IntersectWith(_snapshot.Workspaces.Select(item => item.Id));
        if (_pickedFor != selectedId || _pickedWorkspaces.Count == 0)
        {
            _pickedWorkspaces.Clear();
            if (selectedId is not null) _pickedWorkspaces.Add(selectedId);
            _pickedFor = selectedId;
        }
        var list = new ListView { SelectionMode = ListViewSelectionMode.Extended, Padding = new Thickness(4, 8, 4, 8), CanDragItems = true, AllowDrop = true, Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent) };
        AutomationProperties.SetName(list, Localizer.Get("Workspaces"));
        _sidebarList = list;
        foreach (var workspace in _snapshot.Workspaces)
        {
            // A collapsed parent hides its worktree workspaces (macOS sidebar folder rows).
            if (IsHiddenChild(workspace)) continue;
            var row = BuildSidebarRow(workspace);
            list.Items.Add(row.Item);
            _sidebarRows[workspace.Id] = row;
            UpdateSidebarRow(workspace.Id);
        }
        foreach (var item in list.Items.OfType<ListViewItem>())
            if (_pickedWorkspaces.Contains((string)item.Tag)) list.SelectedItems.Add(item);
        list.SelectionChanged += (_, _) => OnSidebarSelectionChanged(list);
        list.DragItemsStarting += (_, args) =>
        {
            var ids = args.Items.OfType<ListViewItem>().Select(item => (string)item.Tag).ToList();
            if (ids.Count == 0) { args.Cancel = true; return; }
            args.Data.Properties[WorkspaceDragDataKey] = string.Join('\n', ids);
            args.Data.RequestedOperation = DataPackageOperation.Move;
        };
        // Below the rows: a dragged row goes to the end, a double-click adds a workspace at the end.
        list.DragOver += (_, args) =>
        {
            if (DraggedWorkspaces(args) is not null) args.AcceptedOperation = DataPackageOperation.Move;
        };
        list.Drop += (_, args) =>
        {
            if (DraggedWorkspaces(args) is not { } ids) return;
            args.AcceptedOperation = DataPackageOperation.Move;
            DispatcherQueue.TryEnqueue(() => MoveWorkspaces(ids, _snapshot.Workspaces.Count));
        };
        list.DoubleTapped += (_, args) =>
        {
            if (args.OriginalSource is DependencyObject source && Ancestor<ListViewItem>(source) is null)
                Apply(new { command = "create_workspace", workspace_id = Id("workspace"), pane_id = Id("pane"), surface_id = Id("surface"), session_id = Id("session"), placement = "end" });
        };
        list.Loaded += (_, _) => Descendant<ScrollViewer>(list)?.ChangeView(null, _sidebarScroll, null, disableAnimation: true);

        var resize = new Thumb { Width = 4, Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent) };
        AutomationProperties.SetName(resize, Localizer.Get("ToggleSidebar"));
        resize.DragDelta += (_, args) =>
        {
            _sidebarWidth = ClampSidebarWidth(_sidebarWidth + args.HorizontalChange, Root.ActualWidth);
            Root.ColumnDefinitions[0].Width = new GridLength(_sidebarWidth);
        };
        resize.DragCompleted += (_, _) => UpdateDragRegions();
        // The sidebar runs up into the title bar row, as on macOS, and ends with a footer.
        var sidebar = new Grid();
        sidebar.RowDefinitions.Add(new RowDefinition { Height = new GridLength(TitleBarHeight) });
        sidebar.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        sidebar.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        sidebar.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        sidebar.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var footer = SidebarFooter();
        sidebar.Children.Add(list);
        sidebar.Children.Add(footer);
        sidebar.Children.Add(resize);
        Grid.SetRow(list, 1);
        Grid.SetRow(footer, 2);
        Grid.SetColumn(resize, 1);
        Grid.SetRowSpan(resize, 3);
        return sidebar;
    }

    /// <summary>A click picks the row (Ctrl adds or removes it, Shift a range) and selects the clicked
    /// workspace, or the last picked one when Ctrl took the selected one out.</summary>
    private void OnSidebarSelectionChanged(ListView list)
    {
        if (_projecting) return;
        var picked = list.SelectedItems.OfType<ListViewItem>().Select(item => (string)item.Tag).ToList();
        var clicked = _pressedWorkspace;
        _pressedWorkspace = null;
        var current = _snapshot.SelectedWorkspaceId;
        if (picked.Count == 0)
        {
            // Ctrl-click on the only picked row: it stays picked.
            if (current is not null && _sidebarRows.TryGetValue(current, out var row)) list.SelectedItems.Add(row.Item);
            return;
        }
        var target = clicked is not null && picked.Contains(clicked) ? clicked : current is not null && picked.Contains(current) ? current : picked[^1];
        _pickedWorkspaces.Clear();
        _pickedWorkspaces.UnionWith(picked);
        _pickedFor = target;
        if (target != current) Apply(new { command = "select_workspace", workspace_id = target });
    }

    /// <summary>What the row menu acts on: the picked rows, in list order, when this row is one of
    /// several picked, else this row.</summary>
    private List<string> MenuTargets(string workspaceId) =>
        _pickedWorkspaces.Count > 1 && _pickedWorkspaces.Contains(workspaceId)
            ? _snapshot.Workspaces.Where(item => _pickedWorkspaces.Contains(item.Id)).Select(item => item.Id).ToList()
            : [workspaceId];

    private SidebarRow BuildSidebarRow(WorkspaceSnapshot workspace)
    {
        var id = workspace.Id;
        var icon = new ContentControl { MinWidth = 16, Height = 16, Margin = new Thickness(0, 2, 10, 0), VerticalAlignment = VerticalAlignment.Top, IsTabStop = false };
        var title = new TextBlock { TextTrimming = TextTrimming.CharacterEllipsis, TextWrapping = TextWrapping.NoWrap };
        var unread = new InfoBadge { Margin = new Thickness(6, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center, Visibility = Visibility.Collapsed };
        var firstLine = new StackPanel { Orientation = Orientation.Horizontal };
        firstLine.Children.Add(title);
        // A worktree workspace gets a branch badge after its title, a pinned one a pin, as on macOS.
        if (workspace.ParentId is not null)
        {
            var badge = LineIcon(BranchIconPath, 11);
            badge.Margin = new Thickness(5, 0, 0, 0);
            badge.Opacity = 0.7;
            ToolTipService.SetToolTip(badge, Localizer.Get("SidebarWorktreeBadge"));
            AutomationProperties.SetName(badge, Localizer.Get("SidebarWorktreeBadge"));
            firstLine.Children.Add(badge);
        }
        if (workspace.Pinned)
        {
            var pin = new FontIcon { Glyph = char.ConvertFromUtf32(0xE718), FontSize = 11, Opacity = 0.7, Margin = new Thickness(6, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center };
            ToolTipService.SetToolTip(pin, Localizer.Get("SidebarPinnedProtected"));
            firstLine.Children.Add(pin);
        }
        firstLine.Children.Add(unread);

        // The elapsed time sits flush right; hovering swaps it for ••• and close, and holding Ctrl
        // shows the row's digit shortcut where close was.
        var elapsed = new TextBlock { FontSize = 11, Opacity = 0.6, VerticalAlignment = VerticalAlignment.Center, HorizontalAlignment = HorizontalAlignment.Right };
        var more = RowButton(char.ConvertFromUtf32(0xE712), Localizer.Get("SidebarMoreActions"));
        var close = RowButton(char.ConvertFromUtf32(0xE711), Localizer.Get("SidebarCloseWorkspace"));
        ToolTipService.SetToolTip(close, workspace.Pinned ? Localizer.Get("SidebarPinnedProtected") : ShortcutTooltip(Localizer.Get("SidebarCloseWorkspace"), "close_workspace"));
        close.Click += (_, _) => CloseWorkspace(id);
        var digit = SidebarRowModel.ShortcutDigit(_snapshot.Workspaces.ToList().FindIndex(item => item.Id == id), _snapshot.Workspaces.Count);
        var hintText = digit is { } number && _shortcuts.Values.GetValueOrDefault($"select_workspace_{number}") is { Length: > 0 } binding ? ShortcutSettings.Display(binding) : null;
        var hint = new Border
        {
            Child = new TextBlock { Text = hintText ?? string.Empty, FontSize = 10, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold },
            CornerRadius = new CornerRadius(8),
            Padding = new Thickness(6, 1, 6, 2),
            VerticalAlignment = VerticalAlignment.Center,
            HorizontalAlignment = HorizontalAlignment.Right,
            Background = ThemeBrush("LayerFillColorDefaultBrush"),
            BorderBrush = ThemeBrush("CardStrokeColorDefaultBrush"),
            BorderThickness = new Thickness(1),
            Visibility = Visibility.Collapsed,
            Tag = hintText,
        };
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right };
        buttons.Children.Add(more);
        buttons.Children.Add(close);
        var trailing = new Grid { Margin = new Thickness(6, 0, 0, 0) };
        trailing.Children.Add(elapsed);
        trailing.Children.Add(buttons);
        trailing.Children.Add(hint);
        var titleLine = new Grid();
        titleLine.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        titleLine.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        titleLine.Children.Add(firstLine);
        titleLine.Children.Add(trailing);
        Grid.SetColumn(trailing, 1);

        // The agent pill: glyph and label tinted by state, on its own translucent backing (macOS agentStatusPill).
        var pillIcon = new FontIcon { FontSize = 10 };
        var pillLabel = new TextBlock { FontSize = 11 };
        var pillContent = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4 };
        pillContent.Children.Add(pillIcon);
        pillContent.Children.Add(pillLabel);
        var pill = new Border
        {
            Child = pillContent,
            CornerRadius = new CornerRadius(8),
            Padding = new Thickness(6, 1, 6, 2),
            Margin = new Thickness(0, 3, 0, 0),
            HorizontalAlignment = HorizontalAlignment.Left,
            BorderThickness = new Thickness(1),
            Background = ThemeBrush("LayerFillColorDefaultBrush"),
            BorderBrush = ThemeBrush("CardStrokeColorDefaultBrush"),
        };
        var message = new TextBlock { FontSize = 12, Opacity = 0.7, Margin = new Thickness(0, 2, 0, 0), TextTrimming = TextTrimming.CharacterEllipsis, TextWrapping = TextWrapping.NoWrap };
        var text = new StackPanel();
        text.Children.Add(titleLine);
        // One status line, then the description wrapped below it, as on macOS.
        text.Children.Add(pill);
        text.Children.Add(message);
        if (workspace.Description is { } description) text.Children.Add(DescriptionText(description));
        // "N helpers running" under the status, as on macOS.
        var helpersLine = HelpersLine(id);
        text.Children.Add(helpersLine);
        // Status entries, markdown blocks, the latest log line and progress (macOS sidebar metadata).
        var metadataLines = new StackPanel { Margin = new Thickness(0, 2, 0, 0), Visibility = Visibility.Collapsed };
        text.Children.Add(metadataLines);
        var branches = new StackPanel { Margin = new Thickness(0, 2, 0, 0), Visibility = Visibility.Collapsed };
        var pullRequests = new StackPanel { Margin = new Thickness(0, 1, 0, 0), Visibility = Visibility.Collapsed };
        var ports = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6, Margin = new Thickness(0, 1, 0, 0), Visibility = Visibility.Collapsed };
        text.Children.Add(branches);
        text.Children.Add(pullRequests);
        text.Children.Add(ports);

        var rowGrid = new Grid { Padding = new Thickness(0, 6, 0, 6) };
        // A worktree workspace sits indented under its repository's workspace.
        if (workspace.ParentId is not null) rowGrid.Margin = new Thickness(18, 0, 0, 0);
        // The workspace color as a bar along the row's leading edge.
        if (workspace.Color is { Length: 7 } color)
        {
            rowGrid.BorderBrush = new SolidColorBrush(ParseColor(color));
            rowGrid.BorderThickness = new Thickness(3, 0, 0, 0);
            rowGrid.Padding = new Thickness(7, 6, 0, 6);
        }
        rowGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        rowGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        rowGrid.Children.Add(icon);
        rowGrid.Children.Add(text);
        Grid.SetColumn(text, 1);
        // Where a dragged row would land: a line above or below this one.
        var dropLine = new Border { Height = 2, Background = ThemeBrush("AccentFillColorDefaultBrush"), VerticalAlignment = VerticalAlignment.Top, IsHitTestVisible = false, Visibility = Visibility.Collapsed };
        rowGrid.Children.Add(dropLine);
        Grid.SetColumnSpan(dropLine, 2);

        var menu = new MenuFlyout();
        menu.Opening += (_, _) => FillWorkspaceMenu(menu, id);
        var item = new ListViewItem { Content = rowGrid, Tag = id, ContextFlyout = menu, AllowDrop = true };
        more.Click += (_, _) => menu.ShowAt(more);
        var row = new SidebarRow
        {
            Item = item, Icon = icon, Title = title, Unread = unread, Elapsed = elapsed, More = more, CloseButton = close, Hint = hint,
            Pill = pill, PillIcon = pillIcon, PillLabel = pillLabel, Message = message, Helpers = helpersLine, Metadata = metadataLines,
            Branches = branches, PullRequests = pullRequests, Ports = ports, DropLine = dropLine,
        };
        item.PointerEntered += (_, _) => { row.Hovered = true; UpdateRowAccessories(row); };
        item.PointerExited += (_, _) => { row.Hovered = false; UpdateRowAccessories(row); };
        item.AddHandler(UIElement.PointerPressedEvent, new PointerEventHandler((_, args) =>
        {
            var point = args.GetCurrentPoint(item).Properties;
            if (point.IsMiddleButtonPressed)
            {
                args.Handled = true;
                CloseWorkspace(id);
            }
            else if (point.IsLeftButtonPressed) _pressedWorkspace = id;
        }), handledEventsToo: true);
        item.DragOver += (_, args) => OnRowDragOver(row, id, args);
        item.DragLeave += (_, _) => row.DropLine.Visibility = Visibility.Collapsed;
        item.Drop += (_, args) => OnRowDrop(row, id, args);
        UpdateRowAccessories(row);
        return row;
    }

    private static Button RowButton(string glyph, string label)
    {
        var button = new Button
        {
            Content = new FontIcon { Glyph = glyph, FontSize = 10 },
            Width = 22,
            Height = 18,
            Padding = new Thickness(0),
            Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent),
            BorderThickness = new Thickness(0),
            IsTabStop = false,
        };
        AutomationProperties.SetName(button, label);
        ToolTipService.SetToolTip(button, label);
        return button;
    }

    private string ShortcutTooltip(string label, string action) =>
        _shortcuts.Values.GetValueOrDefault(action) is { Length: > 0 } binding ? $"{label} ({ShortcutSettings.Display(binding)})" : label;

    /// <summary>Hover shows ••• and close in place of the elapsed time; Ctrl held shows the digit hint
    /// in place of close. Hidden buttons stay in the tree (transparent and not hit-testable), as on macOS.</summary>
    private void UpdateRowAccessories(SidebarRow row)
    {
        var hint = _shortcutHints && row.Hint.Tag is string;
        row.Hint.Visibility = hint ? Visibility.Visible : Visibility.Collapsed;
        row.Elapsed.Opacity = row.Hovered ? 0 : 0.6;
        row.More.Opacity = row.Hovered ? 1 : 0;
        row.More.IsHitTestVisible = row.Hovered;
        var showClose = row.Hovered && !hint;
        row.CloseButton.Opacity = showClose ? 1 : 0;
        row.CloseButton.IsHitTestVisible = showClose;
    }

    /// <summary>A description as macOS shows it: inline markdown, wrapped, its own line breaks kept.</summary>
    private static TextBlock DescriptionText(string description)
    {
        var text = new TextBlock { FontSize = 12, Opacity = 0.8, Margin = new Thickness(0, 2, 0, 0), TextWrapping = TextWrapping.Wrap };
        var lines = description.Replace("\r\n", "\n").Split('\n');
        for (var index = 0; index < lines.Length; index++)
        {
            if (index > 0) text.Inlines.Add(new LineBreak());
            if (lines[index].Length > 0) AddMarkdown(text.Inlines, lines[index], inlineOnly: true);
        }
        AutomationProperties.SetName(text, description);
        return text;
    }

    /// <summary>Refreshes one row in place: title, icon, status line, metadata, branch lines, pull
    /// requests and ports. The selected workspace's title is also the window title, as on macOS.</summary>
    private void UpdateSidebarRow(string workspaceId)
    {
        var index = _snapshot.Workspaces.ToList().FindIndex(item => item.Id == workspaceId);
        if (index < 0) return;
        var workspace = _snapshot.Workspaces[index];
        var title = WorkspaceTitle(workspace);
        if (workspaceId == SelectedWorkspace()?.Id && Title != title) Title = title;
        if (!_sidebarRows.TryGetValue(workspaceId, out var row)) return;
        var surfaces = OrderedSurfaceIds(workspace);
        var terminals = surfaces.Select(id => _terminals.GetValueOrDefault(id)).OfType<TerminalView>().ToList();
        var now = DateTimeOffset.Now;
        var indicator = AgentIndicator.From(
            terminals.Where(terminal => terminal.EffectiveStatus is not null).Select(terminal => (terminal.EffectiveStatus!, terminal.ProgramStatusChangedAt)),
            now);

        // A program's title loses its spinner glyph while the status line shows the agent; a name you gave stays as written.
        var shownTitle = workspace.Title is null && indicator is not null ? SidebarRowModel.StripSpinnerGlyph(title) : title;
        if (row.Title.Text != shownTitle)
        {
            row.Title.Text = shownTitle;
            ToolTipService.SetToolTip(row.Title, shownTitle);
        }
        var unread = _notifications.UnreadCount(workspaceId);
        row.Unread.Value = unread;
        row.Unread.Visibility = unread > 0 ? Visibility.Visible : Visibility.Collapsed;
        row.Icon.Content = IsWorktreeFolder(workspace) ? FolderIcon(workspace) : AgentLogo(indicator?.App, 16) ?? new FontIcon { Glyph = char.ConvertFromUtf32(0xE756), FontSize = 14 };
        UpdateHelpersLine(workspace.Id, row.Helpers);
        UpdateBranchLines(workspace, surfaces, title, row);
        UpdatePullRequestLines(workspace, surfaces, row);
        UpdatePortsLine(workspace, row);

        // One status line: the agent while it works or waits, else the latest notification, else the
        // agent's resting state, else the latest log line.
        var latestLog = SidebarMetadata.Of(workspaceId)?.Log.LastOrDefault();
        var notification = _notifications.Latest(workspaceId);
        var notificationText = notification is null ? null : (notification.Body.Trim() is { Length: > 0 } body ? body : notification.Title.Trim()) is { Length: > 0 } shown ? shown : null;
        var source = SidebarRowModel.PickStatus(indicator?.State, notificationText is not null, latestLog is not null);
        UpdateMetadataLines(workspaceId, row.Metadata, statusShowsLog: source == SidebarRowModel.StatusSource.Log);
        if (source == SidebarRowModel.StatusSource.Agent && indicator is not null)
        {
            var label = Localizer.Get(indicator.LabelKey);
            var tint = ThemeBrush(indicator.State switch
            {
                "blocked" or "error" => "SystemFillColorCriticalBrush",
                "working" => "AccentTextFillColorPrimaryBrush",
                "done" => "SystemFillColorSuccessBrush",
                _ => "TextFillColorSecondaryBrush",
            });
            row.PillIcon.Glyph = indicator.Glyph;
            row.PillIcon.Foreground = row.PillLabel.Foreground = tint;
            row.PillLabel.Text = label;
            row.Pill.Opacity = indicator.IsStale ? 0.55 : 1;
            row.Pill.Visibility = Visibility.Visible;
            row.Elapsed.Text = ElapsedText(now - indicator.LastEventAt);
            row.Message.Text = indicator.Message ?? string.Empty;
            row.Message.Visibility = indicator.Message is null ? Visibility.Collapsed : Visibility.Visible;
            AutomationProperties.SetName(row.Item, $"{row.Title.Text}, {label}");
            return;
        }
        var (status, at) = source switch
        {
            SidebarRowModel.StatusSource.Notification => (notificationText, notification!.CreatedAt),
            SidebarRowModel.StatusSource.Log => (latestLog!.Message, latestLog.At),
            _ => ((string?)null, now),
        };
        row.Pill.Visibility = Visibility.Collapsed;
        row.Message.Text = status ?? string.Empty;
        row.Message.Visibility = status is null ? Visibility.Collapsed : Visibility.Visible;
        row.Elapsed.Text = status is null ? string.Empty : ElapsedText(now - at);
        AutomationProperties.SetName(row.Item, status is null ? row.Title.Text : $"{row.Title.Text}, {status}");
    }

    private static string ElapsedText(TimeSpan since) =>
        AgentIndicator.Elapsed(since) is var (key, value) ? string.Format(Localizer.Get(key), value) : Localizer.Get("ElapsedNow");

    /// <summary>The workspace's tabs in layout order: pane by pane, each pane's tabs in order.</summary>
    private static List<string> OrderedSurfaceIds(WorkspaceSnapshot workspace)
    {
        var ordered = new List<string>();
        void Visit(LayoutSnapshot? node)
        {
            if (node is null) return;
            if (node.Type == "pane" && workspace.Panes.FirstOrDefault(pane => pane.Id == node.PaneId) is { } pane) ordered.AddRange(pane.Surfaces.Select(surface => surface.Id));
            Visit(node.First);
            Visit(node.Second);
        }
        Visit(workspace.Layout);
        // A pane the layout does not name (never expected) still counts.
        ordered.AddRange(workspace.Panes.SelectMany(pane => pane.Surfaces).Select(surface => surface.Id).Where(id => !ordered.Contains(id)));
        return ordered;
    }

    /// <summary>One branch and directory line per panel directory, `*` after a dirty branch.</summary>
    private void UpdateBranchLines(WorkspaceSnapshot workspace, List<string> surfaces, string title, SidebarRow row)
    {
        var lines = SidebarRowModel.BranchLines(surfaces.Select(id => (_branches.GetValueOrDefault(id), _reportedDirty.GetValueOrDefault(id), _terminals.GetValueOrDefault(id)?.Cwd)), title);
        var stamp = string.Join('\n', lines.Select(line => $"{line.Branch}\t{line.Directory}"));
        if (stamp == row.BranchStamp) return;
        row.BranchStamp = stamp;
        row.Branches.Children.Clear();
        foreach (var line in lines)
        {
            var text = line.Branch is not null && line.Directory is not null ? $"{line.Branch} • {line.Directory}" : line.Branch ?? line.Directory!;
            var block = new TextBlock { Text = text, FontSize = 11, Opacity = 0.7, FontFamily = new FontFamily("Cascadia Mono, Consolas"), TextTrimming = TextTrimming.CharacterEllipsis, TextWrapping = TextWrapping.NoWrap };
            ToolTipService.SetToolTip(block, text);
            row.Branches.Children.Add(block);
        }
        row.Branches.Visibility = lines.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
    }

    /// <summary>Every pull request the workspace's panels have, once each, with its state icon, as on macOS.</summary>
    private void UpdatePullRequestLines(WorkspaceSnapshot workspace, List<string> surfaces, SidebarRow row)
    {
        var pullRequests = WorkspacePullRequests(surfaces);
        var stamp = string.Join('\n', pullRequests.Select(pr => $"{pr.Label}\t{pr.Number}\t{pr.State}\t{pr.Url}"));
        if (stamp == row.PullRequestStamp) return;
        row.PullRequestStamp = stamp;
        row.PullRequests.Children.Clear();
        foreach (var pullRequest in pullRequests)
        {
            var state = Localizer.Get(pullRequest.State switch { "open" => "PullRequestOpen", "merged" => "PullRequestMerged", _ => "PullRequestClosed" });
            var content = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4 };
            content.Children.Add(LineIcon(pullRequest.State switch { "open" => PullRequestOpenPath, "merged" => PullRequestMergedPath, _ => PullRequestClosedPath }, 12));
            content.Children.Add(new TextBlock { Text = $"{pullRequest.Label} #{pullRequest.Number}", FontSize = 11, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold, TextDecorations = Windows.UI.Text.TextDecorations.Underline });
            content.Children.Add(new TextBlock { Text = state, FontSize = 11, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold });
            var link = new HyperlinkButton { Content = content, Padding = new Thickness(0), Margin = new Thickness(0, 1, 0, 0), NavigateUri = new Uri(pullRequest.Url) };
            var tooltip = string.Format(Localizer.Get("SidebarOpenPullRequest"), pullRequest.Label, pullRequest.Number);
            ToolTipService.SetToolTip(link, tooltip);
            AutomationProperties.SetName(link, $"{pullRequest.Label} #{pullRequest.Number} {state}");
            row.PullRequests.Children.Add(link);
        }
        row.PullRequests.Visibility = pullRequests.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
    }

    /// <summary>The ports the workspace's programs listen on, each a link to localhost.</summary>
    private void UpdatePortsLine(WorkspaceSnapshot workspace, SidebarRow row)
    {
        var ports = WorkspacePorts(workspace);
        var stamp = string.Join(',', ports);
        if (stamp == row.PortStamp) return;
        row.PortStamp = stamp;
        row.Ports.Children.Clear();
        foreach (var port in ports)
        {
            var link = new HyperlinkButton
            {
                Content = new TextBlock { Text = $":{port}", FontSize = 11, FontFamily = new FontFamily("Cascadia Mono, Consolas"), TextDecorations = Windows.UI.Text.TextDecorations.Underline },
                Padding = new Thickness(0),
                NavigateUri = new Uri($"http://localhost:{port}"),
            };
            var tooltip = string.Format(Localizer.Get("SidebarOpenPort"), port);
            ToolTipService.SetToolTip(link, tooltip);
            AutomationProperties.SetName(link, tooltip);
            row.Ports.Children.Add(link);
        }
        row.Ports.Visibility = ports.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
    }

    /// <summary>After a port scan: rows whose ports changed redraw that line.</summary>
    private void RefreshSidebarPorts()
    {
        foreach (var (workspaceId, row) in _sidebarRows)
            if (_snapshot.Workspaces.FirstOrDefault(item => item.Id == workspaceId) is { } workspace) UpdatePortsLine(workspace, row);
    }

    // 13x13 line drawings of the macOS sidebar icons (TabItemView PullRequestOpenIcon and friends).
    private const string PullRequestOpenPath = "M3,4.8 L3,9.2 M4.8,3 L9.4,3 L11,4.6 L11,9.2 M1.5,3 A1.5,1.5 0 1 0 4.5,3 A1.5,1.5 0 1 0 1.5,3 M1.5,11 A1.5,1.5 0 1 0 4.5,11 A1.5,1.5 0 1 0 1.5,11 M9.5,11 A1.5,1.5 0 1 0 12.5,11 A1.5,1.5 0 1 0 9.5,11";
    private const string PullRequestMergedPath = "M4.6,4.6 L7.1,7 L9.2,7 M4.6,9.4 L7.1,7 M1.5,3 A1.5,1.5 0 1 0 4.5,3 A1.5,1.5 0 1 0 1.5,3 M1.5,11 A1.5,1.5 0 1 0 4.5,11 A1.5,1.5 0 1 0 1.5,11 M9.5,7 A1.5,1.5 0 1 0 12.5,7 A1.5,1.5 0 1 0 9.5,7";
    private const string PullRequestClosedPath = "M1,6.5 A5.5,5.5 0 1 0 12,6.5 A5.5,5.5 0 1 0 1,6.5 M4.5,4.5 L8.5,8.5 M8.5,4.5 L4.5,8.5";
    private const string BranchIconPath = "M4,4 L4,10 M10,6 C10,8.5 4,7.5 4,10 M2.5,2.5 A1.5,1.5 0 1 0 5.5,2.5 A1.5,1.5 0 1 0 2.5,2.5 M2.5,11.5 A1.5,1.5 0 1 0 5.5,11.5 A1.5,1.5 0 1 0 2.5,11.5 M8.5,4.5 A1.5,1.5 0 1 0 11.5,4.5 A1.5,1.5 0 1 0 8.5,4.5";

    /// <summary>A stroked 13x13 drawing scaled to <paramref name="size"/>, in the text color. Each
    /// call parses its own Geometry: WinUI refuses one Geometry in two elements.</summary>
    private static FrameworkElement LineIcon(string data, double size) => new Viewbox
    {
        Width = size,
        Height = size,
        VerticalAlignment = VerticalAlignment.Center,
        Child = new Microsoft.UI.Xaml.Shapes.Path
        {
            Data = (Geometry)XamlBindingHelper.ConvertValue(typeof(Geometry), data),
            Stroke = ThemeBrush("TextFillColorSecondaryBrush"),
            StrokeThickness = 1.2,
            StrokeStartLineCap = PenLineCap.Round,
            StrokeEndLineCap = PenLineCap.Round,
            StrokeLineJoin = PenLineJoin.Round,
            Width = 13,
            Height = 13,
        },
    };

    private static List<string>? DraggedWorkspaces(DragEventArgs args) =>
        args.DataView.Properties.TryGetValue(WorkspaceDragDataKey, out var value) && value is string ids ? [.. ids.Split('\n')] : null;

    private void OnRowDragOver(SidebarRow row, string workspaceId, DragEventArgs args)
    {
        if (DraggedWorkspaces(args) is { } ids && ids.All(id => _snapshot.Workspaces.Any(item => item.Id == id)))
        {
            args.AcceptedOperation = DataPackageOperation.Move;
            args.Handled = true;
            var below = args.GetPosition(row.Item).Y > row.Item.ActualHeight / 2;
            row.DropLine.VerticalAlignment = below ? VerticalAlignment.Bottom : VerticalAlignment.Top;
            row.DropLine.Visibility = Visibility.Visible;
            return;
        }
        // A pane tab dropped on a row moves into that workspace (macOS SidebarBonsplitTabDropDelegate).
        if (TryGetDragPayload(args, out var payload) && payload.WorkspaceId != workspaceId)
        {
            args.AcceptedOperation = DataPackageOperation.Move;
            args.Handled = true;
        }
    }

    private void OnRowDrop(SidebarRow row, string workspaceId, DragEventArgs args)
    {
        row.DropLine.Visibility = Visibility.Collapsed;
        if (DraggedWorkspaces(args) is { } ids && ids.All(id => _snapshot.Workspaces.Any(item => item.Id == id)))
        {
            args.AcceptedOperation = DataPackageOperation.Move;
            args.Handled = true;
            var below = args.GetPosition(row.Item).Y > row.Item.ActualHeight / 2;
            var slot = _snapshot.Workspaces.ToList().FindIndex(item => item.Id == workspaceId) + (below ? 1 : 0);
            // After the drag finishes: moving rebuilds the list the drag came from.
            DispatcherQueue.TryEnqueue(() => MoveWorkspaces(ids, slot));
            return;
        }
        if (!TryGetDragPayload(args, out var payload) || payload.WorkspaceId == workspaceId) return;
        args.AcceptedOperation = DataPackageOperation.Move;
        args.Handled = true;
        DispatcherQueue.TryEnqueue(() =>
        {
            try { WindowRegistry.MoveTab(payload.WorkspaceId, payload.PaneId, payload.SurfaceId, this, workspaceId, SelectedPaneOf(workspaceId), null); }
            catch (Exception error) when (error is CoreCommandException or ControlException) { _ = ShowErrorAsync(Localizer.Get("CoreError"), error.Message); }
        });
    }

    /// <summary>Moves the workspaces, in list order, to sit together before list position <paramref name="slot"/>.</summary>
    private void MoveWorkspaces(List<string> ids, int slot)
    {
        try
        {
            _snapshot = MoveWorkspaces(Dispatch, _snapshot, ids, slot);
            ProjectSnapshot();
        }
        catch (Exception error) { _ = ShowErrorAsync(Localizer.Get("CoreError"), error.Message); }
    }

    /// <summary>The moves behind a drag: each workspace, in list order, goes before <paramref name="slot"/>
    /// and the next one after it, wherever the core put it (pinned ones stay first).</summary>
    internal static CoreSnapshot MoveWorkspaces(Func<object, CoreSnapshot> dispatch, CoreSnapshot snapshot, ICollection<string> ids, int slot)
    {
        foreach (var id in snapshot.Workspaces.Select(item => item.Id).Where(ids.Contains).ToList())
        {
            var from = snapshot.Workspaces.ToList().FindIndex(item => item.Id == id);
            snapshot = dispatch(new { command = "move_workspace", workspace_id = id, index = Math.Max(0, slot > from ? slot - 1 : slot) });
            slot = snapshot.Workspaces.ToList().FindIndex(item => item.Id == id) + 1;
        }
        return snapshot;
    }

    /// <summary>Ctrl held on its own for a moment shows each row's digit shortcut (macOS holds ⌘).
    /// Wired to the root's tunneling key events, so a focused terminal does not hide them.</summary>
    private void InitializeShortcutHints()
    {
        Root.PreviewKeyDown += (_, args) =>
        {
            if (!IsModifier(args.Key))
            {
                // A shortcut typed quickly is not a hold.
                if (!_shortcutHints) _hintTimer?.Stop();
                return;
            }
            if (HeldModifiers() != HintModifiers()) { ShowShortcutHints(false); return; }
            if (_shortcutHints || _hintTimer?.IsRunning == true) return;
            _hintTimer ??= CreateHintTimer();
            _hintTimer.Start();
        };
        Root.PreviewKeyUp += (_, args) =>
        {
            if (IsModifier(args.Key)) ShowShortcutHints(false);
        };
        Activated += (_, args) =>
        {
            if (args.WindowActivationState == WindowActivationState.Deactivated) ShowShortcutHints(false);
        };
    }

    private Microsoft.UI.Dispatching.DispatcherQueueTimer CreateHintTimer()
    {
        var timer = DispatcherQueue.CreateTimer();
        timer.Interval = TimeSpan.FromMilliseconds(300);
        timer.IsRepeating = false;
        timer.Tick += (_, _) => { if (HeldModifiers() == HintModifiers()) ShowShortcutHints(true); };
        return timer;
    }

    private void ShowShortcutHints(bool show)
    {
        if (!show) _hintTimer?.Stop();
        if (_shortcutHints == show) return;
        _shortcutHints = show;
        foreach (var row in _sidebarRows.Values) UpdateRowAccessories(row);
    }

    private static bool IsModifier(VirtualKey key) => key is VirtualKey.Control or VirtualKey.LeftControl or VirtualKey.RightControl
        or VirtualKey.Shift or VirtualKey.LeftShift or VirtualKey.RightShift or VirtualKey.Menu or VirtualKey.LeftMenu or VirtualKey.RightMenu
        or VirtualKey.LeftWindows or VirtualKey.RightWindows;

    private static string HeldModifiers() =>
        (Down(VirtualKey.Control) ? "ctrl-" : "") + (Down(VirtualKey.Menu) ? "alt-" : "") + (Down(VirtualKey.Shift) ? "shift-" : "");

    private static bool Down(VirtualKey key) => InputKeyboardSource.GetKeyStateForCurrentThread(key).HasFlag(Windows.UI.Core.CoreVirtualKeyStates.Down);

    /// <summary>The modifiers of Select Workspace 1 ("ctrl-" for Ctrl+1); none means no hints.</summary>
    private string HintModifiers() =>
        _shortcuts.Values.GetValueOrDefault("select_workspace_1") is { } binding && binding.LastIndexOf('-') is > 0 and var dash ? binding[..(dash + 1)] : "none";

    /// <summary>Dev builds: debug.sidebar.menu lists a row's menu as it would open now (with `invoke`,
    /// runs the item with that text instead); debug.sidebar.hints shows or hides the digit hints.</summary>
    internal object SidebarDebug(string method, JsonElement p)
    {
        if (method == "debug.sidebar.hints")
        {
            ShowShortcutHints(p.TryGetProperty("show", out var show) && show.ValueKind == JsonValueKind.True);
            return new { shown = _shortcutHints };
        }
        var id = WorkspaceTarget(p).Id;
        var menu = new MenuFlyout();
        FillWorkspaceMenu(menu, id);
        IEnumerable<MenuFlyoutItemBase> All(IEnumerable<MenuFlyoutItemBase> items) =>
            items.SelectMany(item => item is MenuFlyoutSubItem sub ? All(sub.Items).Prepend(sub) : [item]);
        if (Text(p, "invoke") is { } invoke)
        {
            if (All(menu.Items).OfType<MenuFlyoutItem>().FirstOrDefault(item => item.Text == invoke) is not { Tag: Action run, IsEnabled: true })
                throw new ControlException("not_found", $"No enabled menu item '{invoke}'.");
            run();
            return new { workspace_id = id, invoked = invoke };
        }
        object Describe(MenuFlyoutItemBase item) => item switch
        {
            MenuFlyoutSubItem sub => new { text = sub.Text, enabled = sub.IsEnabled, items = sub.Items.Select(Describe).ToList() },
            MenuFlyoutItem leaf => new { text = leaf.Text, enabled = leaf.IsEnabled, shortcut = leaf.KeyboardAcceleratorTextOverride },
            _ => new { text = "-" },
        };
        return new { workspace_id = id, targets = MenuTargets(id), items = menu.Items.Select(Describe).ToList() };
    }

    private static T? Descendant<T>(DependencyObject root) where T : DependencyObject
    {
        for (var index = 0; index < VisualTreeHelper.GetChildrenCount(root); index++)
        {
            var child = VisualTreeHelper.GetChild(root, index);
            if (child is T found) return found;
            if (Descendant<T>(child) is { } deeper) return deeper;
        }
        return null;
    }

    private static T? Ancestor<T>(DependencyObject node) where T : DependencyObject
    {
        for (var current = node; current is not null; current = VisualTreeHelper.GetParent(current))
            if (current is T found) return found;
        return null;
    }
}
