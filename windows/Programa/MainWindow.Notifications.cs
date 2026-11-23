using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace Programa;

/// <summary>Notifications, as on macOS (docs/notifications.md, docs/program-status.md): a toast and an
/// unread mark (bell, tab dot, pane ring, sidebar count) for a terminal you are not looking at, the
/// notifications panel, and jump to the latest unread.</summary>
public sealed partial class MainWindow
{
    /// <summary>The app's notifications, shared by every window; toasts are registered once, by the registry.</summary>
    private static NotificationCenter _notifications => WindowRegistry.Notifications;
    private readonly Dictionary<string, string?> _lastStatusState = new(StringComparer.Ordinal);
    /// <summary>Each pane's unread ring, drawn over its terminal so toggling it never resizes the grid.</summary>
    private readonly Dictionary<string, (Border Host, Border Ring)> _paneRings = new(StringComparer.Ordinal);
    private bool _windowActive = true;
    private AppBarButton? _bell;

    private void InitializeNotifications()
    {
        _notifications.Changed += RefreshUnreadIndicators;
        Activated += (_, args) =>
        {
            _windowActive = args.WindowActivationState != WindowActivationState.Deactivated;
            if (_windowActive) MarkVisibleRead();
        };
    }

    /// <summary>The selected tab of every pane in the selected workspace.</summary>
    private HashSet<string> VisibleSurfaceIds() =>
        SelectedWorkspace()?.Panes.Select(pane => pane.SelectedSurfaceId).ToHashSet(StringComparer.Ordinal) ?? [];

    private bool IsLookingAt(string surfaceId) => _windowActive && VisibleSurfaceIds().Contains(surfaceId);

    private WorkspaceSnapshot? WorkspaceOf(string surfaceId) =>
        _snapshot.Workspaces.FirstOrDefault(workspace => workspace.Panes.Any(pane => pane.Surfaces.Any(surface => surface.Id == surfaceId)));

    private void MarkVisibleRead()
    {
        if (_windowActive) _notifications.MarkRead(VisibleSurfaceIds());
    }

    /// <summary>A program's own OSC 777/9 notification.</summary>
    private void OnTerminalNotification(string surfaceId, string title, string body)
    {
        if (WorkspaceOf(surfaceId) is not { } workspace || IsLookingAt(surfaceId)) return;
        var heading = title.Length > 0 ? title : _terminals.TryGetValue(surfaceId, out var terminal) ? TabTitle(terminal) : Localizer.Get("Terminal");
        _notifications.Post(workspace.Id, surfaceId, heading, body, toast: true);
    }

    /// <summary>The root status entering blocked, done or error posts one notification, at most one per
    /// 10 seconds per terminal. It waits a moment so an agent that also sends its own notification
    /// (Claude Code's OSC 777) is announced once, in its own words.</summary>
    private void NotifyOnStatusChange(string surfaceId, TerminalView terminal)
    {
        var state = terminal.EffectiveStatus?.State;
        var previous = _lastStatusState.GetValueOrDefault(surfaceId);
        _lastStatusState[surfaceId] = state;
        if (state == previous || state is not ("blocked" or "done" or "error") || terminal.EffectiveStatus is not { } record) return;
        var changedAt = DateTimeOffset.Now;
        var timer = DispatcherQueue.CreateTimer();
        timer.Interval = TimeSpan.FromSeconds(1.5);
        timer.IsRepeating = false;
        timer.Tick += (_, _) =>
        {
            timer.Stop();
            if (_notifications.LastPostedAt(surfaceId) is { } last && last > changedAt.AddSeconds(-10)) return;
            if (terminal.EffectiveStatus?.State != state || IsLookingAt(surfaceId) || WorkspaceOf(surfaceId) is not { } workspace) return;
            _notifications.Post(workspace.Id, surfaceId, TabTitle(terminal), StatusNotificationBody(record), toast: true);
        };
        timer.Start();
    }

    private static string StatusNotificationBody(ProgramStatusRecord record) => (record.State, record.Kind) switch
    {
        ("blocked", "permission") => Localizer.Get("NotifyNeedsPermission"),
        ("blocked", "question") => Localizer.Get("NotifyHasQuestion"),
        ("blocked", "auth") => Localizer.Get("NotifyNeedsSignIn"),
        ("blocked", _) => Localizer.Get("NotifyNeedsInput"),
        ("done", _) => Localizer.Get("NotifyFinished"),
        _ => Localizer.Get("NotifyFailed"),
    };

    /// <summary>Goes to a surface, in whichever window holds it.</summary>
    private void JumpToSurface(string surfaceId)
    {
        if (OwnsSurface(surfaceId)) JumpHere(surfaceId);
        else WindowRegistry.JumpTo(surfaceId);
    }

    private void JumpToLatestUnread()
    {
        if (_notifications.LatestUnread is { } latest) JumpToSurface(latest.SurfaceId);
    }

    /// <summary>Repaints every unread mark from the store.</summary>
    private void RefreshUnreadIndicators()
    {
        if (_bell is not null)
        {
            if (_notifications.HasUnread) _bell.Foreground = ThemeBrush("AccentTextFillColorPrimaryBrush");
            else _bell.ClearValue(Control.ForegroundProperty);
        }
        foreach (var (surfaceId, item) in _tabItems)
            if (_terminals.TryGetValue(surfaceId, out var terminal)) item.Header = TabHeader(terminal);
        foreach (var (host, ring) in _paneRings.Values)
            ring.Visibility = host.Child is TerminalView shown && HasUnread(shown.SurfaceId) ? Visibility.Visible : Visibility.Collapsed;
        foreach (var workspaceId in _sidebarRows.Keys.ToList()) UpdateSidebarRow(workspaceId);
    }

    /// <summary>Tabs marked unread by tab.action mark_unread, until you pick them or mark them read.</summary>
    private readonly HashSet<string> _manualUnread = new(StringComparer.Ordinal);

    private bool HasUnread(string surfaceId) => _notifications.HasUnreadFor(surfaceId) || _manualUnread.Contains(surfaceId);

    private object TabHeader(TerminalView terminal) => TabHeader(TabTitle(terminal), IsPinnedSurface(terminal.SurfaceId), HasUnread(terminal.SurfaceId));

    /// <summary>The tab's title, with a dot while it is unread and, when it is pinned, a pin where
    /// the close button would be (macOS).</summary>
    private static object TabHeader(string title, bool pinned, bool unread)
    {
        if (!pinned && !unread) return title;
        var header = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
        header.Children.Add(new TextBlock { Text = title });
        if (unread) header.Children.Add(new InfoBadge { Width = 8, Height = 8, VerticalAlignment = VerticalAlignment.Center });
        if (pinned) header.Children.Add(new FontIcon { Glyph = char.ConvertFromUtf32(0xE718), FontSize = 11, Margin = new Thickness(4, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center });
        return header;
    }

    private bool IsPinnedSurface(string surfaceId) =>
        _snapshot.Workspaces.SelectMany(workspace => workspace.Panes).SelectMany(pane => pane.Surfaces).Any(surface => surface.Id == surfaceId && surface.IsPinned);

    /// <summary>The ring drawn over a pane while its shown tab has unread notifications.</summary>
    private Border PaneRing(string paneId, Border host)
    {
        var ring = new Border
        {
            BorderThickness = new Thickness(2),
            BorderBrush = ThemeBrush("AccentFillColorDefaultBrush"),
            CornerRadius = new CornerRadius(4),
            IsHitTestVisible = false,
            Visibility = Visibility.Collapsed,
        };
        _paneRings[paneId] = (host, ring);
        return ring;
    }

    /// <summary>The panel, as on macOS: Mark All Read and Clear All, and per entry an unread dot, a
    /// clear button and Mark as Read or Unread on right-click. It redraws while open.</summary>
    private void ShowNotificationsPanel()
    {
        if (_bell is null) return;
        var flyout = new Flyout();
        var panel = new StackPanel { Width = 380, Spacing = 8 };
        void Fill()
        {
            panel.Children.Clear();
            var header = new Grid();
            header.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            header.Children.Add(new TextBlock { Text = Localizer.Get("Notifications"), Style = (Style)Application.Current.Resources["SubtitleTextBlockStyle"] });
            var items = _notifications.Items;
            if (items.Count > 0)
            {
                var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4 };
                var markAll = new Button { Content = Localizer.Get("MarkAllRead"), IsEnabled = _notifications.HasUnread };
                markAll.Click += (_, _) => _notifications.MarkAllRead();
                var clear = new Button { Content = Localizer.Get("ClearAll") };
                clear.Click += (_, _) => { _notifications.Clear(); flyout.Hide(); };
                actions.Children.Add(markAll);
                actions.Children.Add(clear);
                header.Children.Add(actions);
                Grid.SetColumn(actions, 1);
            }
            panel.Children.Add(header);

            if (items.Count == 0)
            {
                panel.Children.Add(new TextBlock { Text = Localizer.Get("NoNotificationsTitle"), Style = (Style)Application.Current.Resources["BodyStrongTextBlockStyle"] });
                panel.Children.Add(new TextBlock { Text = Localizer.Get("NoNotificationsSubtitle"), Opacity = 0.7, TextWrapping = TextWrapping.Wrap });
            }
            else
            {
                var list = new ListView { SelectionMode = ListViewSelectionMode.None, IsItemClickEnabled = true, MaxHeight = 440 };
                foreach (var notification in items) list.Items.Add(NotificationRow(notification));
                list.ItemClick += (_, args) =>
                {
                    // The clicked item is the ListViewItem or its content; both carry the surface id.
                    if (args.ClickedItem is FrameworkElement { Tag: string surfaceId })
                    {
                        flyout.Hide();
                        JumpToSurface(surfaceId);
                    }
                };
                panel.Children.Add(list);
                if (_notifications.HasUnread)
                {
                    var jump = new Button { Content = $"{Localizer.Get("JumpToLatestUnread")} ({ShortcutSettings.Display(_shortcuts.Values["jump_to_unread"])})", HorizontalAlignment = HorizontalAlignment.Stretch };
                    jump.Click += (_, _) => { flyout.Hide(); JumpToLatestUnread(); };
                    panel.Children.Add(jump);
                }
            }
            // The macOS menu bar's "N agents blocked".
            if (BlockedAgentsLabel() is { } blocked)
            {
                var jump = new Button { Content = blocked, HorizontalAlignment = HorizontalAlignment.Stretch };
                ToolTipService.SetToolTip(jump, Localizer.Get("BlockedAgentsTooltip"));
                jump.Click += (_, _) => { flyout.Hide(); JumpToFirstBlockedAgent(); };
                panel.Children.Add(jump);
            }
        }
        Fill();
        _notifications.Changed += Fill;
        flyout.Closed += (_, _) => _notifications.Changed -= Fill;
        flyout.Content = panel;
        flyout.ShowAt(_bell);
    }

    private ListViewItem NotificationRow(AppNotification notification)
    {
        var workspaceName = _snapshot.Workspaces.Any(item => item.Id == notification.WorkspaceId) ? _sidebarRows.GetValueOrDefault(notification.WorkspaceId)?.Title.Text : null;
        var elapsed = AgentIndicator.Elapsed(DateTimeOffset.Now - notification.CreatedAt) is var (key, value)
            ? string.Format(Localizer.Get(key), value)
            : Localizer.Get("ElapsedNow");
        var row = new Grid { ColumnSpacing = 10, Padding = new Thickness(0, 6, 0, 6), Tag = notification.SurfaceId };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var accent = ThemeBrush("AccentFillColorDefaultBrush");
        // Filled while unread, a faint ring once read, as on macOS.
        row.Children.Add(new Microsoft.UI.Xaml.Shapes.Ellipse
        {
            Width = 8, Height = 8, Margin = new Thickness(0, 6, 0, 0), VerticalAlignment = VerticalAlignment.Top, StrokeThickness = 1, Stroke = accent,
            Fill = notification.IsRead ? null : accent, Opacity = notification.IsRead ? 0.2 : 1,
        });
        var entry = new StackPanel { Spacing = 2, Opacity = notification.IsRead ? 0.7 : 1 };
        entry.Children.Add(new TextBlock { Text = notification.Title, FontWeight = notification.IsRead ? Microsoft.UI.Text.FontWeights.Normal : Microsoft.UI.Text.FontWeights.SemiBold, TextTrimming = TextTrimming.CharacterEllipsis });
        if (notification.Body.Length > 0)
            entry.Children.Add(new TextBlock { Text = notification.Body, TextWrapping = TextWrapping.Wrap, MaxLines = 3, TextTrimming = TextTrimming.CharacterEllipsis });
        entry.Children.Add(new TextBlock { Text = workspaceName is null ? elapsed : $"{workspaceName} · {elapsed}", FontSize = 12, Opacity = 0.6 });
        row.Children.Add(entry);
        Grid.SetColumn(entry, 1);
        var clear = new Button { Content = new FontIcon { Glyph = char.ConvertFromUtf32(0xE711), FontSize = 10 }, Padding = new Thickness(6), VerticalAlignment = VerticalAlignment.Top, Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent), BorderThickness = new Thickness(0) };
        AutomationProperties.SetName(clear, Localizer.Get("ClearNotification"));
        ToolTipService.SetToolTip(clear, Localizer.Get("ClearNotification"));
        clear.Click += (_, _) => _notifications.Remove(notification.Id);
        row.Children.Add(clear);
        Grid.SetColumn(clear, 2);
        var item = new ListViewItem { Content = row, Tag = notification.SurfaceId };
        var menu = new MenuFlyout();
        menu.Items.Add(MenuItem(Localizer.Get(notification.IsRead ? "MarkAsUnread" : "MarkAsRead"), () => _notifications.SetRead(notification.Id, !notification.IsRead)));
        item.ContextFlyout = menu;
        var state = Localizer.Get(notification.IsRead ? "NotificationRead" : "NotificationUnread");
        AutomationProperties.SetName(item, $"{notification.Title}, {notification.Body}, {state}");
        return item;
    }

    /// <summary>Mark Tab as Read or Unread, from the tab menu (the same as tab.action mark_read and mark_unread).</summary>
    private MenuFlyoutItem TabReadMenuItem(string surfaceId)
    {
        var unread = HasUnread(surfaceId);
        return MenuItem(Localizer.Get(unread ? "MarkTabRead" : "MarkTabUnread"), () =>
        {
            if (unread)
            {
                _manualUnread.Remove(surfaceId);
                _notifications.MarkRead(new HashSet<string>(StringComparer.Ordinal) { surfaceId });
            }
            else _manualUnread.Add(surfaceId);
            RefreshUnreadIndicators();
        });
    }

    /// <summary>The workspace menu's Mark Workspace as Read and Unread and Clear Latest Notification, enabled as on macOS.</summary>
    private IEnumerable<MenuFlyoutItemBase> WorkspaceNotificationMenuItems(string workspaceId)
    {
        yield return new MenuFlyoutSeparator();
        var read = MenuItem(Localizer.Get("MarkWorkspaceRead"), () => TryWorkspaceAction(workspaceId, "mark_read"));
        read.IsEnabled = _notifications.UnreadCount(workspaceId) > 0;
        yield return read;
        var unread = MenuItem(Localizer.Get("MarkWorkspaceUnread"), () => TryWorkspaceAction(workspaceId, "mark_unread"));
        unread.IsEnabled = _notifications.HasReadIn(workspaceId);
        yield return unread;
        var clear = MenuItem(Localizer.Get("ClearLatestNotification"), () => _notifications.ClearLatest(workspaceId));
        clear.IsEnabled = _notifications.HasAnyIn(workspaceId);
        yield return clear;
    }

    /// <summary>Every terminal whose agent is waiting on you, in every window, in sidebar order.</summary>
    private static List<string> BlockedAgentSurfaces() =>
        WindowRegistry.Windows.SelectMany(window => window._snapshot.Workspaces.SelectMany(window.TerminalsOf))
            .Where(terminal => terminal.AgentState.State == "blocked").Select(terminal => terminal.SurfaceId).ToList();

    /// <summary>"N agents blocked", or null when none is.</summary>
    private static string? BlockedAgentsLabel() => BlockedAgentSurfaces().Count switch
    {
        0 => null,
        1 => Localizer.Get("BlockedAgentsOne"),
        var count => string.Format(Localizer.Get("BlockedAgentsOther"), count),
    };

    /// <summary>Goes to the first agent waiting on you (macOS jumpToFirstBlockedAgent).</summary>
    private void JumpToFirstBlockedAgent()
    {
        if (BlockedAgentSurfaces().FirstOrDefault() is { } surfaceId) JumpToSurface(surfaceId);
    }
}
