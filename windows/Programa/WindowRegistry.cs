using System.Text.Json;
using Microsoft.UI.Dispatching;

namespace Programa;

/// <summary>The app's windows, as on macOS: each window has its own workspaces, sidebar and core,
/// while the control pipe, notifications and the saved session are the app's. The pipe routes a
/// request to the window that owns its window, workspace, surface or pane id, else to the window
/// last focused. Everything here runs on the UI thread.</summary>
internal static class WindowRegistry
{
    private static readonly List<MainWindow> Open = [];
    /// <summary>Windows closed in the last few seconds: a shutdown or logoff closes every window in
    /// turn, and the session saved when the last one goes keeps them all.</summary>
    private static readonly List<(SavedSession Session, DateTimeOffset ClosedAt)> RecentlyClosed = [];
    private static readonly TimeSpan RecentlyClosedWindow = TimeSpan.FromSeconds(3);
    private static ControlServer? _control;
    private static DispatcherQueue? _dispatcher;
    private static DispatcherQueueTimer? _autosave;
    private static bool _quitting;

    /// <summary>Quit is closing every window: their terminals keep running in the host.</summary>
    internal static bool Quitting => _quitting;
    private static FileSystemWatcher? _settingsWatcher;
    private static DateTime _appliedSettingsWrite;

    internal static IReadOnlyList<MainWindow> Windows => Open;
    internal static MainWindow? Current { get; private set; }
    internal static NotificationCenter Notifications { get; } = new();

    /// <summary>Opens the saved windows (or one fresh window) at launch.</summary>
    internal static void Launch(bool smoke)
    {
        _dispatcher = DispatcherQueue.GetForCurrentThread();
        McpConfig.Write();
        // Before any terminal starts: they run in the host and reattach to what it kept running.
        // A smoke run leaves nothing behind.
        if (!smoke) TerminalHost.Start();
        Notifications.ToastClicked += surfaceId => _dispatcher.TryEnqueue(() => JumpTo(surfaceId));
        Notifications.RegisterToasts();
        // Before anything can overwrite it, the session goes into the history (snapshot.list); an
        // unreadable one falls back to the newest archive that restores, as on macOS.
        if (!smoke) SessionHistory.Rotate();
        var hadSession = File.Exists(SessionStore.DefaultPath);
        var saved = SessionStore.Load() ?? (hadSession && !smoke ? SessionHistory.NewestRestorable() : null);
        OpenWindow(smoke, saved);
        foreach (var other in saved?.OtherWindows ?? []) OpenWindow(false, other);
        TerminalHost.Retain(Open.SelectMany(window => window.SurfaceIds()));
        Current = Open.FirstOrDefault();
        _control = new ControlServer(HandleAsync);
        _control.Start();
        _autosave = _dispatcher.CreateTimer();
        _autosave.Interval = TimeSpan.FromSeconds(30);
        _autosave.Tick += (_, _) => SaveAll();
        _autosave.Start();
        WatchSettings();
        StartEvents();
        RouteEngine.Start(_dispatcher);
        Helpers.Changed += workspaceId => OwnerOfWorkspace(workspaceId)?.OnHelpersChanged(workspaceId);
        SidebarMetadata.Changed += workspaceId => OwnerOfWorkspace(workspaceId)?.OnSidebarMetadataChanged(workspaceId);
        // Merged worktrees go every 6 hours, starting two minutes after launch (macOS worktrees.autoRemoveMerged).
        Every(TimeSpan.FromMinutes(2), TimeSpan.FromHours(6), CleanUpMergedWorktrees);
        // Free space: 60 seconds after launch, then every 15 minutes (macOS StorageLowDiskMonitor).
        Notifications.StorageRequested += () => _dispatcher.TryEnqueue(() => (Current ?? Open.FirstOrDefault())?.ShowStorageFromNotification());
        var lowDisk = new LowDiskWarning();
        Every(TimeSpan.FromSeconds(60), TimeSpan.FromMinutes(15), () =>
        {
            if (Storage.Capacity() is { } capacity && lowDisk.Check(capacity.Available, AppSettings.Load().LowDiskWarningGB))
                Notifications.ShowLowDiskWarning(capacity.Available, MainWindow.CachedReclaimableBytes);
        });
    }

    /// <summary>Runs <paramref name="tick"/> after <paramref name="first"/>, then every <paramref name="then"/>. The
    /// timer restarts on the switch: a running timer keeps its old interval for the tick already counting,
    /// which ran the cleanup a second time two minutes after the first.</summary>
    private static void Every(TimeSpan first, TimeSpan then, Action tick)
    {
        var timer = _dispatcher!.CreateTimer();
        timer.Interval = first;
        timer.Tick += (_, _) =>
        {
            if (timer.Interval != then)
            {
                timer.Stop();
                timer.Interval = then;
                timer.Start();
            }
            tick();
        };
        timer.Start();
    }

    private static DispatcherQueueTimer? _outputPoll;
    private static readonly Dictionary<string, string> OutputSeen = new(StringComparer.Ordinal);
    private static Dictionary<string, (string? Name, string Shown)>? _knownWorkspaces;
    private static bool _workspaceCheckQueued;

    /// <summary>The event producers that span windows: output frames on a shared 100 ms poll of the
    /// watched surfaces (running only while one is watched), and workspace lifecycle frames.</summary>
    private static void StartEvents()
    {
        _outputPoll = _dispatcher!.CreateTimer();
        _outputPoll.Interval = TimeSpan.FromMilliseconds(100);
        _outputPoll.Tick += (_, _) => PollOutput();
        EventHub.SubscriptionsChanged += () => _dispatcher.TryEnqueue(() =>
        {
            if (EventHub.OutputSurfaces().Count > 0) _outputPoll.Start();
            else
            {
                _outputPoll.Stop();
                OutputSeen.Clear();
            }
        });
        NoteWorkspaces();
    }

    private static void PollOutput()
    {
        var watched = EventHub.OutputSurfaces();
        foreach (var gone in OutputSeen.Keys.Where(id => !watched.Contains(id)).ToList()) OutputSeen.Remove(gone);
        foreach (var id in watched)
        {
            if (Open.Select(window => window.TerminalById(id)).FirstOrDefault(terminal => terminal is not null) is not { } terminal) continue;
            var text = terminal.OutputText(200).TrimEnd();
            // The first read is the baseline: only what comes after the subscription is sent.
            var seen = OutputSeen.TryGetValue(id, out var previous);
            OutputSeen[id] = text;
            if (!seen) continue;
            var tail = EventHub.OutputTail(previous!, text);
            if (tail.Length == 0) continue;
            if (tail.Length > 4000) tail = tail[^4000..];
            EventHub.Publish("output", id, new { @event = "output", workspace_id = terminal.WorkspaceId, surface_id = id, text = tail, ts = EventHub.Now });
        }
    }

    /// <summary>Called after a window projects or closes: once the UI settles, compares every window's
    /// workspaces with the last look and sends created, closed and renamed frames. Deferred, so a
    /// workspace moving between windows (gone from one, then in the other) is neither.</summary>
    internal static void NoteWorkspaces()
    {
        if (_workspaceCheckQueued || _dispatcher is null) return;
        _workspaceCheckQueued = true;
        _dispatcher.TryEnqueue(DispatcherQueuePriority.Low, () =>
        {
            _workspaceCheckQueued = false;
            var now = Open.SelectMany(window => window.WorkspaceNames()).ToDictionary(item => item.Id, item => (item.Name, item.Shown), StringComparer.Ordinal);
            var before = _knownWorkspaces;
            _knownWorkspaces = now;
            Helpers.Retain(now.Keys);
            SidebarMetadata.Retain(now.Keys);
            if (before is null || (!EventHub.Wants("workspace_lifecycle") && !RouteEngine.HasRoutes)) return;
            // Only an explicit rename changes the given name; a shell's title (every cd) does not.
            foreach (var (id, names) in now)
            {
                if (!before.TryGetValue(id, out var old)) WorkspaceChanged("created", id, names.Shown);
                else if (old.Name != names.Name) WorkspaceChanged("renamed", id, names.Shown);
            }
            foreach (var (id, old) in before.Where(item => !now.ContainsKey(item.Key))) WorkspaceChanged("closed", id, old.Shown);
        });
    }

    /// <summary>A workspace lifecycle frame for subscribers and a workspace/&lt;id&gt;/&lt;kind&gt; event for routes.</summary>
    private static void WorkspaceChanged(string kind, string id, string? title)
    {
        var ts = EventHub.Now;
        EventHub.Publish("workspace_lifecycle", null, kind == "closed"
            ? new { @event = "workspace_lifecycle", kind, workspace_id = id, ts }
            : (object)new { @event = "workspace_lifecycle", kind, workspace_id = id, title, ts });
        var fields = new Dictionary<string, string>(StringComparer.Ordinal)
        {
            ["topic"] = $"workspace/{id}/{kind}", ["workspace_id"] = id, ["kind"] = kind, ["ts"] = ts.ToString(System.Globalization.CultureInfo.InvariantCulture),
        };
        if (!string.IsNullOrEmpty(title)) fields["title"] = title;
        // Programa itself reports these, so routes trust them.
        RouteEngine.Fire(new RouteEvent(fields["topic"], fields, id, null, Trusted: true));
    }

    /// <summary>The six-hourly pass: merged worktrees (worktrees.autoRemoveMerged) and idle package
    /// caches (storage.autoCleanCaches), each independently, as on macOS.</summary>
    private static void CleanUpMergedWorktrees()
    {
        var settings = WorktreeSettings.Load();
        var cleanCaches = AppSettings.Load().AutoCleanCaches;
        var open = OpenDirectories();
        _ = Task.Run(() =>
        {
            if (settings.AutoRemoveMerged)
                foreach (var removed in WorktreeCleanup.Run(settings.Directory, open, TimeSpan.FromHours(settings.AutoRemoveAfterHours)))
                    LaunchLog.Write($"worktrees: removed merged worktree {removed}");
            if (cleanCaches)
            {
                var projects = Storage.ScanWorktrees(open, settings, sizes: false).SelectMany(worktree => new[] { worktree.Path, worktree.RepoRoot }).ToList();
                foreach (var cache in Storage.AutoCleanCaches(projects))
                    LaunchLog.Write($"storage: cleaned {cache.Id} ({cache.Path})");
            }
        });
    }

    private static List<string> OpenDirectories() => Open.SelectMany(window => window.OpenDirectories()).ToList();

    /// <summary>storage.scan and storage.clean: the open directories are read here on the UI thread;
    /// git, the size walks and the tools run on a worker thread.</summary>
    private static Task<object?> StorageFromControl(string method, JsonElement p)
    {
        var open = OpenDirectories();
        var settings = WorktreeSettings.Load();
        if (method == "storage.scan") return Task.Run<object?>(() => Storage.ScanJson(Storage.ScanWorktrees(open, settings), ScanCachesNear(open, settings)));
        var categories = Strings(p, "categories");
        if (categories?.FirstOrDefault(category => category is not ("xcode" or "android" or "packages")) is { } unknown)
            throw new ControlException("invalid_params", $"Unknown cache category '{unknown}'; expected xcode, android or packages.");
        var paths = Strings(p, "paths");
        if (paths?.FirstOrDefault(path => !Path.IsPathRooted(path)) is { } relative)
            throw new ControlException("invalid_params", $"paths must be absolute: '{relative}'.");
        var options = new Storage.CleanOptions(Flag(p, "dry_run") ?? true, Flag(p, "include_external") ?? false, Flag(p, "ignore_grace_period") ?? false, categories, Strings(p, "items"), paths);
        return Task.Run<object?>(() =>
        {
            var result = Storage.Clean(options, open, settings);
            if (!options.DryRun) MainWindow.InvalidateStorage();
            return Storage.CleanJson(result);
        });
    }

    private static List<Storage.Cache> ScanCachesNear(List<string> open, WorktreeSettings settings) =>
        Storage.ScanCaches(Storage.ScanWorktrees(open, settings, sizes: false).SelectMany(worktree => new[] { worktree.Path, worktree.RepoRoot }).ToList());

    private static bool? Flag(JsonElement p, string name) =>
        p.ValueKind == JsonValueKind.Object && p.TryGetProperty(name, out var value) && value.ValueKind is JsonValueKind.True or JsonValueKind.False ? value.GetBoolean() : null;

    private static List<string>? Strings(JsonElement p, string name) =>
        p.ValueKind == JsonValueKind.Object && p.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.Array
            ? value.EnumerateArray().Where(item => item.ValueKind == JsonValueKind.String).Select(item => item.GetString()!).ToList()
            : null;

    /// <summary>A new window: restored from the session, holding a workspace moved from another
    /// window, or with one fresh workspace. New windows open a little below and right of the current one.</summary>
    internal static MainWindow OpenWindow(bool smoke = false, SavedSession? restore = null, WorkspaceTransfer? adopt = null)
    {
        var anchor = Current;
        var window = new MainWindow(smoke, restore, adopt);
        Open.Add(window);
        if (restore?.Window is null && anchor is not null) window.CascadeFrom(anchor);
        window.Activate();
        Current = window;
        return window;
    }

    internal static void Activated(MainWindow window) => Current = window;

    /// <summary>Applies settings.json to every window (Settings saved, or the file edited elsewhere).</summary>
    internal static void ApplySettings()
    {
        _appliedSettingsWrite = SettingsWriteTime();
        TerminalAppearance.Reload();
        foreach (var window in Open) window.ApplySettings();
    }

    private static DateTime SettingsWriteTime() =>
        File.Exists(ShortcutSettings.SettingsPath) ? File.GetLastWriteTimeUtc(ShortcutSettings.SettingsPath) : default;

    /// <summary>Applies settings.json when it changes on disk, as macOS does: an editor's save, the
    /// macOS app through a synced folder, or Settings (whose own write is already applied).</summary>
    private static void WatchSettings()
    {
        var folder = Path.GetDirectoryName(ShortcutSettings.SettingsPath)!;
        try
        {
            Directory.CreateDirectory(folder);
            var reload = _dispatcher!.CreateTimer();
            reload.Interval = TimeSpan.FromMilliseconds(300);
            reload.IsRepeating = false;
            reload.Tick += (_, _) =>
            {
                if (SettingsWriteTime() != _appliedSettingsWrite) ApplySettings();
                // Event routes live in programa.json beside it; RouteEngine installs only a real change.
                RouteEngine.Reload();
            };
            void Changed(string? name)
            {
                if (name is not null && !name.Equals(Path.GetFileName(ShortcutSettings.SettingsPath), StringComparison.OrdinalIgnoreCase)
                    && !name.Equals("programa.json", StringComparison.OrdinalIgnoreCase)) return;
                _dispatcher.TryEnqueue(() => { reload.Stop(); reload.Start(); });
            }
            _settingsWatcher = new FileSystemWatcher(folder, "*.json")
            {
                NotifyFilter = NotifyFilters.LastWrite | NotifyFilters.FileName | NotifyFilters.Size,
            };
            _settingsWatcher.Changed += (_, args) => Changed(args.Name);
            _settingsWatcher.Created += (_, args) => Changed(args.Name);
            _settingsWatcher.Deleted += (_, args) => Changed(args.Name);
            _settingsWatcher.Renamed += (_, args) => Changed(args.Name);
            _settingsWatcher.EnableRaisingEvents = true;
            _appliedSettingsWrite = SettingsWriteTime();
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or ArgumentException)
        {
            LaunchLog.Write($"settings: not watching {folder}: {error.Message}");
        }
    }

    /// <summary>Called as a window closes, with what it would save (null for an empty window).</summary>
    internal static void Closed(MainWindow window, SavedSession? state)
    {
        Open.Remove(window);
        NoteWorkspaces();
        if (Current == window) Current = Open.LastOrDefault();
        if (_quitting) return;
        if (state is not null) RecentlyClosed.Add((state, DateTimeOffset.Now));
        if (Open.Count > 0)
        {
            SaveAll();
            return;
        }
        // The last window: keep the windows that closed with it (a shutdown), then stop.
        SaveAll(includeRecentlyClosed: true, clean: true);
        _autosave?.Stop();
        _control?.Dispose();
        _settingsWatcher?.Dispose();
    }

    /// <summary>Writes every open window to the session file: the first at its root, the others under
    /// other_windows. No window with a workspace deletes it, so the next launch starts fresh.</summary>
    internal static void SaveAll(bool includeRecentlyClosed = false, bool clean = false)
    {
        var now = DateTimeOffset.Now;
        RecentlyClosed.RemoveAll(item => now - item.ClosedAt > RecentlyClosedWindow);
        var sessions = Open.Select(window => window.CaptureSession()).OfType<SavedSession>().ToList();
        if (includeRecentlyClosed) sessions.InsertRange(0, RecentlyClosed.Select(item => item.Session));
        if (sessions.Count == 0)
        {
            SessionStore.Delete();
            return;
        }
        // A quit marks the session clean (snapshot.list clean_shutdown); every other save, unclean.
        SessionStore.Save(sessions[0] with
        {
            OtherWindows = sessions.Count > 1 ? sessions.Skip(1).Select(item => item with { OtherWindows = null, CleanShutdown = null, SavedAt = null }).ToList() : null,
            CleanShutdown = clean,
            SavedAt = DateTimeOffset.UtcNow,
        });
    }

    /// <summary>Quit: saves every window, then closes them all without asking again. The caller has
    /// already asked about running programs.</summary>
    internal static void Quit()
    {
        SaveAll(clean: true);
        _quitting = true;
        _autosave?.Stop();
        foreach (var window in Open.ToList()) window.CloseWithoutAsking();
        _control?.Dispose();
        _settingsWatcher?.Dispose();
    }

    internal static MainWindow? OwnerOfWorkspace(string id) => Open.FirstOrDefault(window => window.OwnsWorkspace(id));

    internal static MainWindow? OwnerOfSurface(string id) => Open.FirstOrDefault(window => window.OwnsSurface(id));

    internal static MainWindow? WindowById(string id) => Open.FirstOrDefault(window => window.WindowId == id);

    /// <summary>Shows a surface wherever it is, bringing its window forward (a toast or a
    /// notification in another window's panel).</summary>
    internal static void JumpTo(string surfaceId)
    {
        if (OwnerOfSurface(surfaceId) is not { } window) return;
        window.Activate();
        window.JumpHere(surfaceId);
    }

    /// <summary>Moves a workspace, its terminals still running, to another window, or to a new one
    /// when <paramref name="target"/> is null. A window left without workspaces closes.</summary>
    internal static MainWindow MoveWorkspace(string workspaceId, MainWindow? target)
    {
        var source = OwnerOfWorkspace(workspaceId) ?? throw new ControlException("not_found", $"workspace '{workspaceId}' was not found.");
        if (source == target) return source;
        var transfer = source.TakeWorkspace(workspaceId);
        return Deliver(source, transfer, target);
    }

    /// <summary>Moves one tab into a workspace of its own in a new window, opened with its top-left
    /// near <paramref name="at"/> (a tab dropped outside every window) or cascaded.</summary>
    internal static MainWindow MoveSurfaceToNewWindow(string workspaceId, string paneId, string surfaceId, Windows.Graphics.PointInt32? at = null)
    {
        var source = OwnerOfWorkspace(workspaceId) ?? throw new ControlException("not_found", $"workspace '{workspaceId}' was not found.");
        var window = Deliver(source, source.TakeSurface(workspaceId, paneId, surfaceId), null);
        if (at is { } point) window.PlaceUnder(point);
        return window;
    }

    /// <summary>Moves a tab into a pane of another window (a tab dropped on that window's tab strip).
    /// A source window left without workspaces closes.</summary>
    internal static void MoveTab(string workspaceId, string paneId, string surfaceId, MainWindow target, string targetWorkspaceId, string targetPaneId, string? beforeSurfaceId, bool activate = true)
    {
        // The same window works too: a tab to another workspace of it (surface.move).
        if (OwnerOfWorkspace(workspaceId) is not { } source) return;
        target.AdoptTab(targetWorkspaceId, targetPaneId, source.TakeTab(workspaceId, paneId, surfaceId), beforeSurfaceId);
        if (activate) target.Activate();
        if (source.WorkspaceCount == 0) source.CloseWithoutAsking();
        SaveAll();
    }

    /// <summary>Whether a screen point (physical pixels) is over any Programa window.</summary>
    internal static bool IsOverAnyWindow(Windows.Graphics.PointInt32 point) =>
        Open.Any(window => window.AppWindow.Position is var position && window.AppWindow.Size is var size
            && point.X >= position.X && point.X < position.X + size.Width && point.Y >= position.Y && point.Y < position.Y + size.Height);

    private static MainWindow Deliver(MainWindow source, WorkspaceTransfer transfer, MainWindow? target)
    {
        // The target exists before an emptied source closes, so the app never sees its last window go.
        if (target is null) target = OpenWindow(adopt: transfer);
        else
        {
            target.AdoptWorkspace(transfer);
            target.Activate();
        }
        if (source.WorkspaceCount == 0) source.CloseWithoutAsking();
        SaveAll();
        return target;
    }

    /// <summary>The control pipe's handler: window methods here, everything else in the window that
    /// owns the ids the request names, else in the window last focused.</summary>
    private static Task<object?> HandleAsync(string method, JsonElement p)
    {
        var done = new TaskCompletionSource<Task<object?>>(TaskCreationOptions.RunContinuationsAsynchronously);
        var queued = _dispatcher!.TryEnqueue(() =>
        {
            try { done.SetResult(Route(method, p)); }
            catch (Exception error) { done.SetException(error); }
        });
        if (!queued) return Task.FromException<object?>(new ControlException("unavailable", "Programa is closing."));
        return done.Task.Unwrap();
    }

    private static Task<object?> Route(string method, JsonElement p)
    {
        switch (method)
        {
            case "window.list":
                return Task.FromResult<object?>(new
                {
                    windows = Open.Select((window, index) => new
                    {
                        id = window.WindowId, index = index + 1, selected = window == Current,
                        workspace_count = window.WorkspaceCount, selected_workspace_id = window.SelectedWorkspaceId,
                    }),
                });
            case "window.current":
                var current = Text(p, "window_id") is { } asked ? WindowById(asked) ?? throw NotFound("window", asked) : Current ?? throw NotFound("window", null);
                return Task.FromResult<object?>(new { window_id = current.WindowId, workspace_id = current.SelectedWorkspaceId });
            case "window.create":
                var created = OpenWindow();
                return Task.FromResult<object?>(new { window_id = created.WindowId, workspace_id = created.SelectedWorkspaceId });
            case "window.focus":
                var focused = RequiredWindow(p);
                focused.Activate();
                Current = focused;
                return Task.FromResult<object?>(new { window_id = focused.WindowId });
            case "window.close":
                RequiredWindow(p).CloseWithoutAsking();
                return Task.FromResult<object?>(new { });
            case "workspace.move_to_window":
                var workspaceId = Text(p, "workspace_id") ?? throw new ControlException("invalid_params", "workspace_id is required.");
                // "new" opens a window for it (a Windows extension; macOS takes an existing window).
                var target = Text(p, "window_id") is "new" or null ? null : RequiredWindow(p);
                var moved = MoveWorkspace(workspaceId, target);
                return Task.FromResult<object?>(new { workspace_id = workspaceId, window_id = moved.WindowId });
            case "surface.move":
                return Task.FromResult<object?>(MoveSurfaceFromControl(p));
            case "pane.join":
                // surface.move of the surface (else the pane's selected tab) into target_pane_id, as on macOS.
                var joinTarget = Text(p, "target_pane_id") ?? throw new ControlException("invalid_params", "target_pane_id is required.");
                var joined = Text(p, "surface_id")
                    ?? (Text(p, "pane_id") is { } fromPane
                        ? Open.Select(window => window.SelectedSurfaceOfPane(fromPane)).FirstOrDefault(id => id is not null)
                            ?? throw new ControlException("not_found", "Unable to resolve selected surface in source pane", new { pane_id = fromPane })
                        : throw new ControlException("invalid_params", "Missing surface_id (or pane_id with selected surface)"));
                return Task.FromResult<object?>(MoveSurfaceFromControl(JsonSerializer.SerializeToElement(new { surface_id = joined, pane_id = joinTarget })));
            case "debug.tab.tear_off" when BuildIdentity.Value.Contains("0.0.0-dev", StringComparison.Ordinal):
                // As a tab drag released outside every window: a new window under the screen point.
                var tornId = Text(p, "surface_id") ?? throw new ControlException("invalid_params", "surface_id is required.");
                var tornFrom = OwnerOfSurface(tornId) ?? throw NotFound("surface", tornId);
                if (!p.TryGetProperty("x", out var x) || !p.TryGetProperty("y", out var y) || !x.TryGetDouble(out var tornX) || !y.TryGetDouble(out var tornY))
                    throw new ControlException("invalid_params", "x and y are required.");
                if (Open.Count == 1 && tornFrom.IsOnlyTab(tornId)) throw new ControlException("invalid_params", "The app's only tab stays in its window.");
                var (tornWorkspace, tornPane) = tornFrom.LocateSurface(tornId);
                var torn = MoveSurfaceToNewWindow(tornWorkspace, tornPane, tornId, new Windows.Graphics.PointInt32((int)tornX, (int)tornY));
                return Task.FromResult<object?>(new { surface_id = tornId, window_id = torn.WindowId, workspace_id = torn.SelectedWorkspaceId });
            case "debug.command_palette.toggle" or "debug.command_palette.results" or "debug.type" when BuildIdentity.Value.Contains("0.0.0-dev", StringComparison.Ordinal):
                var paletteWindow = method == "debug.type" ? Open.FirstOrDefault(window => window.PaletteOpen) ?? Current! : Text(p, "window_id") is null ? Current! : RequiredWindow(p);
                return Task.FromResult<object?>(paletteWindow.PaletteDebug(method, p));
            case "agent.task.start" or "agent.task.update" or "agent.task.finish" or "agent.task.finish_session" or "agent.task.list":
                return Task.FromResult<object?>(Helpers.FromControl(method, p, id => OwnerOfWorkspace(id) is not null,
                    (workspace, surface) => OwnerOfWorkspace(workspace)?.WorkspaceHasSurface(workspace, surface) == true, DateTimeOffset.UtcNow));
            case "system.tree":
                return Task.FromResult<object?>(Tree(p));
            case "app.reload_config":
                // settings.json and the terminal configuration, as their file watcher applies them.
                ApplySettings();
                return Task.FromResult<object?>(new { reloaded = true });
            case "snapshot.list":
                return Task.FromResult<object?>(SessionHistory.List());
            case "snapshot.restore":
                // New windows only: an open window is never touched.
                var (restoredWindows, restoredWorkspaces, restoredPanels) = SessionHistory.Restore(Text(p, "id"));
                foreach (var restored in restoredWindows) OpenWindow(false, restored);
                SaveAll();
                return Task.FromResult<object?>(new { restored = new { windows = restoredWindows.Count, workspaces = restoredWorkspaces, panels = restoredPanels } });
            case "ports.list":
                return Task.FromResult<object?>(PortsList());
            case "routes.list":
                return Task.FromResult<object?>(RouteEngine.List());
            case "storage.scan" or "storage.clean":
                return StorageFromControl(method, p);
            case "ports.stop":
                foreach (var window in Open) window.RescanPorts();
                var pid = p.ValueKind == JsonValueKind.Object && p.TryGetProperty("pid", out var value) && value.TryGetInt32(out var number) ? number : 0;
                var owner = Open.FirstOrDefault(window => window.HasPortProcess(pid)) ?? Current!;
                return owner.HandleControlAsync(method, p);
        }
        var routed = (Text(p, "window_id") is { } windowId ? WindowById(windowId) : null)
            ?? (Text(p, "surface_id") is { } surfaceId ? OwnerOfSurface(surfaceId) : null)
            ?? (Text(p, "tab_id") is { } tabId ? OwnerOfSurface(tabId) : null)
            ?? (Text(p, "workspace_id") is { } id ? OwnerOfWorkspace(id) : null)
            ?? (Text(p, "parent_workspace_id") is { } parentId ? OwnerOfWorkspace(parentId) : null)
            ?? (Text(p, "pane_id") is { } routedPane ? Open.FirstOrDefault(window => window.PaneWorkspace(routedPane) is not null) : null)
            ?? Current ?? Open[0];
        return routed.HandleControlAsync(method, p);
    }

    /// <summary>system.tree, as on macOS: the focused window (every window with all_windows, or the one
    /// holding workspace_id), with the focus and, given caller, where the calling terminal is.</summary>
    private static object Tree(JsonElement p)
    {
        var only = Text(p, "workspace_id");
        var focused = Text(p, "window_id") is { } windowId ? WindowById(windowId) ?? throw NotFound("window", windowId) : Current ?? Open.FirstOrDefault();
        var windows = new List<object>();
        if (only is not null)
        {
            var owner = OwnerOfWorkspace(only) ?? throw new ControlException("not_found", "Workspace not found", new { workspace_id = only });
            windows.Add(owner.TreeWindow(Open.IndexOf(owner), owner == Current, only));
        }
        else
        {
            var all = Flag(p, "all_windows") ?? false;
            for (var index = 0; index < Open.Count; index++)
                if (all || Open[index] == focused) windows.Add(Open[index].TreeWindow(index, Open[index] == Current, null));
        }
        object? caller = null;
        if (p.ValueKind == JsonValueKind.Object && p.TryGetProperty("caller", out var from) && Text(from, "workspace_id") is { } callerWorkspace)
            caller = OwnerOfWorkspace(callerWorkspace)?.TreeCaller(callerWorkspace, Text(from, "surface_id") ?? Text(from, "tab_id"));
        return new { active = focused?.TreeFocus(), caller, windows };
    }

    /// <summary>`surface.move`, as on macOS: a tab to a pane (pane_id), to a workspace's selected pane
    /// (workspace_id), to a window's selected pane (window_id), or to a new window (window_id "new"), at
    /// before_surface_id, after_surface_id or index (else last). Moves take no focus unless `focus`.</summary>
    private static object MoveSurfaceFromControl(JsonElement p)
    {
        var surfaceId = Text(p, "surface_id") ?? throw new ControlException("invalid_params", "surface_id is required.");
        var source = OwnerOfSurface(surfaceId) ?? throw NotFound("surface", surfaceId);
        var (sourceWorkspace, sourcePane) = source.LocateSurface(surfaceId);
        var focus = Flag(p, "focus") ?? false;
        if (Text(p, "window_id") == "new")
        {
            if (Open.Count == 1 && source.IsOnlyTab(surfaceId)) throw new ControlException("invalid_params", "The app's only tab stays in its window.");
            var opened = MoveSurfaceToNewWindow(sourceWorkspace, sourcePane, surfaceId);
            return new { surface_id = surfaceId, window_id = opened.WindowId, workspace_id = opened.SelectedWorkspaceId };
        }
        MainWindow target;
        string workspaceId, paneId;
        if (Text(p, "pane_id") is { } pane)
        {
            target = Open.FirstOrDefault(window => window.PaneWorkspace(pane) is not null) ?? throw NotFound("pane", pane);
            (workspaceId, paneId) = (target.PaneWorkspace(pane)!, pane);
        }
        else if (Text(p, "workspace_id") is { } workspace)
        {
            target = OwnerOfWorkspace(workspace) ?? throw NotFound("workspace", workspace);
            (workspaceId, paneId) = (workspace, target.SelectedPaneOf(workspace));
        }
        else if (Text(p, "window_id") is { } windowId)
        {
            target = WindowById(windowId) ?? throw NotFound("window", windowId);
            workspaceId = target.SelectedWorkspaceId ?? throw NotFound("workspace", null);
            paneId = target.SelectedPaneOf(workspaceId);
        }
        else throw new ControlException("invalid_params", "pane_id, workspace_id or window_id is required.");
        var others = target.SurfacesOf(workspaceId, paneId).Where(id => id != surfaceId).ToList();
        string? before;
        if (Text(p, "before_surface_id") is { } beforeId) before = others.Contains(beforeId) ? beforeId : throw NotFound("surface", beforeId);
        else if (Text(p, "after_surface_id") is { } afterId)
        {
            var at = others.IndexOf(afterId);
            if (at < 0) throw NotFound("surface", afterId);
            before = at + 1 < others.Count ? others[at + 1] : null;
        }
        else if (p.TryGetProperty("index", out var index) && index.TryGetInt32(out var position)) before = position >= 0 && position < others.Count ? others[position] : null;
        else before = null;
        if (target == source && workspaceId == sourceWorkspace) source.MoveWithinWorkspace(workspaceId, sourcePane, paneId, surfaceId, before);
        else MoveTab(sourceWorkspace, sourcePane, surfaceId, target, workspaceId, paneId, before, activate: focus);
        if (focus) JumpTo(surfaceId);
        return new { surface_id = surfaceId, window_id = target.WindowId, workspace_id = workspaceId, pane_id = paneId };
    }

    /// <summary>`ports.list` across every window, grouped by workspace.</summary>
    private static object PortsList() => new
    {
        workspaces = Open.SelectMany(window => window.DescribePortWorkspaces()),
        left_running = Open.SelectMany(window => window.DescribeLeftRunning()),
    };

    private static MainWindow RequiredWindow(JsonElement p)
    {
        var id = Text(p, "window_id") ?? throw new ControlException("invalid_params", "window_id is required.");
        return WindowById(id) ?? throw NotFound("window", id);
    }

    private static ControlException NotFound(string what, string? id) =>
        new("not_found", id is null ? $"No {what} is open." : $"{what} '{id}' was not found.");

    private static string? Text(JsonElement p, string name) =>
        p.ValueKind == JsonValueKind.Object && p.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.String ? value.GetString() : null;
}
