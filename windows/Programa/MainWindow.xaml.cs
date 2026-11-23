using System.Text.Json;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Windows.ApplicationModel.DataTransfer;
using Windows.Foundation;
using Windows.System;

namespace Programa;

public sealed partial class MainWindow : Window
{
    private const string TabDragDataKey = "com.darkroom.programa.surface-drag";
    private readonly CoreClient _core = new();
    private readonly Dictionary<string, TerminalView> _terminals = new(StringComparer.Ordinal);
    private readonly Dictionary<string, TabViewItem> _tabItems = new(StringComparer.Ordinal);
    private CoreSnapshot _snapshot;
    private ShortcutSettings _shortcuts;
    private string? _startupSettingsError;
    private bool _dialogOpen;
    private bool _projecting;
    /// <summary>From a rebuild until its refocus: focus moving around the new tree is not a pane pick.</summary>
    private bool _settlingFocus;
    private bool _activationLogged;
    private readonly bool _smoke;
    private bool _sidebarVisible = true;
    private double _sidebarWidth = 240;
    /// <summary>Sidebar row parts by workspace id, so title and status changes update in place.</summary>
    private readonly Dictionary<string, SidebarRow> _sidebarRows = new(StringComparer.Ordinal);
    private readonly Microsoft.UI.Dispatching.DispatcherQueueTimer _sidebarClock;
    /// <summary>The directory the next terminal created by a projection starts in.</summary>
    private string? _nextTerminalDirectory;
    /// <summary>The command the next terminal created runs first (CLI --command).</summary>
    private string? _nextTerminalCommand;
    /// <summary>Each terminal's git branch, read when its shell reports a directory.</summary>
    private readonly Dictionary<string, string?> _branches = new(StringComparer.Ordinal);

    /// <summary>A window restored from the session, holding a workspace moved from another window,
    /// or with one fresh workspace. Open windows through <see cref="WindowRegistry.OpenWindow"/>.</summary>
    internal MainWindow(bool smoke = false, SavedSession? restore = null, WorkspaceTransfer? adopt = null)
    {
        _smoke = smoke;
        InitializeComponent();
        // Windows 11's material behind the sidebar and toolbar, the counterpart of macOS sidebar glass.
        SystemBackdrop = new MicaBackdrop();
        InitializeTitleBar();
        ApplyAppearance();
        _shortcuts = LoadSettingsOrDefaults();
        _snapshot = _core.Snapshot();
        Root.PreviewKeyDown += OnKeyDown;
        Root.Loaded += OnRootLoaded;
        Closed += OnClosed;
        Activated += OnActivated;
        InitializeNotifications();
        if (adopt is not null) AdoptWorkspace(adopt);
        else if (restore is null || !RestoreSession(restore))
            _snapshot = Dispatch(new { command = "create_workspace", workspace_id = Id("workspace"), pane_id = Id("pane"), surface_id = Id("surface"), session_id = Id("session") });
        ProjectSnapshot();
        StartPortScan();
        StartPullRequestPolling();
        StartAgentDetection();
        InitializeCloseConfirmation();
        // Elapsed times and "(stale)" advance once a minute, as on macOS.
        _sidebarClock = DispatcherQueue.CreateTimer();
        _sidebarClock.Interval = TimeSpan.FromMinutes(1);
        _sidebarClock.Tick += (_, _) => { foreach (var id in _sidebarRows.Keys.ToList()) UpdateSidebarRow(id); };
        _sidebarClock.Start();
    }

    private void OnActivated(object sender, WindowActivatedEventArgs args)
    {
        if (args.WindowActivationState != WindowActivationState.Deactivated) WindowRegistry.Activated(this);
        if (_activationLogged) return;
        _activationLogged = true;
        LaunchLog.Write("launch ok: window shown");
        LaunchLog.LaunchCompleted = true;
        if (_smoke) _ = RunSmokeTestAsync();
    }

    /// <summary>
    /// CI-only path exercised by `programa.exe --smoke`: by the time this fires,
    /// Application.Start has run, MainWindow exists and is activated, and the
    /// create_workspace fallback in the constructor above has already spawned one
    /// terminal. This waits for that terminal to report its first snapshot -- proof
    /// the native ConPTY session and the WinUI rendering path both actually worked,
    /// not just that the window opened -- then exits the process with a definitive
    /// pass/fail code for the CI step to check.
    /// </summary>
    private async Task RunSmokeTestAsync()
    {
        var terminal = _terminals.Values.FirstOrDefault();
        if (terminal is null)
        {
            LaunchLog.Write("smoke: no terminal was spawned");
            Environment.Exit(1);
            return;
        }
        if (!terminal.HasSnapshot)
        {
            var ready = new TaskCompletionSource();
            terminal.FirstSnapshotReady += () => ready.TrySetResult();
            if (terminal.HasSnapshot) ready.TrySetResult();
            var completed = await Task.WhenAny(ready.Task, Task.Delay(TimeSpan.FromSeconds(20)));
            if (completed != ready.Task)
            {
                LaunchLog.Write("smoke: timed out waiting for the first terminal snapshot");
                Environment.Exit(1);
                return;
            }
        }
        LaunchLog.Write("smoke: first terminal snapshot received");
        Environment.Exit(0);
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
            Root.ColumnDefinitions.Clear();
            Root.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(_sidebarVisible ? _sidebarWidth : 0) });
            Root.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            RemoveClosedTerminals();
            _paneRings.Clear();
            _paneElements.Clear();

            var content = new Grid();
            content.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            content.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
            content.Children.Add(BuildToolbar());
            var workspace = SelectedWorkspace();
            NoteSelectedWorkspace();
            _layoutElement = null;
            if (workspace is not null)
            {
                // A zoomed pane fills the workspace on its own (macOS Toggle Pane Zoom).
                var zoomed = _zoomedPanes.GetValueOrDefault(workspace.Id) is { } zoomedId ? workspace.Panes.FirstOrDefault(pane => pane.Id == zoomedId) : null;
                var layout = zoomed is not null ? BuildPane(workspace.Id, zoomed) : BuildLayout(workspace, workspace.Layout);
                content.Children.Add(layout);
                Grid.SetRow(layout, 1);
                _layoutElement = layout;
            }
            Root.Children.Add(content);
            Grid.SetColumn(content, 1);
            // After the layout, so a new workspace's terminal exists when its row reads it.
            if (_sidebarVisible) Root.Children.Add(BuildSidebar());
        }
        finally { _projecting = false; }
        WindowRegistry.NoteWorkspaces();
        MarkVisibleRead();
        RefreshUnreadIndicators();
        // Rebuilding the tree drops keyboard focus. Refocus once the new tree has been laid out,
        // unless a dialog is open and should keep it.
        _settlingFocus = true;
        DispatcherQueue.TryEnqueue(Microsoft.UI.Dispatching.DispatcherQueuePriority.Low, () =>
        {
            _settlingFocus = false;
            if (!_dialogOpen && !_footerFlyoutOpen) ActiveTerminal()?.FocusTerminal();
        });
    }

    private static void DetachTerminals(DependencyObject node)
    {
        // Terminals outlive a projection; free them from their old pane host before reuse.
        if (node is Border border)
        {
            if (border.Child is TerminalView or IPanel) border.Child = null;
            else if (border.Child is DependencyObject child) DetachTerminals(child);
            return;
        }
        if (node is Panel panel)
            foreach (var child in panel.Children) DetachTerminals(child);
        else if (node is ContentControl { Content: DependencyObject content })
            DetachTerminals(content);
    }

    private FrameworkElement BuildToolbar()
    {
        // The toolbar is the title bar row (see MainWindow.Chrome.cs): Notifications and New
        // Workspace, then Toggle Sidebar, at the sidebar's trailing edge, as on macOS.
        var leading = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Left, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(4, 0, 0, 0) };
        _bell = IconButton("", "Notifications", "show_notifications", ShowNotificationsPanel);
        leading.Children.Add(_bell);
        leading.Children.Add(IconButton("", "NewWorkspace", "new_workspace", NewWorkspace));
        leading.Children.Add(IconButton("", "ToggleSidebar", "toggle_sidebar", ToggleSidebar));
        _toolbarButtons = leading;
        leading.SizeChanged += (_, _) => UpdateDragRegions();
        return new Grid { Height = TitleBarHeight, Children = { leading } };
    }

    /// <summary>An icon-only toolbar button whose tooltip names its current shortcut.</summary>
    private AppBarButton IconButton(string glyph, string labelKey, string action, Action handler)
    {
        var label = Localizer.Get(labelKey);
        var button = new AppBarButton { Icon = new FontIcon { Glyph = glyph }, LabelPosition = CommandBarLabelPosition.Collapsed, Width = 44, MinHeight = 44 };
        AutomationProperties.SetName(button, label);
        ToolTipService.SetToolTip(button, $"{label} ({ShortcutSettings.Display(_shortcuts.Values[action])})");
        button.Click += (_, _) => handler();
        return button;
    }

    private FrameworkElement BuildSidebar()
    {
        _sidebarRows.Clear();
        var list = new ListView { SelectionMode = ListViewSelectionMode.Single, Padding = new Thickness(4, 8, 4, 8) };
        AutomationProperties.SetName(list, Localizer.Get("Workspaces"));
        for (var index = 0; index < _snapshot.Workspaces.Count; index++)
        {
            var workspace = _snapshot.Workspaces[index];
            // A collapsed parent hides its worktree workspaces (macOS sidebar folder rows).
            if (IsHiddenChild(workspace)) continue;
            var icon = new ContentControl { Width = 16, Height = 16, Margin = new Thickness(0, 2, 10, 0), VerticalAlignment = VerticalAlignment.Top, IsTabStop = false };
            var title = new TextBlock { TextTrimming = TextTrimming.CharacterEllipsis, TextWrapping = TextWrapping.NoWrap };
            var elapsed = new TextBlock { FontSize = 11, Opacity = 0.6, Margin = new Thickness(8, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center };
            // The unread notification count, as on macOS.
            var unread = new InfoBadge { Margin = new Thickness(6, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center, Visibility = Visibility.Collapsed };
            var firstLine = new Grid();
            firstLine.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            firstLine.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            firstLine.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            firstLine.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            firstLine.Children.Add(title);
            firstLine.Children.Add(unread);
            firstLine.Children.Add(elapsed);
            Grid.SetColumn(unread, 2);
            Grid.SetColumn(elapsed, 3);
            // A pin after the title of a pinned workspace, as on macOS.
            if (workspace.Pinned)
            {
                var pin = new FontIcon { Glyph = "", FontSize = 11, Opacity = 0.7, Margin = new Thickness(6, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center };
                firstLine.Children.Add(pin);
                Grid.SetColumn(pin, 1);
            }
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
            text.Children.Add(firstLine);
            if (workspace.Description is { } description)
                text.Children.Add(new TextBlock { Text = description, FontSize = 12, Opacity = 0.8, Margin = new Thickness(0, 1, 0, 0), TextTrimming = TextTrimming.CharacterEllipsis, TextWrapping = TextWrapping.NoWrap });
            text.Children.Add(pill);
            text.Children.Add(message);
            // "N helpers running" under the status, as on macOS.
            var helpersLine = HelpersLine(workspace.Id);
            text.Children.Add(helpersLine);
            // Status entries, markdown blocks, the latest log line and progress (macOS sidebar metadata).
            var metadataLines = new StackPanel { Margin = new Thickness(0, 2, 0, 0), Visibility = Visibility.Collapsed };
            text.Children.Add(metadataLines);
            var branchLine = new TextBlock { FontSize = 12, Opacity = 0.7, Margin = new Thickness(0, 2, 0, 0), TextTrimming = TextTrimming.CharacterEllipsis, TextWrapping = TextWrapping.NoWrap };
            var directoryLine = new TextBlock { FontSize = 12, Opacity = 0.6, TextTrimming = TextTrimming.CharacterEllipsis, TextWrapping = TextWrapping.NoWrap };
            text.Children.Add(branchLine);
            text.Children.Add(directoryLine);
            // The branch's pull request, a link to it (macOS sidebar PR row).
            var pullRequestLine = new HyperlinkButton { Content = new TextBlock { FontSize = 12, TextTrimming = TextTrimming.CharacterEllipsis }, Padding = new Thickness(0), Margin = new Thickness(0, 1, 0, 0), Visibility = Visibility.Collapsed };
            text.Children.Add(pullRequestLine);
            var row = new Grid { Padding = new Thickness(0, 6, 0, 6) };
            // A worktree workspace sits indented under its repository's workspace.
            if (workspace.ParentId is not null) row.Margin = new Thickness(18, 0, 0, 0);
            // The workspace color as a bar along the row's leading edge.
            if (workspace.Color is { Length: 7 } color)
            {
                row.BorderBrush = new SolidColorBrush(ParseColor(color));
                row.BorderThickness = new Thickness(3, 0, 0, 0);
                row.Padding = new Thickness(7, 6, 0, 6);
            }
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            row.Children.Add(icon);
            row.Children.Add(text);
            Grid.SetColumn(text, 1);

            var item = new ListViewItem { Content = row, Tag = workspace.Id, ContextFlyout = WorkspaceMenu(workspace) };
            list.Items.Add(item);
            if (workspace.Id == SelectedWorkspace()?.Id) list.SelectedItem = item;
            _sidebarRows[workspace.Id] = new SidebarRow(item, icon, title, unread, elapsed, pill, pillIcon, pillLabel, message, branchLine, directoryLine, pullRequestLine, helpersLine, metadataLines);
            UpdateSidebarRow(workspace.Id);
        }
        list.SelectionChanged += (_, _) =>
        {
            if (!_projecting && list.SelectedItem is ListViewItem { Tag: string id } && id != _snapshot.SelectedWorkspaceId)
                Apply(new { command = "select_workspace", workspace_id = id });
        };

        var resize = new Thumb { Width = 4, Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent) };
        AutomationProperties.SetName(resize, Localizer.Get("ToggleSidebar"));
        resize.DragDelta += (_, args) =>
        {
            _sidebarWidth = Math.Clamp(_sidebarWidth + args.HorizontalChange, 160, 480);
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

    private static MenuFlyoutItem MenuItem(string text, Action handler)
    {
        var item = new MenuFlyoutItem { Text = text };
        item.Click += (_, _) => handler();
        return item;
    }

    /// <summary>The name you gave the workspace, else its focused terminal's title, else "Workspace N".</summary>
    private string WorkspaceTitle(WorkspaceSnapshot workspace)
    {
        var focusedId = workspace.SelectedPane?.SelectedSurfaceId;
        var focused = focusedId is null ? null : _terminals.GetValueOrDefault(focusedId);
        return workspace.Title ?? (focusedId is null ? null : SurfaceTitle(focusedId)) ?? DisplayTitle(focused?.Title)
            ?? (focusedId is null ? null : _panels.GetValueOrDefault(focusedId)?.Title ?? (_restorePanels.TryGetValue(focusedId, out var path) ? Path.GetFileName(path) : null))
            ?? string.Format(Localizer.Get("WorkspaceDefaultTitle"), _snapshot.Workspaces.ToList().FindIndex(item => item.Id == workspace.Id) + 1);
    }

    /// <summary>Refreshes one sidebar row from its workspace's terminals: the user's title or the
    /// focused terminal's, the agent's logo, and the agent pill with the time since its last report.</summary>
    private void UpdateSidebarRow(string workspaceId)
    {
        var index = _snapshot.Workspaces.ToList().FindIndex(item => item.Id == workspaceId);
        if (index < 0 || !_sidebarRows.TryGetValue(workspaceId, out var row)) return;
        var workspace = _snapshot.Workspaces[index];
        var terminals = workspace.Panes.SelectMany(pane => pane.Surfaces)
            .Select(surface => _terminals.GetValueOrDefault(surface.Id)).OfType<TerminalView>().ToList();
        var focusedId = workspace.SelectedPane?.SelectedSurfaceId;
        var focused = focusedId is null ? null : _terminals.GetValueOrDefault(focusedId);
        var title = WorkspaceTitle(workspace);
        var now = DateTimeOffset.Now;
        var indicator = AgentIndicator.From(
            terminals.Where(terminal => terminal.EffectiveStatus is not null).Select(terminal => (terminal.EffectiveStatus!, terminal.ProgramStatusChangedAt)),
            now);

        row.Title.Text = title;
        var unread = _notifications.UnreadCount(workspaceId);
        row.Unread.Value = unread;
        row.Unread.Visibility = unread > 0 ? Visibility.Visible : Visibility.Collapsed;
        row.Icon.Content = HasChildren(workspace) ? FolderToggle(workspace) : AgentLogo(indicator?.App, 16) ?? new FontIcon { Glyph = "", FontSize = 14 };
        // The branch and directory lines of the focused terminal; the directory is left out when it
        // is home or repeats the title, as on macOS.
        var branch = focusedId is null ? null : _branches.GetValueOrDefault(focusedId);
        var directory = focused?.Cwd is { } cwd ? GitInfo.AbbreviateHome(cwd) : null;
        if (directory == "~" || string.Equals(directory, title, StringComparison.OrdinalIgnoreCase)) directory = null;
        row.Branch.Text = branch ?? string.Empty;
        row.Branch.Visibility = branch is null ? Visibility.Collapsed : Visibility.Visible;
        row.Directory.Text = directory ?? string.Empty;
        row.Directory.Visibility = directory is null ? Visibility.Collapsed : Visibility.Visible;
        UpdatePullRequestLine(workspace, row.PullRequest);
        UpdateHelpersLine(workspace.Id, row.Helpers);
        // With no agent, the status line is the latest log message, as on macOS.
        var latestLog = indicator is null ? SidebarMetadata.Of(workspaceId)?.Log.LastOrDefault() : null;
        UpdateMetadataLines(workspaceId, row.Metadata, statusShowsLog: latestLog is not null);
        if (indicator is null)
        {
            row.Pill.Visibility = Visibility.Collapsed;
            row.Message.Text = latestLog?.Message ?? string.Empty;
            row.Message.Visibility = latestLog is null ? Visibility.Collapsed : Visibility.Visible;
            row.Elapsed.Text = latestLog is null ? string.Empty
                : AgentIndicator.Elapsed(now - latestLog.At) is var (logKey, logValue) ? string.Format(Localizer.Get(logKey), logValue) : Localizer.Get("ElapsedNow");
            AutomationProperties.SetName(row.Item, latestLog is null ? title : $"{title}, {latestLog.Message}");
            return;
        }
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
        row.Elapsed.Text = AgentIndicator.Elapsed(now - indicator.LastEventAt) is var (key, value)
            ? string.Format(Localizer.Get(key), value)
            : Localizer.Get("ElapsedNow");
        row.Message.Text = indicator.Message ?? string.Empty;
        row.Message.Visibility = indicator.Message is null ? Visibility.Collapsed : Visibility.Visible;
        AutomationProperties.SetName(row.Item, $"{title}, {label}");
    }

    private static Brush ThemeBrush(string key) => (Brush)Application.Current.Resources[key];

    /// <summary>The agent's logo scaled to <paramref name="size"/>, or null for agents without one.</summary>
    private FrameworkElement? AgentLogo(string? app, double size) =>
        AgentLogoSource(app) is { } logo ? new Image { Source = logo, Width = size, Height = size } : null;

    /// <summary>A shell reported its directory (each prompt): refresh the branch and the sidebar.</summary>
    private void OnTerminalCwdChanged(string surfaceId)
    {
        if (!_terminals.TryGetValue(surfaceId, out var terminal) || terminal.Cwd is not { } cwd) return;
        _branches[surfaceId] = GitInfo.Branch(cwd);
        if (_snapshot.Workspaces.FirstOrDefault(item => item.Panes.Any(pane => pane.Surfaces.Any(surface => surface.Id == surfaceId))) is { } workspace) LookUpPullRequest(workspace, refresh: false);
        UpdateSidebarRowForSurface(surfaceId);
    }

    private void UpdateSidebarRowForSurface(string surfaceId)
    {
        var workspace = _snapshot.Workspaces.FirstOrDefault(item => item.Panes.Any(pane => pane.Surfaces.Any(surface => surface.Id == surfaceId)));
        if (workspace is not null) UpdateSidebarRow(workspace.Id);
    }

    /// <summary>ConPTY titles a console with its executable path; show "powershell" instead.</summary>
    internal static string? DisplayTitle(string? title)
    {
        if (string.IsNullOrWhiteSpace(title)) return null;
        var trimmed = title.Trim();
        return Path.IsPathFullyQualified(trimmed) && trimmed.EndsWith(".exe", StringComparison.OrdinalIgnoreCase)
            ? Path.GetFileNameWithoutExtension(trimmed)
            : trimmed;
    }

    private void ToggleSidebar()
    {
        _sidebarVisible = !_sidebarVisible;
        ProjectSnapshot();
    }

    private void NewWorkspace() =>
        Apply(new { command = "create_workspace", workspace_id = Id("workspace"), pane_id = Id("pane"), surface_id = Id("surface"), session_id = Id("session"), placement = WorkspacePlacement });

    /// <summary>A new workspace in the focused terminal's directory running Claude Code (macOS ⌘⇧C).</summary>
    private void NewClaudeWorkspace()
    {
        _nextTerminalDirectory = ActiveTerminal()?.Cwd;
        _nextTerminalCommand = "claude";
        NewWorkspace();
    }

    /// <summary>1-8 pick that workspace; 9 is the last one, as on macOS.</summary>
    private void SelectWorkspaceByNumber(int number)
    {
        var workspaces = _snapshot.Workspaces;
        if (workspaces.Count == 0) return;
        var index = number == 9 ? workspaces.Count - 1 : number - 1;
        if (index < workspaces.Count) Apply(new { command = "select_workspace", workspace_id = workspaces[index].Id });
    }

    private void CycleWorkspace(int delta)
    {
        var workspaces = _snapshot.Workspaces;
        if (workspaces.Count < 2 || SelectedWorkspace() is not { } current) return;
        var index = workspaces.ToList().FindIndex(item => item.Id == current.Id);
        var next = workspaces[(index + delta + workspaces.Count) % workspaces.Count];
        Apply(new { command = "select_workspace", workspace_id = next.Id });
    }

    private async Task RenameWorkspaceAsync(string workspaceId)
    {
        if (_dialogOpen || Root.XamlRoot is null) return;
        var workspace = _snapshot.Workspaces.FirstOrDefault(item => item.Id == workspaceId);
        if (workspace is null) return;
        var box = new TextBox { Text = workspace.Title ?? string.Empty, PlaceholderText = _sidebarRows.GetValueOrDefault(workspaceId)?.Title.Text ?? string.Empty, MinWidth = 320 };
        box.Loaded += (_, _) => { box.Focus(FocusState.Programmatic); box.SelectAll(); };
        var dialog = new ContentDialog { XamlRoot = Root.XamlRoot, Title = Localizer.Get("RenameWorkspace"), Content = box, PrimaryButtonText = Localizer.Get("Rename"), CloseButtonText = Localizer.Get("Cancel"), DefaultButton = ContentDialogButton.Primary };
        ContentDialogResult result;
        _dialogOpen = true;
        try { result = await dialog.ShowAsync(); }
        finally { _dialogOpen = false; }
        // A blank name goes back to the derived title.
        if (result == ContentDialogResult.Primary) Apply(new { command = "rename_workspace", workspace_id = workspaceId, title = box.Text });
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
        // The TabView is only the tab strip; the selected terminal lives in this host below it,
        // as in Windows Terminal. TabView's own content presenter left a terminal opened as a
        // later tab with a canvas that never drew (a blank new tab).
        var host = new Border();
        AutomationProperties.SetName(tabs, Localizer.Get("Terminal"));
        tabs.TabStripFooter = PaneControls(workspaceId, pane.Id);
        tabs.AddTabButtonClick += (_, _) => NewTab(pane.Id);
        tabs.TabCloseRequested += OnTabCloseRequested;
        tabs.TabDragStarting += OnTabDragStarting;
        tabs.SelectionChanged += (_, _) =>
        {
            if (tabs.SelectedItem is TabViewItem { Tag: SurfaceTag tag } && SurfaceElement(tag.SurfaceId) is { } shown)
                host.Child = shown;
        };
        tabs.SelectionChanged += OnTabSelectionChanged;
        tabs.TabDragCompleted += OnTabDragCompleted;
        tabs.TabStripDragOver += OnTabStripDragOver;
        tabs.TabStripDrop += OnTabStripDrop;
        tabs.TabDroppedOutside += OnTabDroppedOutside;

        for (var surfaceIndex = 0; surfaceIndex < pane.Surfaces.Count; surfaceIndex++)
        {
            var surface = pane.Surfaces[surfaceIndex];
            if (PanelFor(surface.Id) is { } panel)
            {
                var panelItem = PanelTab(workspaceId, pane.Id, surface.Id, panel);
                StyleTab(panelItem, surface);
                tabs.TabItems.Add(panelItem);
                if (surface.Id == pane.SelectedSurfaceId)
                {
                    tabs.SelectedItem = panelItem;
                    host.Child = (UIElement)panel;
                }
                continue;
            }
            var terminal = TerminalFor(workspaceId, surface.Id);
            var item = new TabViewItem
            {
                Header = TabHeader(terminal),
                IconSource = TabIcon(terminal),
                Tag = new SurfaceTag(workspaceId, pane.Id, surface.Id),
            };
            StyleTab(item, surface);
            AutomationProperties.SetName(item, string.IsNullOrEmpty(terminal.Title) ? $"{Localizer.Get("Terminal")} {surfaceIndex + 1}" : terminal.Title);
            ApplyProgramStatusLabel(item, terminal);
            item.ContextFlyout = TabMenu(workspaceId, pane.Id, surface.Id);
            _tabItems[surface.Id] = item;
            tabs.TabItems.Add(item);
            if (surface.Id == pane.SelectedSurfaceId)
            {
                tabs.SelectedItem = item;
                host.Child = terminal;
            }
        }
        var paneGrid = new Grid();
        paneGrid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        paneGrid.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        var ring = PaneRing(pane.Id, host);
        paneGrid.Children.Add(tabs);
        paneGrid.Children.Add(host);
        paneGrid.Children.Add(ring);
        Grid.SetRow(host, 1);
        Grid.SetRow(ring, 1);
        AddDropTarget(paneGrid, host, workspaceId, pane.Id);
        // Focus in the terminal or on a tab makes this the workspace's selected pane.
        paneGrid.GotFocus += (_, args) => OnPaneGotFocus(tabs, args);
        _paneElements[pane.Id] = paneGrid;
        return paneGrid;
    }

    /// <summary>The surface's terminal, created on first use with what the session or the creating
    /// command left for it (directory, saved output, font size, initial command).</summary>
    private TerminalView TerminalFor(string workspaceId, string surfaceId)
    {
        if (_terminals.TryGetValue(surfaceId, out var existing)) return existing;
        if (IsPanel(surfaceId))
            throw new ControlException("invalid_params", $"{surfaceId} is a panel, not a terminal.");
        var saved = TakeRestoredTerminal(surfaceId);
        // A layout leaves a spec per surface; other creations leave the next terminal's directory and command.
        _pendingTerminals.Remove(surfaceId, out var spec);
        var terminal = spec is not null
            ? new TerminalView(surfaceId, workspaceId, spec.Cwd, null, spec.Command, spec.Env)
            : new TerminalView(surfaceId, workspaceId, saved?.Cwd ?? _nextTerminalDirectory, saved?.Text, _nextTerminalCommand);
        if (saved?.FontSize is { } fontSize) terminal.SetFontSize(fontSize);
        terminal.LastAgentSession = saved?.Agent;
        _nextTerminalDirectory = null;
        _nextTerminalCommand = null;
        Wire(terminal);
        _terminals.Add(surfaceId, terminal);
        return terminal;
    }

    private string TabTitle(TerminalView terminal)
    {
        var title = SurfaceTitle(terminal.SurfaceId) ?? DisplayTitle(terminal.Title) ?? Localizer.Get("Terminal");
        return terminal.EffectiveStatus?.Progress is int progress ? string.Format(Localizer.Get("ProgramStatusProgressFormat"), title, progress) : title;
    }

    /// <summary>The agent's logo when the program status names a known agent, as on macOS;
    /// otherwise the status symbol. The status stays in the tooltip and the sidebar pill.</summary>
    private IconSource TabIcon(TerminalView terminal)
    {
        // A plain terminal shows a terminal symbol, as on macOS.
        if (terminal.EffectiveStatus is not { } status) return new FontIconSource { Glyph = "" };
        // Logos are shared SVG images. Not a PathIconSource or Path: those hand one Geometry to every
        // element they create, and WinUI fails with "The parameter is incorrect" once a rebuilt tab
        // strip puts that Geometry in a second element.
        return AgentLogoSource(status.App) is { } logo
            ? new ImageIconSource { ImageSource = logo }
            : new SymbolIconSource { Symbol = ProgramStatusSymbol(status) };
    }

    private static Symbol ProgramStatusSymbol(ProgramStatusRecord? status) => status?.State switch
    {
        "working" => Symbol.Sync,
        "blocked" => Symbol.Help,
        "done" => Symbol.Accept,
        "error" => Symbol.Important,
        _ => Symbol.Document,
    };

    private static string? ProgramStatusLabel(string? state) => state switch
    {
        "working" => Localizer.Get("ProgramStatusWorking"),
        "blocked" => Localizer.Get("ProgramStatusBlocked"),
        "done" => Localizer.Get("ProgramStatusDone"),
        "error" => Localizer.Get("ProgramStatusError"),
        _ => null,
    };

    private static void ApplyProgramStatusLabel(TabViewItem item, TerminalView terminal)
    {
        var label = ProgramStatusLabel(terminal.EffectiveStatus?.State);
        AutomationProperties.SetItemStatus(item, label ?? string.Empty);
        if (label is null) item.ClearValue(ToolTipService.ToolTipProperty);
        else ToolTipService.SetToolTip(item, label);
    }

    private void OnTerminalHeaderChanged(string surfaceId)
    {
        if (_terminals.TryGetValue(surfaceId, out var changed)) NotifyOnStatusChange(surfaceId, changed);
        RefreshReviewsAfterTurn(surfaceId);
        if (_terminals.TryGetValue(surfaceId, out var agent))
        {
            NoteAgentSession(agent);
            NoteTurn(agent);
        }
        if (_tabItems.TryGetValue(surfaceId, out var item) && _terminals.TryGetValue(surfaceId, out var terminal))
        {
            item.Header = TabHeader(terminal);
            item.IconSource = TabIcon(terminal);
            ApplyProgramStatusLabel(item, terminal);
            if (!string.IsNullOrEmpty(terminal.Title)) AutomationProperties.SetName(item, terminal.Title);
        }
        UpdateSidebarRowForSurface(surfaceId);
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

    /// <summary>The shell in a tab exited: close that tab, as the macOS app does.</summary>
    private void OnTerminalExited(string surfaceId)
    {
        DispatcherQueue.TryEnqueue(() =>
        {
            foreach (var workspace in _snapshot.Workspaces)
            {
                var pane = workspace.Panes.FirstOrDefault(item => item.Surfaces.Any(surface => surface.Id == surfaceId));
                if (pane is null) continue;
                // Same command and last-surface handling as closing the tab by hand.
                Apply(new { command = "close_surface", workspace_id = workspace.Id, pane_id = pane.Id, surface_id = surfaceId });
                return;
            }
        });
    }

    private void NewTab(string? paneId = null)
    {
        if (SelectedWorkspace() is not { } workspace) return;
        var pane = paneId is null ? workspace.SelectedPane : workspace.Panes.FirstOrDefault(item => item.Id == paneId);
        if (pane is null) return;
        // New tabs and splits start where the focused terminal is, like Ghostty.
        _nextTerminalDirectory = ActiveTerminal()?.Cwd;
        Apply(new { command = "create_surface", workspace_id = workspace.Id, pane_id = pane.Id, surface_id = Id("surface"), session_id = Id("session") });
    }

    private void Split(string direction, string? paneId = null)
    {
        if (SelectedWorkspace() is not { } workspace) return;
        var pane = paneId is null ? workspace.SelectedPane : workspace.Panes.FirstOrDefault(item => item.Id == paneId);
        if (pane is null) return;
        _nextTerminalDirectory = ActiveTerminal()?.Cwd;
        Apply(new { command = "split_pane", workspace_id = workspace.Id, pane_id = pane.Id, split_id = Id("split"), new_pane_id = Id("pane"), new_surface_id = Id("surface"), session_id = Id("session"), direction, ratio = 0.5 });
    }

    private void OnTabCloseRequested(TabView sender, TabViewTabCloseRequestedEventArgs args)
    {
        if (args.Tab.Tag is SurfaceTag tag)
            CloseSurface(tag.WorkspaceId, tag.PaneId, tag.SurfaceId);
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

    private void OnTabStripDragOver(object sender, DragEventArgs args)
    {
        if (sender is not TabView { Tag: PaneTag target } || !TryGetDragPayload(args, out var payload)) return;
        if (payload.WorkspaceId == target.WorkspaceId || FromAnotherWindow(payload))
            args.AcceptedOperation = DataPackageOperation.Move;
    }

    /// <summary>A tab dragged here from another Programa window.</summary>
    private bool FromAnotherWindow(TabDragPayload payload) =>
        WindowRegistry.OwnerOfWorkspace(payload.WorkspaceId) is { } owner && owner != this;

    private void OnTabStripDrop(object sender, DragEventArgs args)
    {
        if (sender is not TabView { Tag: PaneTag target } tabs || !TryGetDragPayload(args, out var payload)) return;
        if ((payload.WorkspaceId != target.WorkspaceId && !FromAnotherWindow(payload)) || payload.PaneId == target.PaneId) return;
        var beforeSurfaceId = SurfaceBeforeDropPoint(tabs, args.GetPosition(tabs));
        args.AcceptedOperation = DataPackageOperation.Move;
        args.Handled = true;
        if (FromAnotherWindow(payload))
        {
            // After the drag finishes in both windows: moving rebuilds both tab strips.
            DispatcherQueue.TryEnqueue(() => WindowRegistry.MoveTab(payload.WorkspaceId, payload.PaneId, payload.SurfaceId, this, target.WorkspaceId, target.PaneId, beforeSurfaceId));
            return;
        }
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
        // A rebuilt TabView reports the selection it was built with as it loads; only a new tab is a pick.
        if (_snapshot.Workspaces.FirstOrDefault(item => item.Id == tag.WorkspaceId)?.Panes.FirstOrDefault(pane => pane.Id == tag.PaneId)?.SelectedSurfaceId == tag.SurfaceId) return;
        SelectSurfaceWithoutProjection(tag, focusTerminal: true);
    }

    private void OnPaneGotFocus(object sender, RoutedEventArgs args)
    {
        if (_projecting || _settlingFocus || sender is not TabView tabs || tabs.SelectedItem is not TabViewItem { Tag: SurfaceTag tag }) return;
        if (SelectedWorkspace() is not { } workspace) return;
        if (workspace.SelectedPaneId != tag.PaneId || workspace.SelectedPane?.SelectedSurfaceId != tag.SurfaceId)
            SelectSurfaceWithoutProjection(tag, focusTerminal: false);
    }

    private void SelectSurfaceWithoutProjection(SurfaceTag tag, bool focusTerminal)
    {
        try
        {
            _snapshot = Dispatch(new { command = "select_surface", workspace_id = tag.WorkspaceId, pane_id = tag.PaneId, surface_id = tag.SurfaceId });
            // Picking a tab you marked unread reads it.
            if (_manualUnread.Remove(tag.SurfaceId) && _tabItems.TryGetValue(tag.SurfaceId, out var picked) && _terminals.TryGetValue(tag.SurfaceId, out var pickedTerminal)) picked.Header = TabHeader(pickedTerminal);
            // The row's derived title follows the focused tab; a tab you now see is read.
            UpdateSidebarRow(tag.WorkspaceId);
            MarkVisibleRead();
            RefreshUnreadIndicators();
            if (focusTerminal) _terminals.GetValueOrDefault(tag.SurfaceId)?.FocusTerminal();
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

    private void CloseSelectedTab(string? paneId = null)
    {
        if (SelectedWorkspace() is not { } workspace) return;
        var pane = paneId is null ? workspace.SelectedPane : workspace.Panes.FirstOrDefault(item => item.Id == paneId);
        if (pane?.SelectedSurface is not null)
            CloseSurface(workspace.Id, pane.Id, pane.SelectedSurface.Id);
    }

    private TerminalView? ActiveTerminal()
    {
        var id = SelectedWorkspace()?.SelectedPane?.SelectedSurfaceId;
        return id is not null && _terminals.TryGetValue(id, out var terminal) ? terminal : null;
    }

    private WorkspaceSnapshot? SelectedWorkspace() =>
        _snapshot.Workspaces.FirstOrDefault(item => item.Id == _snapshot.SelectedWorkspaceId)
            ?? _snapshot.Workspaces.FirstOrDefault();

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
        DeleteCheckpointsOfClosedWorkspaces(_terminals.Where(item => !alive.Contains(item.Key)).Select(item => item.Value).ToList());
        foreach (var id in _terminals.Keys.Where(id => !alive.Contains(id)).ToArray())
        {
            // A closed tab whose shell still runs stays reopenable for a few seconds (macOS ⌘⇧T).
            KeepClosedTerminal(_terminals[id]);
            _terminals.Remove(id);
            _tabItems.Remove(id);
            _lastStatusState.Remove(id);
            _branches.Remove(id);
            _shellStates.Remove(id);
            _ttyNames.Remove(id);
            _reportedDirty.Remove(id);
            _reportedPullRequests.Remove(id);
            _reportedPorts.Remove(id);
        }
        foreach (var id in _panels.Keys.Where(id => !alive.Contains(id)).ToArray())
        {
            _panels.Remove(id, out var panel);
            panel!.Dispose();
            _tabItems.Remove(id);
        }
        RememberSurfaceLocations();
    }

    private void OnClosed(object sender, WindowEventArgs args)
    {
        WindowRegistry.Closed(this, _smoke ? null : CaptureSession());
        _notifications.Changed -= RefreshUnreadIndicators;
        _sidebarClock.Stop();
        foreach (var closed in _closedTerminals) closed.Terminal.Close();
        _closedTerminals.Clear();
        // Closing one window of several ends its workspaces; a quit, or the last window closing,
        // leaves hosted shells running for the next launch to reattach.
        var ending = !WindowRegistry.Quitting && WindowRegistry.Windows.Count > 0;
        foreach (var terminal in _terminals.Values)
        {
            if (ending) terminal.Close();
            else terminal.Dispose();
        }
        foreach (var panel in _panels.Values) panel.Dispose();
        _core.Dispose();
    }

    private sealed record SidebarRow(ListViewItem Item, ContentControl Icon, TextBlock Title, InfoBadge Unread, TextBlock Elapsed, Border Pill, FontIcon PillIcon, TextBlock PillLabel, TextBlock Message, TextBlock Branch, TextBlock Directory, HyperlinkButton PullRequest, HyperlinkButton Helpers, StackPanel Metadata);
    private sealed record PaneTag(string WorkspaceId, string PaneId);
    private sealed record SurfaceTag(string WorkspaceId, string PaneId, string SurfaceId);
    private sealed record TabDragPayload(string WorkspaceId, string PaneId, string SurfaceId);
}
