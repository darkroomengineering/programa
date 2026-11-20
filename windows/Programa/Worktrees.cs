using System.Diagnostics;
using System.Text;

namespace Programa;

internal sealed record WorktreeEntry(string Path, string? Branch, string Head);

/// <summary>The git side of `worktree.*`, as on macOS (Sources/GitWorktreeManager.swift): a branch
/// gets its own worktree, by default at %USERPROFILE%\.programa\worktrees\&lt;repo&gt;\&lt;branch-slug&gt;.
/// Every call runs git and blocks, so callers stay off the UI thread.</summary>
internal static class Worktrees
{
    internal sealed class GitException(string code, string message) : Exception(message)
    {
        internal string Code { get; } = code;
    }

    /// <summary>`feature/foo` becomes `feature-foo`.</summary>
    internal static string BranchSlug(string branch)
    {
        var slug = new string(branch.Select(c => char.IsAsciiLetterOrDigit(c) || c is '-' or '_' or '.' ? c : '-').ToArray());
        return slug.Length == 0 ? "worktree" : slug;
    }

    internal static string DefaultPath(string repoRoot, string branch) =>
        System.IO.Path.Combine(WorktreeSettings.Load().Directory, System.IO.Path.GetFileName(repoRoot), BranchSlug(branch));

    internal static string RepoRoot(string directory)
    {
        if (!Directory.Exists(directory)) throw new GitException("not_a_git_repo", $"{directory} does not exist.");
        var (code, output, _) = Git(directory, "rev-parse", "--show-toplevel");
        if (code != 0) throw new GitException("not_a_git_repo", $"{directory} is not inside a git repository.");
        return Normalize(output.Trim());
    }

    /// <summary>Parses `git worktree list --porcelain`.</summary>
    internal static List<WorktreeEntry> List(string repoRoot)
    {
        var (code, output, error) = Git(repoRoot, "worktree", "list", "--porcelain");
        if (code != 0) throw new GitException("git_command_failed", error.Trim());
        return ParsePorcelain(output);
    }

    internal static List<WorktreeEntry> ParsePorcelain(string output)
    {
        var entries = new List<WorktreeEntry>();
        foreach (var block in output.Replace("\r\n", "\n").Split("\n\n", StringSplitOptions.RemoveEmptyEntries))
        {
            string? path = null, branch = null, head = string.Empty;
            foreach (var line in block.Split('\n'))
            {
                if (line.StartsWith("worktree ", StringComparison.Ordinal)) path = Normalize(line[9..]);
                else if (line.StartsWith("HEAD ", StringComparison.Ordinal)) head = line[5..];
                else if (line.StartsWith("branch refs/heads/", StringComparison.Ordinal)) branch = line[18..];
            }
            if (path is not null) entries.Add(new WorktreeEntry(path, branch, head));
        }
        return entries;
    }

    internal static WorktreeEntry Create(string repoRoot, string branch, string? baseRef, string? path)
    {
        var entries = List(repoRoot);
        if (entries.Any(entry => entry.Branch == branch))
            throw new GitException("branch_checked_out", $"{branch} is already checked out in {entries.First(entry => entry.Branch == branch).Path}.");
        var target = Normalize(path ?? DefaultPath(repoRoot, branch));
        if (Directory.Exists(target) || File.Exists(target)) throw new GitException("worktree_path_exists", $"{target} already exists.");
        Directory.CreateDirectory(System.IO.Path.GetDirectoryName(target)!);
        var exists = Git(repoRoot, "show-ref", "--verify", "--quiet", $"refs/heads/{branch}").Code == 0;
        var (code, _, error) = exists
            ? Git(repoRoot, "worktree", "add", target, branch)
            : Git(repoRoot, "worktree", "add", "-b", branch, target, baseRef ?? "HEAD");
        if (code != 0) throw new GitException("git_command_failed", error.Trim());
        return List(repoRoot).FirstOrDefault(entry => SamePath(entry.Path, target)) ?? new WorktreeEntry(target, branch, string.Empty);
    }

    internal static bool IsDirty(string path) =>
        Directory.Exists(path) && Git(path, "status", "--porcelain").Output.Trim().Length > 0;

    /// <summary>Removes the worktree, never its branch. A worktree with changes needs <paramref name="force"/>.</summary>
    internal static void Remove(string repoRoot, WorktreeEntry entry, bool force)
    {
        if (!force && IsDirty(entry.Path))
            throw new GitException("worktree_dirty", $"{entry.Path} has uncommitted changes; pass force to remove it anyway.");
        // A shell that just closed can hold the directory open for a moment on Windows.
        // git then deregisters it but leaves the empty folder, which goes once the shell has exited.
        for (var attempt = 0; ; attempt++)
        {
            int code;
            string error;
            if (List(repoRoot).Any(item => SamePath(item.Path, entry.Path)))
            {
                (code, _, error) = force ? Git(repoRoot, "worktree", "remove", "--force", entry.Path) : Git(repoRoot, "worktree", "remove", entry.Path);
            }
            else
            {
                code = TryDeleteEmpty(entry.Path) ? 0 : 1;
                error = $"{entry.Path} is still in use.";
            }
            if (code == 0 && !Directory.Exists(entry.Path)) return;
            if (attempt == 10) throw new GitException("git_command_failed", error.Trim());
            Thread.Sleep(300);
        }
    }

    private static bool TryDeleteEmpty(string path)
    {
        try
        {
            if (Directory.Exists(path)) Directory.Delete(path, recursive: false);
            return true;
        }
        catch (IOException) { return false; }
        catch (UnauthorizedAccessException) { return false; }
    }

    internal static WorktreeEntry Find(string repoRoot, string? path, string? branch) =>
        List(repoRoot).FirstOrDefault(entry => path is not null ? SamePath(entry.Path, Normalize(path)) : entry.Branch == branch)
            ?? throw new GitException("worktree_not_found", $"No worktree for {path ?? branch} in {repoRoot}.");

    /// <summary>Whether <paramref name="directory"/> is <paramref name="root"/> or inside it.</summary>
    internal static bool Contains(string root, string? directory)
    {
        if (directory is null) return false;
        var normalized = Normalize(directory);
        return SamePath(normalized, root) || normalized.StartsWith(root.TrimEnd('\\') + "\\", StringComparison.OrdinalIgnoreCase);
    }

    internal static bool SamePath(string a, string b) => string.Equals(a.TrimEnd('\\'), b.TrimEnd('\\'), StringComparison.OrdinalIgnoreCase);

    /// <summary>git prints C:/x/y; Windows paths are C:\x\y.</summary>
    private static string Normalize(string path) => System.IO.Path.GetFullPath(path.Replace('/', '\\'));

    private static (int Code, string Output, string Error) Git(string directory, params string[] arguments)
    {
        var start = new ProcessStartInfo("git") { WorkingDirectory = directory, CreateNoWindow = true, UseShellExecute = false, RedirectStandardOutput = true, RedirectStandardError = true, StandardOutputEncoding = Encoding.UTF8 };
        foreach (var argument in arguments) start.ArgumentList.Add(argument);
        try
        {
            using var process = Process.Start(start) ?? throw new GitException("git_command_failed", "git did not start.");
            var error = process.StandardError.ReadToEndAsync();
            var output = process.StandardOutput.ReadToEnd();
            process.WaitForExit();
            return (process.ExitCode, output, error.Result);
        }
        catch (System.ComponentModel.Win32Exception)
        {
            throw new GitException("git_command_failed", "git is not on PATH.");
        }
    }
}
