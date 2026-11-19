using System.Diagnostics;
using System.Text;
using System.Text.RegularExpressions;

namespace Programa;

/// <summary>Storage, as on macOS (docs/socket-api.md, storage.*; docs/workspace-interface.md, Storage):
/// disk usage of linked git worktrees and package manager caches, with guarded cleanup. Worktrees
/// come from the repositories open in workspaces and from the worktrees folder; the main checkout is
/// never one. The Windows cache category is packages (npm, pnpm, Yarn, Bun); Xcode and Android
/// caches are macOS-only. Windows cannot read another process's directory, so process_running is
/// always false: Windows refuses to delete a folder a process works in, and git's refusal is kept
/// as git_refused. Everything here runs git, walks folders or starts tools, so it stays off the UI thread.</summary>
internal static partial class Storage
{
    internal sealed record Worktree(string RepoRoot, string Path, string? Branch, long SizeBytes, bool SizePartial, DateTime? LastModified,
        bool ProgramaCreated, WorktreeCleanup.WorktreeFacts Facts, bool OpenInWorkspace, string? Blocker)
    {
        internal bool Removable => Blocker is null;
    }

    internal sealed record Cache(string Id, string Category, string Title, string Path, long SizeBytes, bool SizePartial, DateTime? LastUsed,
        bool AutoCleanable, string? Blocker);

    internal sealed record Kept(string Path, string Blocker, string? Message = null);

    internal sealed record CleanResult(List<Worktree> Removed, List<Kept> Kept, List<Cache> CachesRemoved, List<Cache> CachesKept, bool DryRun);

    internal sealed record CleanOptions(bool DryRun = true, bool IncludeExternal = false, bool IgnoreGracePeriod = false,
        IReadOnlyCollection<string>? Categories = null, IReadOnlyCollection<string>? Items = null, IReadOnlyCollection<string>? Paths = null,
        bool Worktrees = true);

    internal sealed record LiveSession(string Title, string Path, long Bytes, bool Partial, List<(string Name, long Bytes)> Heavy);

    private static string Home => Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
    private static string LocalAppData => Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);

    // ---- Worktrees

    /// <summary>Every linked worktree of the repositories open in <paramref name="open"/> and under the
    /// worktrees folder, with its size, what git says about it, and the first blocker that keeps it.</summary>
    internal static List<Worktree> ScanWorktrees(IReadOnlyCollection<string> open, WorktreeSettings settings, bool includeExternal = false, bool ignoreGracePeriod = false, bool sizes = true)
    {
        var idle = ignoreGracePeriod ? (TimeSpan?)null : TimeSpan.FromHours(settings.AutoRemoveAfterHours);
        return Discover(open, settings.Directory).Select(item =>
        {
            var path = item.Entry.Path;
            var programaCreated = Worktrees.Contains(settings.Directory, path);
            var facts = WorktreeCleanup.Facts(path);
            var blocker = WorktreeCleanup.Blocker(path, facts, external: !programaCreated && !includeExternal, open, idle, monitor: false);
            var (bytes, partial, _) = sizes ? Measure(path, TimeSpan.FromSeconds(30)) : (0, true, null);
            return new Worktree(item.Repo, path, item.Entry.Branch, bytes, partial, WorktreeCleanup.LastUsed(path), programaCreated,
                facts, open.Any(directory => Worktrees.Contains(path, directory)), blocker);
        }).ToList();
    }

    /// <summary>Linked worktrees, each with its repository's main worktree, found from the candidates.</summary>
    private static List<(string Repo, WorktreeEntry Entry)> Discover(IEnumerable<string> open, string folder)
    {
        var candidates = open.ToList();
        try
        {
            if (Directory.Exists(folder)) candidates.AddRange(Directory.EnumerateDirectories(folder).SelectMany(Directory.EnumerateDirectories));
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { }
        var known = new List<string>();
        var result = new List<(string, WorktreeEntry)>();
        foreach (var candidate in candidates.Distinct(StringComparer.OrdinalIgnoreCase))
        {
            // One git call per repository: a directory inside a worktree already listed adds nothing.
            if (!Directory.Exists(candidate) || known.Any(path => Worktrees.Contains(path, candidate))) continue;
            var (code, list) = WorktreeCleanup.Git(candidate, "worktree", "list", "--porcelain");
            if (code != 0) continue;
            var entries = Worktrees.ParsePorcelain(list);
            if (entries.Count == 0 || known.Any(path => Worktrees.SamePath(path, entries[0].Path))) continue;
            known.AddRange(entries.Select(entry => entry.Path));
            result.AddRange(entries.Skip(1).Where(entry => Directory.Exists(entry.Path)).Select(entry => (entries[0].Path, entry)));
        }
        return result;
    }

    /// <summary>`storage.clean`: removes (or with DryRun lists) the removable worktrees and the selected
    /// caches. Worktrees go with `git worktree remove` without --force; branches stay.</summary>
    internal static CleanResult Clean(CleanOptions options, IReadOnlyCollection<string> open, WorktreeSettings settings)
    {
        var removed = new List<Worktree>();
        var kept = new List<Kept>();
        // A caches-only clean (the panel's category Clean) still needs the worktrees, to keep projects safe.
        var worktrees = ScanWorktrees(open, settings, options.IncludeExternal, options.IgnoreGracePeriod, sizes: options.Worktrees);
        foreach (var worktree in options.Worktrees ? worktrees : [])
        {
            if (options.Paths is { Count: > 0 } paths && !paths.Any(path => Worktrees.Contains(Path.GetFullPath(path), worktree.Path))) continue;
            if (worktree.Blocker is { } blocker) kept.Add(new(worktree.Path, blocker));
            else if (options.DryRun) removed.Add(worktree);
            else if (WorktreeCleanup.Remove(worktree.RepoRoot, worktree.Path) is { } message) kept.Add(new(worktree.Path, "git_refused", message));
            else removed.Add(worktree);
        }
        var cachesRemoved = new List<Cache>();
        var cachesKept = new List<Cache>();
        var selected = SelectCaches(options.Categories, options.Items);
        if (selected is not null)
        {
            var projects = worktrees.Select(worktree => worktree.Path).Concat(worktrees.Select(worktree => worktree.RepoRoot)).ToList();
            foreach (var cache in ScanCaches(projects).Where(selected))
            {
                if (cache.Blocker is not null) cachesKept.Add(cache);
                else if (options.DryRun || RemoveCache(cache, projects)) cachesRemoved.Add(cache);
                else cachesKept.Add(cache with { Blocker = "tool_failed" });
            }
        }
        return new(removed, kept, cachesRemoved, cachesKept, options.DryRun);
    }

    /// <summary>Explicit categories and items, as on macOS: items narrow the chosen categories, or pick
    /// those ids across categories when none is chosen. Null when no cache is selected at all.</summary>
    internal static Func<Cache, bool>? SelectCaches(IReadOnlyCollection<string>? categories, IReadOnlyCollection<string>? items)
    {
        var byCategory = categories is { Count: > 0 };
        var byItem = items is { Count: > 0 };
        if (!byCategory && !byItem) return null;
        return cache => (!byCategory || categories!.Contains(cache.Category)) && (!byItem || items!.Contains(cache.Id));
    }

    /// <summary>The six-hourly pass with storage.autoCleanCaches: automatic, unblocked caches only.</summary>
    internal static List<Cache> AutoCleanCaches(IReadOnlyCollection<string> projects) =>
        ScanCaches(projects).Where(cache => cache.AutoCleanable && cache.Blocker is null && RemoveCache(cache, projects)).ToList();

    // ---- Package caches

    private sealed record CacheLocation(string Manager, string Id, string Title, string Path, string? Tool);

    private static readonly TimeSpan IdleForAutomaticCleanup = TimeSpan.FromDays(14);

    internal static List<Cache> ScanCaches(IReadOnlyCollection<string> projects)
    {
        var locations = CacheLocations(projects);
        if (locations.Count == 0) return [];
        var commandLines = CommandLines();
        return locations.Select(location =>
        {
            // One walk gives the size and the last use; a walk cut short knows neither for sure.
            var (bytes, partial, latest) = Measure(location.Path, TimeSpan.FromSeconds(20));
            var automatic = (location.Manager == "pnpm" && location.Tool is not null)
                || (latest is { } used && DateTime.UtcNow - used >= IdleForAutomaticCleanup);
            return new Cache("packages." + location.Id, "packages", location.Title, location.Path, bytes, partial, latest, automatic,
                InstallRunning(location.Manager, commandLines) ? "install_running" : null);
        }).ToList();
    }

    /// <summary>Where each package manager keeps its cache: asked of the tool when it is installed,
    /// else its Windows default. Only paths that pass <see cref="SafeCachePath"/>.</summary>
    private static List<CacheLocation> CacheLocations(IReadOnlyCollection<string> projects)
    {
        var result = new List<CacheLocation>();
        void Add(string manager, string id, string title, string? path, string? tool)
        {
            if (path is { Length: > 0 } && !path.Contains('\n') && SafeCachePath(path, Home, projects))
                result.Add(new(manager, id, title, Path.GetFullPath(path), tool));
        }
        string? Ask(string? tool, params string[] arguments) => tool is null ? null : RunTool(tool, arguments, TimeSpan.FromSeconds(30))?.Trim();

        Add("bun", "bun", "bun", Environment.GetEnvironmentVariable("BUN_INSTALL_CACHE_DIR") is { Length: > 0 } bunCache ? bunCache : Path.Combine(Home, ".bun", "install", "cache"), FindTool("bun"));
        var npm = FindTool("npm");
        var npmRoot = Ask(npm, "config", "get", "cache");
        Add("npm", "npm", "npm", Path.Combine(npmRoot is { Length: > 0 } && Path.IsPathRooted(npmRoot) ? npmRoot : Path.Combine(LocalAppData, "npm-cache"), "_cacache"), npm);
        var pnpm = FindTool("pnpm");
        Add("pnpm", "pnpm", "pnpm", pnpm is null ? Path.Combine(LocalAppData, "pnpm", "store") : Ask(pnpm, "store", "path"), pnpm);
        var yarn = FindTool("yarn");
        var major = int.TryParse(Ask(yarn, "--version")?.Split('.')[0], out var number) ? number : 0;
        var berry = Path.Combine(Home, ".yarn", "berry", "cache");
        if (yarn is null)
        {
            Add("yarn", "yarn_classic", "yarn", Path.Combine(LocalAppData, "Yarn", "Cache"), null);
            Add("yarn", "yarn_berry", "Yarn Berry", berry, null);
        }
        else if (major == 1) Add("yarn", "yarn_classic", "yarn", Ask(yarn, "cache", "dir"), yarn);
        // Berry only when its global cache is verifiably the one in the home folder.
        else if (major >= 2 && Ask(yarn, "config", "get", "globalFolder") is { Length: > 0 } global && Worktrees.SamePath(Path.Combine(global, "cache"), berry))
            Add("yarn", "yarn_berry", "Yarn Berry", berry, yarn);
        return result;
    }

    /// <summary>A path cleanup may touch: an existing absolute folder reached without junctions or
    /// links, named like a cache or store, not a home or system root, not in a repository or project.</summary>
    internal static bool SafeCachePath(string path, string home, IReadOnlyCollection<string> projects)
    {
        if (!Path.IsPathRooted(path)) return false;
        var full = Path.GetFullPath(path).TrimEnd('\\');
        if (!Directory.Exists(full) || Worktrees.Contains(full, home) || Path.GetPathRoot(full)?.TrimEnd('\\') == full) return false;
        var components = full.Split('\\', StringSplitOptions.RemoveEmptyEntries).Select(component => component.ToLowerInvariant()).ToList();
        if (!components.Any(component => component is "cache" or "caches" or "_cacache" or "store" || component.EndsWith("-cache", StringComparison.Ordinal))) return false;
        if (projects.Any(project => Worktrees.Contains(project, full))) return false;
        for (var folder = new DirectoryInfo(full); folder is not null; folder = folder.Parent)
        {
            if (folder.Attributes.HasFlag(FileAttributes.ReparsePoint)) return false;
            if (Path.Exists(Path.Combine(folder.FullName, ".git"))) return false;
        }
        return true;
    }

    private static string[] CleanArguments(string manager, string id) => manager switch
    {
        "bun" => ["pm", "cache", "rm"],
        "npm" => ["cache", "clean", "--force"],
        "pnpm" => ["store", "prune"],
        _ => id == "yarn_berry" ? ["cache", "clean", "--mirror"] : ["cache", "clean"],
    };

    /// <summary>Checks the cache again (still where it was, still safe, no install running), then lets
    /// its manager clean it, or empties the folder when the manager is not installed.</summary>
    private static bool RemoveCache(Cache cache, IReadOnlyCollection<string> projects)
    {
        var location = CacheLocations(projects).FirstOrDefault(item => "packages." + item.Id == cache.Id && Worktrees.SamePath(item.Path, cache.Path));
        if (location is null || InstallRunning(location.Manager, CommandLines())) return false;
        if (location.Tool is not null) return RunTool(location.Tool, CleanArguments(location.Manager, location.Id), TimeSpan.FromMinutes(2)) is not null;
        try
        {
            foreach (var entry in new DirectoryInfo(location.Path).EnumerateFileSystemInfos())
            {
                if (entry is DirectoryInfo folder && !folder.Attributes.HasFlag(FileAttributes.ReparsePoint)) folder.Delete(recursive: true);
                else entry.Delete();
            }
            return true;
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { return false; }
    }

    [GeneratedRegex("\"[^\"]*\"|\\S+")]
    private static partial Regex Token();

    /// <summary>Whether a command line runs this manager's install (install, add, i, ci; or a bare
    /// `yarn`). No process list (null) counts as running, so nothing is removed blind.</summary>
    internal static bool InstallRunning(string manager, IEnumerable<string>? commandLines)
    {
        if (commandLines is null) return true;
        foreach (var line in commandLines)
        {
            var tokens = Token().Matches(line).Select(match => match.Value.Trim('"')).ToList();
            var index = tokens.FindIndex(token =>
            {
                var name = Path.GetFileName(token).ToLowerInvariant();
                return name == manager || name == manager + ".exe" || name == manager + ".cmd" || name == manager + ".js" || name == manager + ".cjs" || name == manager + "-cli.js"
                    || (manager == "yarn" && name.StartsWith("yarn-", StringComparison.Ordinal) && (name.EndsWith(".cjs", StringComparison.Ordinal) || name.EndsWith(".js", StringComparison.Ordinal)));
            });
            if (index < 0) continue;
            var arguments = tokens.Skip(index + 1).ToList();
            if (manager == "yarn" && arguments.All(argument => argument.StartsWith('-'))) return true;
            if (arguments.Any(argument => argument.ToLowerInvariant() is "install" or "add" or "i" or "ci")) return true;
        }
        return false;
    }

    /// <summary>Every process's command line (Windows keeps them per process; CIM reads them), or null.</summary>
    private static List<string>? CommandLines()
    {
        var powershell = Path.Combine(Environment.SystemDirectory, "WindowsPowerShell", "v1.0", "powershell.exe");
        return RunTool(powershell, ["-NoProfile", "-NonInteractive", "-Command", "Get-CimInstance Win32_Process | ForEach-Object { $_.CommandLine }"], TimeSpan.FromSeconds(20))
            ?.Split('\n', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries).ToList();
    }

    /// <summary>The tool's full path on PATH (.exe, then the .cmd or .bat shims npm installs), or null.</summary>
    internal static string? FindTool(string name)
    {
        foreach (var directory in (Environment.GetEnvironmentVariable("PATH") ?? string.Empty).Split(';', StringSplitOptions.RemoveEmptyEntries))
            foreach (var extension in new[] { ".exe", ".cmd", ".bat" })
            {
                try
                {
                    var path = Path.Combine(directory.Trim().Trim('"'), name + extension);
                    if (File.Exists(path)) return path;
                }
                catch (ArgumentException) { }
            }
        return null;
    }

    /// <summary>Runs a tool in the home folder; its output when it exits 0 in time, else null.</summary>
    private static string? RunTool(string tool, string[] arguments, TimeSpan timeout)
    {
        var script = tool.EndsWith(".cmd", StringComparison.OrdinalIgnoreCase) || tool.EndsWith(".bat", StringComparison.OrdinalIgnoreCase);
        var start = new ProcessStartInfo(script ? Environment.GetEnvironmentVariable("ComSpec") ?? "cmd.exe" : tool)
        {
            WorkingDirectory = Home, CreateNoWindow = true, UseShellExecute = false,
            RedirectStandardOutput = true, RedirectStandardError = true, StandardOutputEncoding = Encoding.UTF8,
        };
        if (script) foreach (var argument in new[] { "/d", "/c", tool }) start.ArgumentList.Add(argument);
        foreach (var argument in arguments) start.ArgumentList.Add(argument);
        try
        {
            using var process = Process.Start(start)!;
            var output = process.StandardOutput.ReadToEndAsync();
            _ = process.StandardError.ReadToEndAsync();
            if (!process.WaitForExit(timeout))
            {
                process.Kill(entireProcessTree: true);
                return null;
            }
            return process.ExitCode == 0 ? output.Result : null;
        }
        catch (Exception error) when (error is System.ComponentModel.Win32Exception or InvalidOperationException) { return null; }
    }

    // ---- Sizes and space

    /// <summary>Bytes under a folder and the newest change in it, skipping junctions and links. A walk
    /// past <paramref name="limit"/> or into an unreadable folder is partial and has no newest change.</summary>
    internal static (long Bytes, bool Partial, DateTime? Latest) Measure(string path, TimeSpan limit)
    {
        var started = Stopwatch.GetTimestamp();
        var options = new EnumerationOptions { AttributesToSkip = FileAttributes.ReparsePoint, IgnoreInaccessible = false, RecurseSubdirectories = false };
        long bytes = 0;
        var latest = DateTime.MinValue;
        var partial = false;
        var pending = new Stack<DirectoryInfo>([new DirectoryInfo(path)]);
        while (pending.TryPop(out var folder))
        {
            if (Stopwatch.GetElapsedTime(started) > limit) return (bytes, true, null);
            try
            {
                foreach (var entry in folder.EnumerateFileSystemInfos("*", options))
                {
                    if (entry is FileInfo file) bytes += file.Length;
                    else if (entry is DirectoryInfo child) pending.Push(child);
                    if (entry.LastWriteTimeUtc > latest) latest = entry.LastWriteTimeUtc;
                }
            }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException or System.Security.SecurityException) { partial = true; }
        }
        return (bytes, partial, partial || latest == DateTime.MinValue ? null : latest);
    }

    /// <summary>Free and total bytes on the home folder's drive, or null.</summary>
    internal static (long Available, long Total)? Capacity()
    {
        try
        {
            var drive = new DriveInfo(Path.GetPathRoot(Home)!);
            return (drive.AvailableFreeSpace, drive.TotalSize);
        }
        catch (Exception error) when (error is IOException or ArgumentException or UnauthorizedAccessException) { return null; }
    }

    private static readonly string[] HeavyFolderNames = ["node_modules", ".build", "build", "dist", ".next", "target", "Pods", "DerivedData"];

    /// <summary>A workspace directory's size, with its build and dependency folders of 50 MB or more.</summary>
    internal static LiveSession MeasureSession(string title, string path)
    {
        var (bytes, partial, _) = Measure(path, TimeSpan.FromSeconds(10));
        var heavy = HeavyFolderNames
            .Select(name => new DirectoryInfo(Path.Combine(path, name)))
            .Where(folder => folder.Exists && !folder.Attributes.HasFlag(FileAttributes.ReparsePoint))
            .Select(folder => (folder.Name, Measure(folder.FullName, TimeSpan.FromSeconds(3)).Bytes))
            .Where(item => item.Bytes >= 50_000_000)
            .OrderByDescending(item => item.Bytes)
            .ToList();
        return new(title, path, bytes, partial, heavy);
    }

    /// <summary>"1.2 GB", in decimal units like the macOS file byte count.</summary>
    internal static string Bytes(long bytes)
    {
        string[] units = ["bytes", "KB", "MB", "GB", "TB"];
        double value = bytes;
        var unit = 0;
        while (value >= 1000 && unit < units.Length - 1) { value /= 1000; unit++; }
        return unit == 0 ? $"{bytes} bytes" : $"{value.ToString(value >= 100 ? "0" : "0.#", System.Globalization.CultureInfo.CurrentCulture)} {units[unit]}";
    }

    // ---- The socket's JSON

    internal static object ScanJson(List<Worktree> worktrees, List<Cache> caches) => new
    {
        worktrees = worktrees.Select(WorktreeJson),
        total_bytes = worktrees.Sum(worktree => worktree.SizeBytes),
        reclaimable_bytes = worktrees.Where(worktree => worktree.Removable).Sum(worktree => worktree.SizeBytes),
        caches = caches.Select(CacheJson),
        cache_totals = caches.GroupBy(cache => cache.Category).ToDictionary(group => group.Key, group => new
        {
            total_bytes = group.Sum(cache => cache.SizeBytes),
            reclaimable_bytes = group.Where(cache => cache.AutoCleanable && cache.Blocker is null).Sum(cache => cache.SizeBytes),
            size_partial = group.Any(cache => cache.SizePartial),
        }),
    };

    internal static object CleanJson(CleanResult result) => new
    {
        removed = result.Removed.Select(worktree => worktree.Path),
        kept = result.Kept.Select(kept => new { path = kept.Path, blocker = kept.Blocker, message = kept.Message }),
        reclaimed_bytes = result.Removed.Sum(worktree => worktree.SizeBytes),
        dry_run = result.DryRun,
        caches_removed = result.CachesRemoved.Select(CacheJson),
        caches_kept = result.CachesKept.Select(CacheJson),
        caches_reclaimed_bytes = result.CachesRemoved.Sum(cache => cache.SizeBytes),
    };

    private static object WorktreeJson(Worktree worktree) => new
    {
        repo_root = worktree.RepoRoot, path = worktree.Path, branch = worktree.Branch,
        size_bytes = worktree.SizeBytes, size_partial = worktree.SizePartial, last_modified = worktree.LastModified?.ToString("o"),
        programa_created = worktree.ProgramaCreated, dirty = worktree.Facts.Dirty, ignored_env_files = worktree.Facts.IgnoredEnvFiles,
        ignored_files = worktree.Facts.IgnoredFiles, merged = worktree.Facts.Merged, open_in_workspace = worktree.OpenInWorkspace,
        process_running = false, removable = worktree.Removable, blocker = worktree.Blocker,
    };

    private static object CacheJson(Cache cache) => new
    {
        id = cache.Id, category = cache.Category, title = cache.Title, path = cache.Path, size_bytes = cache.SizeBytes,
        size_partial = cache.SizePartial, last_used = cache.LastUsed?.ToString("o"), auto_cleanable = cache.AutoCleanable, blocker = cache.Blocker,
    };
}

/// <summary>The low-disk warning's memory (macOS StorageLowDiskWarningState): one warning when free
/// space drops below the threshold, the next only after it rose above the threshold plus 5 GB.</summary>
internal sealed class LowDiskWarning
{
    private bool _armed = true;

    /// <summary>True when this reading should warn.</summary>
    internal bool Check(long availableBytes, double thresholdGB)
    {
        if (!double.IsFinite(thresholdGB) || thresholdGB <= 0 || availableBytes < 0) return false;
        var freeGB = availableBytes / 1_000_000_000d;
        if (freeGB > thresholdGB + 5) _armed = true;
        else if (freeGB < thresholdGB && _armed)
        {
            _armed = false;
            return true;
        }
        return false;
    }
}
