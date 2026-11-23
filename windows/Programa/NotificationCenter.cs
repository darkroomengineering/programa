using Microsoft.Windows.AppNotifications;
using Microsoft.Windows.AppNotifications.Builder;

namespace Programa;

/// <summary>One notification, as the macOS notifications panel lists it.</summary>
internal sealed record AppNotification(long Id, string WorkspaceId, string SurfaceId, string Title, string Body, DateTimeOffset CreatedAt)
{
    public bool IsRead { get; set; }
}

/// <summary>
/// The app's notifications: the list the bell panel shows, unread state for tabs, panes and
/// sidebar rows, and Windows toasts. Mirrors TerminalNotificationStore on macOS: a notification for
/// a terminal you are looking at is never posted, and looking at a terminal marks its notifications read.
/// </summary>
internal sealed class NotificationCenter
{
    private const int Capacity = 200;
    private readonly List<AppNotification> _items = [];
    private long _nextId = 1;
    private bool _toastsRegistered;

    /// <summary>Raised on the UI thread after any change.</summary>
    internal event Action? Changed;

    /// <summary>Raised on a background thread with the surface id when a toast is clicked.</summary>
    internal event Action<string>? ToastClicked;

    /// <summary>Newest first.</summary>
    internal IReadOnlyList<AppNotification> Items => _items.AsEnumerable().Reverse().ToList();

    internal bool HasUnread => _items.Any(item => !item.IsRead);

    internal AppNotification? LatestUnread => _items.LastOrDefault(item => !item.IsRead);

    /// <summary>The workspace's newest notification, read or not (the sidebar row's status line).</summary>
    internal AppNotification? Latest(string workspaceId) => _items.LastOrDefault(item => item.WorkspaceId == workspaceId);

    internal int UnreadCount(string workspaceId) => _items.Count(item => !item.IsRead && item.WorkspaceId == workspaceId);

    internal bool HasUnreadFor(string surfaceId) => _items.Any(item => !item.IsRead && item.SurfaceId == surfaceId);

    internal DateTimeOffset? LastPostedAt(string surfaceId) => _items.LastOrDefault(item => item.SurfaceId == surfaceId)?.CreatedAt;

    internal AppNotification Post(string workspaceId, string surfaceId, string title, string body, bool toast)
    {
        var notification = new AppNotification(_nextId++, workspaceId, surfaceId, title, body, DateTimeOffset.Now);
        _items.Add(notification);
        if (_items.Count > Capacity) _items.RemoveAt(0);
        if (toast) ShowToast(notification);
        Changed?.Invoke();
        return notification;
    }

    /// <summary>Marks every notification of these surfaces read; true when anything changed.</summary>
    internal bool MarkRead(IReadOnlySet<string> surfaceIds)
    {
        var changed = false;
        foreach (var item in _items.Where(item => !item.IsRead && surfaceIds.Contains(item.SurfaceId)))
        {
            item.IsRead = true;
            changed = true;
        }
        if (changed) Changed?.Invoke();
        return changed;
    }

    internal bool HasReadIn(string workspaceId) => _items.Any(item => item.IsRead && item.WorkspaceId == workspaceId);

    internal bool HasAnyIn(string workspaceId) => _items.Any(item => item.WorkspaceId == workspaceId);

    internal void MarkAllRead()
    {
        var unread = _items.Where(item => !item.IsRead).ToList();
        unread.ForEach(item => item.IsRead = true);
        if (unread.Count > 0) Changed?.Invoke();
    }

    /// <summary>Marks one notification read or unread. One marked unread moves to the top of the
    /// list, as on macOS, so it is easy to find again.</summary>
    internal void SetRead(long id, bool read)
    {
        if (_items.FirstOrDefault(item => item.Id == id) is not { } item || item.IsRead == read) return;
        item.IsRead = read;
        if (!read) BumpToNewest([item]);
        Changed?.Invoke();
    }

    /// <summary>Marks a workspace's read notifications unread and moves them to the top (macOS markUnread(forTabId:)).</summary>
    internal void MarkUnread(string workspaceId)
    {
        var read = _items.Where(item => item.IsRead && item.WorkspaceId == workspaceId).ToList();
        if (read.Count == 0) return;
        read.ForEach(item => item.IsRead = false);
        BumpToNewest(read);
        Changed?.Invoke();
    }

    private void BumpToNewest(List<AppNotification> changed)
    {
        var ids = changed.Select(item => item.Id).ToHashSet();
        _items.RemoveAll(item => ids.Contains(item.Id));
        _items.AddRange(changed);
    }

    internal void Remove(long id)
    {
        if (_items.RemoveAll(item => item.Id == id) > 0) Changed?.Invoke();
    }

    /// <summary>Removes a workspace's newest notification (Clear Latest Notification).</summary>
    internal void ClearLatest(string workspaceId)
    {
        if (_items.LastOrDefault(item => item.WorkspaceId == workspaceId) is { } latest) Remove(latest.Id);
    }

    /// <summary>Removes one workspace's notifications (notification.clear with a workspace).</summary>
    internal void Clear(string workspaceId)
    {
        if (_items.RemoveAll(item => item.WorkspaceId == workspaceId) > 0) Changed?.Invoke();
    }

    internal void Clear()
    {
        _items.Clear();
        Changed?.Invoke();
        if (_toastsRegistered) _ = AppNotificationManager.Default.RemoveAllAsync();
    }

    /// <summary>Whether Windows shows this app's toasts (Settings > System > Notifications).</summary>
    internal static bool DesktopNotificationsEnabled
    {
        get
        {
            try { return AppNotificationManager.Default.Setting == AppNotificationSetting.Enabled; }
            catch (Exception error) when (error is System.Runtime.InteropServices.COMException or InvalidOperationException) { return false; }
        }
    }

    /// <summary>Registers for toasts once; an unpackaged app that cannot register keeps working without them.</summary>
    internal void RegisterToasts()
    {
        try
        {
            AppNotificationManager.Default.NotificationInvoked += (_, args) =>
            {
                if (args.Arguments.TryGetValue("surface", out var surfaceId)) ToastClicked?.Invoke(surfaceId);
                else if (args.Arguments.TryGetValue("destination", out var destination) && destination == "storage") StorageRequested?.Invoke();
            };
            AppNotificationManager.Default.Register();
            _toastsRegistered = true;
        }
        catch (Exception error)
        {
            LaunchLog.Write($"notifications: Windows toasts unavailable: {error.Message}");
        }
    }

    /// <summary>An app-level toast, tied to no terminal (route failures, routes that did not load, a
    /// route notification whose workspace closed).</summary>
    internal void ShowAppToast(string title, string body)
    {
        if (!_toastsRegistered) return;
        try
        {
            var builder = new AppNotificationBuilder().AddText(title);
            if (body.Length > 0) builder.AddText(body);
            if (AppSettings.Load().Silent) builder.MuteAudio();
            AppNotificationManager.Default.Show(builder.BuildNotification());
        }
        catch (Exception error)
        {
            LaunchLog.Write($"notifications: app toast failed: {error.Message}");
        }
    }

    /// <summary>A low-disk toast was clicked: open Storage.</summary>
    internal event Action? StorageRequested;

    /// <summary>The app's low-disk warning (macOS storage.warning.*), a toast that opens Storage.</summary>
    internal void ShowLowDiskWarning(long availableBytes, long? reclaimableBytes)
    {
        if (!_toastsRegistered) return;
        var body = string.Format(Localizer.Get("StorageWarningFree"), Storage.Bytes(availableBytes));
        if (reclaimableBytes is > 0) body += " " + string.Format(Localizer.Get("StorageWarningReclaimable"), Storage.Bytes(reclaimableBytes.Value));
        try
        {
            var builder = new AppNotificationBuilder().AddArgument("destination", "storage").AddText(Localizer.Get("StorageWarningTitle")).AddText(body);
            if (AppSettings.Load().Silent) builder.MuteAudio();
            AppNotificationManager.Default.Show(builder.BuildNotification());
        }
        catch (Exception error)
        {
            LaunchLog.Write($"notifications: low-disk toast failed: {error.Message}");
        }
    }

    private void ShowToast(AppNotification notification)
    {
        if (!_toastsRegistered) return;
        try
        {
            var builder = new AppNotificationBuilder().AddArgument("surface", notification.SurfaceId).AddText(notification.Title);
            if (notification.Body.Length > 0) builder.AddText(notification.Body);
            if (AppSettings.Load().Silent) builder.MuteAudio();
            AppNotificationManager.Default.Show(builder.BuildNotification());
        }
        catch (Exception error)
        {
            LaunchLog.Write($"notifications: toast failed: {error.Message}");
        }
    }
}
