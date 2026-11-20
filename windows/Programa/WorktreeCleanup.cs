using System.Diagnostics;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace Programa;

/// <summary>The worktree settings in settings.json, shared with macOS (docs/settings-json.md#worktrees).</summary>
internal sealed record WorktreeSettings(string Directory, bool AutoRemoveMerged, double AutoRemoveAfterHours)
{
    internal static WorktreeSettings Load()
    {
        var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        var fallback = new WorktreeSettings(Path.Combine(home, ".programa", "worktrees"), true, 24);
        try
        {
            if (!File.Exists(ShortcutSettings.SettingsPath)) return fallback;
            var root = JsonNode.Parse(File.ReadAllText(ShortcutSettings.SettingsPath), null, new JsonDocumentOptions { CommentHandling = JsonCommentHandling.Skip, AllowTrailingCommas = true });
            if (root?["worktrees"] is not JsonObject worktrees) return fallback;
            var directory = worktrees["directory"] is JsonValue folder && folder.TryGetValue<string>(out var text) && text.Length > 0
                ? Path.GetFullPath(text.StartsWith('~') ? Path.Combine(home, text.TrimStart('~', '/', '\\')) : text)
                : fallback.Directory;
            var remove = worktrees["autoRemoveMerged"] is JsonValue flag && flag.TryGetValue<bool>(out var on) ? on : true;
            var hours = worktrees["autoRemoveAfterHours"] is JsonValue number && number.TryGetValue<double>(out var value) ? Math.Max(1, value) : 24;
            return new WorktreeSettings(directory, remove, hours);
        }
        catch (Exception error) when (error is JsonException or IOException or UnauthorizedAccessException or InvalidOperationException)
        {
            return fallback;
        }
    }
}

/// <summary>Removing merged worktrees, as on macOS (docs/socket-api.md, storage.*): every 6 hours, a
/// linked worktree under the worktrees folder goes when its branch is merged into the remote default
/// branch (or, clean, its upstream is gone), it has no changes, holds no ignored .env* file outside
/// node_modules and no other ignored file outside rebuildable folders, no workspace is open on it,
/// and it was not used for the idle period. `git worktree remove` without --force; branches stay.
/// Windows refuses to delete a folder a process works in, which covers "a process runs inside".</summary>
internal static class WorktreeCleanup
{
    private static readonly HashSet<string> Rebuildable = new(StringComparer.OrdinalIgnoreCase)
    {
        "node_modules", ".build", "build", "dist", ".next", ".nuxt", ".turbo", ".cache", "target", "Pods", "DerivedData", ".gradle", "coverage", "__pycache__", ".venv", "venv",
    };

    /// <summary>Removes every removable worktree under <paramref name="folder"/>; returns the removed paths.</summary>
    internal static List<string> Run(string folder, IReadOnlyCollection<string> open, TimeSpan idle)
    {
        var removed = new List<string>();
        if (!Directory.Exists(folder)) return removed;
        // <folder>\<repo>\<branch-slug>, as worktree.create lays them out.
        foreach (var worktree in Directory.EnumerateDirectories(folder).SelectMany(Directory.EnumerateDirectories))
        {
            if (Blocker(worktree, open, idle) is not null) continue;
            if (MainWorktree(worktree) is not { } main || Worktrees.SamePath(main, worktree)) continue;
            if (Remove(main, worktree) is null) removed.Add(worktree);
        }
        return removed;
    }

    /// <summary>The main worktree of the repository <paramref name="worktree"/> belongs to.</summary>
    internal static string? MainWorktree(string worktree)
    {
        var (code, list) = Git(worktree, "worktree", "list", "--porcelain");
        return code == 0 ? Worktrees.ParsePorcelain(list).FirstOrDefault()?.Path : null;
    }

    /// <summary>`git worktree remove` without --force; null when it went, else git's message.</summary>
    internal static string? Remove(string main, string worktree)
    {
        var (code, _, error) = GitWithError(main, "worktree", "remove", worktree);
        return code == 0 ? null : error.Trim();
    }

    /// <summary>The background monitor's blocker (it also keeps ignored_files): status_unknown, dirty,
    /// env_files, ignored_files, not_merged, open_in_workspace or recently_used.</summary>
    internal static string? Blocker(string worktree, IReadOnlyCollection<string> open, TimeSpan idle) =>
        Blocker(worktree, Facts(worktree), external: false, open, idle, monitor: true);

    /// <summary>What git says about a worktree; null where git could not tell.</summary>
    internal sealed record WorktreeFacts(bool? Dirty, bool? IgnoredEnvFiles, bool? IgnoredFiles, bool? Merged);

    internal static WorktreeFacts Facts(string worktree)
    {
        // Only linked worktrees: their .git is a file pointing at the main repository.
        if (!File.Exists(Path.Combine(worktree, ".git"))) return new(null, null, null, null);
        var (statusCode, status) = Git(worktree, "status", "--porcelain");
        bool? dirty = statusCode == 0 ? status.Trim().Length > 0 : null;
        var (ignoredCode, ignored) = Git(worktree, "ls-files", "-z", "--others", "--ignored", "--exclude-standard", "--directory");
        if (ignoredCode != 0) return new(dirty, null, null, IsMerged(worktree));
        var (env, other) = IgnoredKinds(worktree, ignored.Split('\0', StringSplitOptions.RemoveEmptyEntries));
        return new(dirty, env, other, IsMerged(worktree));
    }

    /// <summary>Why a worktree stays, or null when it can go, checked in the macOS order (docs/socket-api.md,
    /// storage.*). <paramref name="idle"/> null skips recently_used; only the monitor keeps ignored_files.</summary>
    internal static string? Blocker(string worktree, WorktreeFacts facts, bool external, IReadOnlyCollection<string> open, TimeSpan? idle, bool monitor)
    {
        if (external) return "external";
        if (facts.Dirty is null || facts.IgnoredEnvFiles is null || facts.Merged is null) return "status_unknown";
        if (facts.Dirty == true) return "dirty";
        if (facts.IgnoredEnvFiles == true) return "env_files";
        if (monitor && facts.IgnoredFiles == true) return "ignored_files";
        if (facts.Merged != true) return "not_merged";
        if (open.Any(directory => Worktrees.Contains(worktree, directory))) return "open_in_workspace";
        if (idle is { } wait && RecentlyUsed(worktree, wait)) return "recently_used";
        return null;
    }

    /// <summary>env_files for a .env* file outside node_modules (inside an ignored folder too),
    /// ignored_files for anything else ignored outside rebuildable folders.</summary>
    internal static string? IgnoredBlocker(string worktree, IEnumerable<string> entries) =>
        IgnoredKinds(worktree, entries) switch { (true, _) => "env_files", (_, true) => "ignored_files", _ => null };

    /// <summary>Whether the ignored entries hold a .env* file, and anything else outside rebuildable folders.</summary>
    internal static (bool Env, bool Other) IgnoredKinds(string worktree, IEnumerable<string> entries)
    {
        bool env = false, other = false;
        foreach (var entry in entries)
        {
            var segments = entry.TrimEnd('/').Split('/');
            if (segments.Contains("node_modules", StringComparer.OrdinalIgnoreCase)) continue;
            var rebuildable = segments.Any(Rebuildable.Contains);
            if (entry.EndsWith('/'))
            {
                env |= !env && HasEnvFile(Path.Combine(worktree, entry.TrimEnd('/').Replace('/', '\\')));
                other |= !rebuildable;
            }
            else if (segments[^1].StartsWith(".env", StringComparison.OrdinalIgnoreCase)) env = true;
            else other |= !rebuildable;
        }
        return (env, other);
    }

    private static bool HasEnvFile(string folder)
    {
        try
        {
            var pending = new Stack<string>([folder]);
            while (pending.TryPop(out var current))
            {
                if (Directory.EnumerateFiles(current, ".env*").Any()) return true;
                foreach (var child in Directory.EnumerateDirectories(current))
                    if (!string.Equals(Path.GetFileName(child), "node_modules", StringComparison.OrdinalIgnoreCase)) pending.Push(child);
            }
            return false;
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            return true; // unreadable: keep it
        }
    }

    /// <summary>HEAD is in the remote default branch (origin/HEAD, else origin/main, else
    /// origin/master, as last fetched), or the branch's upstream was deleted.</summary>
    private static bool IsMerged(string worktree)
    {
        var (headCode, defaultBranch) = Git(worktree, "rev-parse", "--abbrev-ref", "origin/HEAD");
        var candidates = headCode == 0 ? [defaultBranch.Trim()] : new[] { "origin/main", "origin/master" };
        var target = candidates.FirstOrDefault(name => Git(worktree, "rev-parse", "--verify", "--quiet", name).Code == 0);
        if (target is not null && Git(worktree, "merge-base", "--is-ancestor", "HEAD", target).Code == 0) return true;
        var (branchCode, branch) = Git(worktree, "symbolic-ref", "--short", "HEAD");
        if (branchCode != 0) return false;
        var (_, track) = Git(worktree, "for-each-ref", "--format=%(upstream:track)", $"refs/heads/{branch.Trim()}");
        return track.Contains("[gone]", StringComparison.Ordinal);
    }

    /// <summary>The worktree's git index, HEAD or HEAD log changed within the idle period, or cannot be read.</summary>
    private static bool RecentlyUsed(string worktree, TimeSpan idle) =>
        LastUsed(worktree) is not { } used || used > DateTime.UtcNow - idle;

    /// <summary>When the worktree's git index, HEAD or HEAD log last changed (UTC), or null if unreadable.</summary>
    internal static DateTime? LastUsed(string worktree)
    {
        var (code, gitDir) = Git(worktree, "rev-parse", "--git-dir");
        if (code != 0) return null;
        var folder = Path.IsPathRooted(gitDir.Trim()) ? gitDir.Trim() : Path.Combine(worktree, gitDir.Trim());
        try
        {
            return new[] { "index", "HEAD", Path.Combine("logs", "HEAD") }
                .Select(name => new FileInfo(Path.Combine(folder, name)))
                .Where(file => file.Exists)
                .Select(file => (DateTime?)file.LastWriteTimeUtc)
                .Max();
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            return null;
        }
    }

    internal static (int Code, string Output) Git(string directory, params string[] arguments)
    {
        var (code, output, _) = GitWithError(directory, arguments);
        return (code, output);
    }

    private static (int Code, string Output, string Error) GitWithError(string directory, params string[] arguments)
    {
        var start = new ProcessStartInfo("git") { WorkingDirectory = directory, CreateNoWindow = true, UseShellExecute = false, RedirectStandardOutput = true, RedirectStandardError = true, StandardOutputEncoding = Encoding.UTF8 };
        foreach (var argument in new[] { "-c", "core.quotePath=false" }.Concat(arguments)) start.ArgumentList.Add(argument);
        try
        {
            using var process = Process.Start(start)!;
            var error = process.StandardError.ReadToEndAsync();
            var output = process.StandardOutput.ReadToEnd();
            process.WaitForExit();
            return (process.ExitCode, output, error.Result);
        }
        catch (System.ComponentModel.Win32Exception)
        {
            return (-1, string.Empty, "git is not on PATH.");
        }
    }
}
