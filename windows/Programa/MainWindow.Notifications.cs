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

    /// <summary>The tab's title, after a pin when it is pinned, with a dot while it is unread.</summary>
    private object TabHeader(TerminalView terminal)
    {
        var title = TabTitle(terminal);
        var pinned = IsPinnedSurface(terminal.SurfaceId);
        var unread = HasUnread(terminal.SurfaceId);
        if (!pinned && !unread) return title;
        var header = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
        if (pinned) header.Children.Add(new FontIcon { Glyph = char.ConvertFromUtf32(0xE718), FontSize = 11, VerticalAlignment = VerticalAlignment.Center });
        header.Children.Add(new TextBlock { Text = title });
        if (unread) header.Children.Add(new InfoBadge { Width = 8, Height = 8, VerticalAlignment = VerticalAlignment.Center });
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

    private void ShowNotificationsPanel()
    {
        if (_bell is null) return;
        var flyout = new Flyout();
        var panel = new StackPanel { Width = 380, Spacing = 8 };
        var header = new Grid();
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        header.Children.Add(new TextBlock { Text = Localizer.Get("Notifications"), Style = (Style)Application.Current.Resources["SubtitleTextBlockStyle"] });
        var items = _notifications.Items;
        if (items.Count > 0)
        {
            var clear = new Button { Content = Localizer.Get("ClearAll") };
            clear.Click += (_, _) => { _notifications.Clear(); flyout.Hide(); };
            header.Children.Add(clear);
            Grid.SetColumn(clear, 1);
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
            foreach (var notification in items)
            {
                var workspaceIndex = _snapshot.Workspaces.ToList().FindIndex(item => item.Id == notification.WorkspaceId);
                var workspaceName = workspaceIndex < 0 ? null : _sidebarRows.GetValueOrDefault(notification.WorkspaceId)?.Title.Text;
                var elapsed = AgentIndicator.Elapsed(DateTimeOffset.Now - notification.CreatedAt) is var (key, value)
                    ? string.Format(Localizer.Get(key), value)
                    : Localizer.Get("ElapsedNow");
                var entry = new StackPanel { Padding = new Thickness(0, 6, 0, 6), Spacing = 2, Opacity = notification.IsRead ? 0.7 : 1, Tag = notification.SurfaceId };
                entry.Children.Add(new TextBlock { Text = notification.Title, FontWeight = notification.IsRead ? Microsoft.UI.Text.FontWeights.Normal : Microsoft.UI.Text.FontWeights.SemiBold, TextTrimming = TextTrimming.CharacterEllipsis });
                if (notification.Body.Length > 0)
                    entry.Children.Add(new TextBlock { Text = notification.Body, TextWrapping = TextWrapping.Wrap, MaxLines = 3, TextTrimming = TextTrimming.CharacterEllipsis });
                entry.Children.Add(new TextBlock { Text = workspaceName is null ? elapsed : $"{workspaceName} · {elapsed}", FontSize = 12, Opacity = 0.6 });
                var item = new ListViewItem { Content = entry, Tag = notification.SurfaceId };
                AutomationProperties.SetName(item, $"{notification.Title}, {notification.Body}");
                list.Items.Add(item);
            }
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
        flyout.Content = panel;
        flyout.ShowAt(_bell);
    }
}
