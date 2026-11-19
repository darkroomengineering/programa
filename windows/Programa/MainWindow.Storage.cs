using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Input;

namespace Programa;

/// <summary>The Storage button in the sidebar footer and its panel, as on macOS (docs/workspace-interface.md,
/// Storage): free space on the home drive, disk usage by workspace directory with large build and
/// dependency folders, removable worktrees and package caches. Each Clean previews what it would
/// remove and asks first. Worktree and cache results are kept five minutes, session sizes two.</summary>
public sealed partial class MainWindow
{
    private sealed record StorageScan(DateTime At, List<Storage.Worktree> Worktrees, List<Storage.Cache> Caches);

    // The app's, like macOS StorageHubModel.shared: every window's panel shows the same scan.
    private static volatile StorageScan? _storageScan;
    private static readonly Dictionary<string, (DateTime At, Storage.LiveSession Session)> SessionSizes = new(StringComparer.OrdinalIgnoreCase);

    /// <summary>What worktrees and caches could free, from the last scan; null before one.</summary>
    internal static long? CachedReclaimableBytes => _storageScan is { } scan
        ? scan.Worktrees.Where(worktree => worktree.Removable).Sum(worktree => worktree.SizeBytes) + scan.Caches.Where(cache => cache.AutoCleanable && cache.Blocker is null).Sum(cache => cache.SizeBytes)
        : null;

    /// <summary>Forgets the scan after a clean, so the next look scans again.</summary>
    internal static void InvalidateStorage() => _storageScan = null;

    private AppBarButton? _storageButton;
    private Flyout? _storageFlyout;
    private ScrollViewer? _storageScroll;
    private StackPanel? _storageBody;
    private bool _storageBusy;
    /// <summary>A clean awaiting confirmation: its dry run and the options that remove it.</summary>
    private (Storage.CleanResult Preview, Storage.CleanOptions Options)? _storagePreview;
    private Storage.CleanResult? _storageResult;

    private AppBarButton StorageButton()
    {
        var label = Localizer.Get("StorageTitle");
        _storageButton = new AppBarButton { Icon = new FontIcon { Glyph = "" }, LabelPosition = CommandBarLabelPosition.Collapsed, Width = 44, MinHeight = 44 };
        AutomationProperties.SetName(_storageButton, label);
        ToolTipService.SetToolTip(_storageButton, label);
        _storageButton.Click += (_, _) => ShowStoragePanel();
        return _storageButton;
    }

    /// <summary>The low-disk toast was clicked: reveal the sidebar if needed and open Storage.</summary>
    internal void ShowStorageFromNotification()
    {
        Activate();
        if (!_sidebarVisible) ToggleSidebar();
        // The button joins the tree with the sidebar; open once it is laid out.
        DispatcherQueue.TryEnqueue(Microsoft.UI.Dispatching.DispatcherQueuePriority.Low, ShowStoragePanel);
    }

    private void ShowStoragePanel()
    {
        if (_storageButton is null || _storageButton.XamlRoot is null) return;
        _storagePreview = null;
        _storageResult = null;
        _storageBody = new StackPanel { Spacing = 6, Width = 360 };
        // Focusable, so a redraw that removes the focused button (Clean, Remove) keeps keyboard focus in the panel.
        _storageScroll = new ScrollViewer { Content = _storageBody, MaxHeight = 480, IsTabStop = true, UseSystemFocusVisuals = false };
        _storageFlyout = new Flyout { Placement = FlyoutPlacementMode.TopEdgeAlignedLeft, Content = _storageScroll };
        _storageFlyout.Closed += (_, _) => _storageFlyout = null;
        RenderStorage();
        ShowFooterFlyout(_storageFlyout, _storageButton);
        RefreshStorage();
    }

    /// <summary>Measures the workspace directories (two-minute cache) and scans worktrees and caches
    /// (five-minute cache), off the UI thread, re-rendering as each part arrives.</summary>
    private void RefreshStorage()
    {
        var sessions = StorageSessionDirectories();
        var open = WindowRegistry.Windows.SelectMany(window => window.OpenDirectories()).ToList();
        var settings = WorktreeSettings.Load();
        var scan = _storageScan is not { } last || DateTime.UtcNow - last.At > TimeSpan.FromMinutes(5);
        _storageBusy = true;
        RenderStorage();
        _ = Task.Run(() =>
        {
            foreach (var (title, path) in sessions)
            {
                lock (SessionSizes)
                    if (SessionSizes.TryGetValue(path, out var cached) && DateTime.UtcNow - cached.At < TimeSpan.FromMinutes(2)) continue;
                var measured = Storage.MeasureSession(title, path);
                lock (SessionSizes) SessionSizes[path] = (DateTime.UtcNow, measured);
            }
            DispatcherQueue.TryEnqueue(RenderStorage);
            if (scan)
            {
                var worktrees = Storage.ScanWorktrees(open, settings);
                var caches = Storage.ScanCaches(worktrees.SelectMany(worktree => new[] { worktree.Path, worktree.RepoRoot }).ToList());
                _storageScan = new StorageScan(DateTime.UtcNow, worktrees, caches);
            }
        }).ContinueWith(_ => DispatcherQueue.TryEnqueue(() =>
        {
            _storageBusy = false;
            RenderStorage();
        }));
    }

    /// <summary>Every window's workspace directories, one row per directory naming its workspaces;
    /// the home folder and drive roots are left out, as macOS leaves out home and /.</summary>
    private static List<(string Title, string Path)> StorageSessionDirectories()
    {
        var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        return WindowRegistry.Windows
            .SelectMany(window => window._snapshot.Workspaces.SelectMany(workspace => workspace.Panes
                .SelectMany(pane => pane.Surfaces)
                .Select(surface => window._terminals.GetValueOrDefault(surface.Id)?.WorkingDirectory)
                .OfType<string>()
                .Select(path => (Title: window.WorkspaceTitle(workspace), Path: path.TrimEnd('\\')))))
            .Where(item => Directory.Exists(item.Path) && !Worktrees.SamePath(item.Path, home) && Path.GetPathRoot(item.Path)?.TrimEnd('\\') != item.Path)
            .GroupBy(item => item.Path, StringComparer.OrdinalIgnoreCase)
            .Select(group => (string.Join(", ", group.Select(item => item.Title).Distinct()), group.Key))
            .ToList();
    }

    private void RenderStorage()
    {
        if (_storageBody is null || _storageFlyout is null) return;
        var body = _storageBody;
        if (_storageScroll?.XamlRoot is { } root && FocusManager.GetFocusedElement(root) is DependencyObject focused && IsInside(focused, body))
            _storageScroll.Focus(FocusState.Programmatic);
        body.Children.Clear();
        body.Children.Add(new TextBlock { Text = Localizer.Get("StorageTitle"), FontWeight = Microsoft.UI.Text.FontWeights.SemiBold });
        body.Children.Add(Secondary(Storage.Capacity() is { } capacity
            ? string.Format(Localizer.Get("StorageCapacity"), Storage.Bytes(capacity.Available), Storage.Bytes(capacity.Total))
            : Localizer.Get("StorageCapacityUnavailable")));
        if (_storageBusy)
        {
            var working = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
            working.Children.Add(new ProgressRing { IsActive = true, Width = 16, Height = 16 });
            working.Children.Add(new TextBlock { Text = Localizer.Get("StorageWorking") });
            body.Children.Add(working);
        }
        if (_storagePreview is { } preview)
        {
            RenderStorageConfirmation(body, preview.Preview, preview.Options);
            return;
        }
        RenderLiveSessions(body);
        if (_storageScan is { } scan) RenderStorageCategories(body, scan);
        if (_storageResult is { } result) RenderStorageOutcome(body, result);
    }

    private static void RenderLiveSessions(StackPanel body)
    {
        body.Children.Add(Heading(Localizer.Get("StorageLiveSessions")));
        var sessions = StorageSessionDirectories();
        if (sessions.Count == 0) body.Children.Add(Secondary(Localizer.Get("StorageLiveSessionsEmpty")));
        foreach (var (title, path) in sessions)
        {
            Storage.LiveSession? measured;
            lock (SessionSizes) measured = SessionSizes.TryGetValue(path, out var cached) ? cached.Session : null;
            var row = new Grid { ColumnSpacing = 8 };
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            row.Children.Add(new TextBlock { Text = title, TextTrimming = TextTrimming.CharacterEllipsis });
            var size = Secondary(measured is null ? Localizer.Get("StorageMeasuring") : (measured.Partial ? "~" : "") + Storage.Bytes(measured.Bytes));
            Grid.SetColumn(size, 1);
            row.Children.Add(size);
            ToolTipService.SetToolTip(row, path);
            body.Children.Add(row);
            if (measured is { Heavy.Count: > 0 })
                body.Children.Add(Secondary(string.Join(" · ", measured.Heavy.Select(folder => $"{folder.Name} {Storage.Bytes(folder.Bytes)}"))));
        }
    }

    private void RenderStorageCategories(StackPanel body, StorageScan scan)
    {
        // The panel's worktree Clean skips the idle wait, so recently used worktrees count as removable here.
        var removable = scan.Worktrees.Where(worktree => worktree.Blocker is null or "recently_used").ToList();
        var kept = scan.Worktrees.Except(removable).ToList();
        body.Children.Add(new MenuFlyoutSeparator());
        body.Children.Add(HeadingWithClean(Localizer.Get("StorageWorktrees"), null, removable.Count == 0,
            () => PrepareStorageClean(new Storage.CleanOptions(IgnoreGracePeriod: true))));
        body.Children.Add(Secondary(string.Format(Localizer.Get("StorageWorktreeSummary"), removable.Count, Storage.Bytes(removable.Sum(worktree => worktree.SizeBytes)), kept.Count)));
        if (scan.Worktrees.Any(worktree => worktree.SizePartial)) body.Children.Add(Secondary(Localizer.Get("StoragePartial")));
        foreach (var worktree in kept) body.Children.Add(KeptRow(worktree.Branch ?? worktree.Path, worktree.Blocker!));
        var packages = scan.Caches.Where(cache => cache.Category == "packages").ToList();
        if (packages.Count == 0) return;
        body.Children.Add(new MenuFlyoutSeparator());
        body.Children.Add(HeadingWithClean(Localizer.Get("StoragePackages"), Storage.Bytes(packages.Sum(cache => cache.SizeBytes)), packages.All(cache => cache.Blocker is not null),
            () => PrepareStorageClean(new Storage.CleanOptions(Categories: ["packages"], Worktrees: false))));
        foreach (var cache in packages.Where(cache => cache.Blocker is not null)) body.Children.Add(KeptRow(cache.Title, cache.Blocker!));
    }

    private FrameworkElement HeadingWithClean(string title, string? total, bool disabled, Action clean)
    {
        var row = new Grid { ColumnSpacing = 8 };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        row.Children.Add(Heading(title));
        if (total is not null)
        {
            var size = Secondary(total);
            size.VerticalAlignment = VerticalAlignment.Center;
            Grid.SetColumn(size, 1);
            row.Children.Add(size);
        }
        var button = new Button { Content = Localizer.Get("StorageClean"), IsEnabled = !disabled && !_storageBusy, Padding = new Thickness(10, 2, 10, 2) };
        button.Click += (_, _) => clean();
        Grid.SetColumn(button, 2);
        row.Children.Add(button);
        return row;
    }

    /// <summary>A dry run first: the panel lists what would go and asks.</summary>
    private void PrepareStorageClean(Storage.CleanOptions options)
    {
        var open = WindowRegistry.Windows.SelectMany(window => window.OpenDirectories()).ToList();
        var settings = WorktreeSettings.Load();
        _storageResult = null;
        _storageBusy = true;
        RenderStorage();
        _ = Task.Run(() => Storage.Clean(options with { DryRun = true }, open, settings)).ContinueWith(task => DispatcherQueue.TryEnqueue(() =>
        {
            _storageBusy = false;
            if (task.IsCompletedSuccessfully) _storagePreview = (task.Result, options);
            RenderStorage();
        }));
    }

    private void RenderStorageConfirmation(StackPanel body, Storage.CleanResult preview, Storage.CleanOptions options)
    {
        var items = CleanItems(preview);
        body.Children.Add(Heading(Localizer.Get("StorageConfirmTitle")));
        body.Children.Add(new TextBlock { Text = string.Format(Localizer.Get("StorageConfirmTotal"), items.Count, Storage.Bytes(items.Sum(item => item.Bytes))), TextWrapping = TextWrapping.Wrap });
        foreach (var (name, bytes, path) in items)
        {
            body.Children.Add(new TextBlock { Text = $"{name} ({Storage.Bytes(bytes)})", TextWrapping = TextWrapping.Wrap });
            body.Children.Add(new TextBlock { Text = path, FontSize = 11, Opacity = 0.7, IsTextSelectionEnabled = true, TextWrapping = TextWrapping.Wrap });
        }
        if (items.Count == 0) body.Children.Add(new TextBlock { Text = Localizer.Get("StorageEmpty") });
        RenderKept(body, preview);
        var buttons = new Grid { Margin = new Thickness(0, 6, 0, 0) };
        buttons.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        buttons.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var cancel = new Button { Content = Localizer.Get("Cancel") };
        cancel.Click += (_, _) => { _storagePreview = null; RenderStorage(); };
        var remove = new Button { Content = Localizer.Get("StorageRemove"), IsEnabled = items.Count > 0 && !_storageBusy, Style = (Style)Application.Current.Resources["AccentButtonStyle"] };
        remove.Click += (_, _) => ConfirmStorageClean(options);
        Grid.SetColumn(remove, 1);
        buttons.Children.Add(cancel);
        buttons.Children.Add(remove);
        body.Children.Add(buttons);
    }

    /// <summary>Removes for real; the rules are checked again, so the result can keep more than the preview did.</summary>
    private void ConfirmStorageClean(Storage.CleanOptions options)
    {
        var open = WindowRegistry.Windows.SelectMany(window => window.OpenDirectories()).ToList();
        var settings = WorktreeSettings.Load();
        _storagePreview = null;
        _storageBusy = true;
        RenderStorage();
        _ = Task.Run(() => Storage.Clean(options with { DryRun = false }, open, settings)).ContinueWith(task =>
        {
            InvalidateStorage();
            lock (SessionSizes) SessionSizes.Clear();
            DispatcherQueue.TryEnqueue(() =>
            {
                _storageBusy = false;
                _storageResult = task.IsCompletedSuccessfully ? task.Result : null;
                RefreshStorage();
            });
        });
    }

    private static void RenderStorageOutcome(StackPanel body, Storage.CleanResult result)
    {
        var items = CleanItems(result);
        body.Children.Add(new MenuFlyoutSeparator());
        body.Children.Add(Heading(string.Format(Localizer.Get("StorageResult"), items.Count, Storage.Bytes(items.Sum(item => item.Bytes)))));
        foreach (var item in items) body.Children.Add(Secondary(item.Path));
        RenderKept(body, result);
    }

    private static List<(string Name, long Bytes, string Path)> CleanItems(Storage.CleanResult result) =>
        result.Removed.Select(worktree => (worktree.Branch ?? worktree.Path, worktree.SizeBytes, worktree.Path))
            .Concat(result.CachesRemoved.Select(cache => (cache.Title, cache.SizeBytes, cache.Path)))
            .ToList();

    private static void RenderKept(StackPanel body, Storage.CleanResult result)
    {
        foreach (var kept in result.Kept) body.Children.Add(KeptRow(kept.Path, kept.Blocker));
        foreach (var cache in result.CachesKept) body.Children.Add(KeptRow(cache.Title, cache.Blocker ?? string.Empty));
    }

    private static TextBlock KeptRow(string name, string blocker) =>
        Secondary(string.Format(Localizer.Get("StorageKept"), name, StorageReason(blocker)));

    /// <summary>The macOS wording for each blocker.</summary>
    internal static string StorageReason(string code) => code switch
    {
        "external" => Localizer.Get("StorageReasonExternal"),
        "status_unknown" => Localizer.Get("StorageReasonUnknown"),
        "dirty" => Localizer.Get("StorageReasonDirty"),
        "env_files" => Localizer.Get("StorageReasonEnv"),
        "not_merged" => Localizer.Get("StorageReasonUnmerged"),
        "open_in_workspace" => Localizer.Get("StorageReasonOpen"),
        "process_running" => Localizer.Get("StorageReasonBusy"),
        "recently_used" => Localizer.Get("StorageReasonRecent"),
        "git_refused" => Localizer.Get("StorageReasonGit"),
        "manual_only" => Localizer.Get("StorageReasonManual"),
        _ => string.Format(Localizer.Get("StorageReasonTool"), code),
    };

    private static bool IsInside(DependencyObject element, DependencyObject container)
    {
        for (var current = element; current is not null; current = Microsoft.UI.Xaml.Media.VisualTreeHelper.GetParent(current))
            if (current == container) return true;
        return false;
    }

    private static TextBlock Heading(string text) => new() { Text = text, FontWeight = Microsoft.UI.Text.FontWeights.Medium, VerticalAlignment = VerticalAlignment.Center, TextWrapping = TextWrapping.Wrap };

    private static TextBlock Secondary(string text) => new() { Text = text, FontSize = 12, Opacity = 0.7, TextWrapping = TextWrapping.Wrap };
}
