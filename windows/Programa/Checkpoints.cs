using System.Diagnostics;
using System.Text;

namespace Programa;

/// <summary>One saved working tree under refs/programa/checkpoints/&lt;workspace&gt;/&lt;surface&gt;/&lt;seq&gt;.
/// <see cref="Kind"/> is "turn start" or "before revert".</summary>
internal sealed record Checkpoint(string Ref, string Commit, string Tree, string Kind);

/// <summary>Turn checkpoints, as on macOS (Sources/ReviewCheckpointStore.swift): when an agent starts
/// a turn, the repository's files (tracked and untracked, .gitignore respected) are saved as a commit
/// built in a temporary index, so the real index, HEAD and branches are never touched; the review
/// panel can then put the files back as they were. Every call runs git and blocks, one at a time.</summary>
internal static class Checkpoints
{
    internal const string TurnStart = "turn start";
    internal const string BeforeRevert = "before revert";
    private const string RefRoot = "refs/programa/checkpoints";
    private const string SubjectPrefix = "programa checkpoint: ";
    private const int KeepCount = 20;
    private const int MaxChangedPaths = 500;
    private const long MaxUntrackedFileBytes = 10 * 1024 * 1024;
    private static readonly TimeSpan StaleAge = TimeSpan.FromDays(7);
    /// <summary>Git work for checkpoints runs one call at a time, so two saves never race for a sequence number.</summary>
    internal static readonly SemaphoreSlim Gate = new(1, 1);

    internal sealed class CheckpointException(string message) : Exception(message);

    internal static string Prefix(string workspaceId, string surfaceId) => $"{RefRoot}/{workspaceId}/{surfaceId}/";

    internal static string? RepoRoot(string directory)
    {
        if (!Directory.Exists(directory)) return null;
        var (code, output) = Git(directory, ["rev-parse", "--show-toplevel"]);
        return code == 0 ? Path.GetFullPath(output.Trim().Replace('/', '\\')) : null;
    }

    /// <summary>Saves the working tree, unless it equals the newest checkpoint; null when the
    /// directory is not a repository. Throws when the files are over the limits.</summary>
    internal static Checkpoint? Save(string directory, string workspaceId, string surfaceId, string kind)
    {
        if (RepoRoot(directory) is not { } root) return null;
        return SaveIn(root, Prefix(workspaceId, surfaceId), workspaceId, kind);
    }

    private static Checkpoint SaveIn(string root, string prefix, string workspaceId, string kind)
    {
        var existing = List(root, prefix);
        var (headCode, head) = Git(root, ["rev-parse", "--verify", "--quiet", "HEAD^{commit}"]);
        var tree = SnapshotTree(root, headCode == 0);
        if (existing.FirstOrDefault() is { } newest && newest.Tree == tree) return newest;
        var commitArguments = new List<string> { "commit-tree", tree, "-m", SubjectPrefix + kind };
        if (headCode == 0) commitArguments.AddRange(["-p", head.Trim()]);
        var (commitCode, commit) = Git(root, [.. commitArguments], new Dictionary<string, string>
        {
            // A repository without a git identity can still record checkpoints.
            ["GIT_AUTHOR_NAME"] = "Programa", ["GIT_AUTHOR_EMAIL"] = "checkpoints@programa.invalid",
            ["GIT_COMMITTER_NAME"] = "Programa", ["GIT_COMMITTER_EMAIL"] = "checkpoints@programa.invalid",
        });
        if (commitCode != 0) throw new CheckpointException("git commit-tree failed");
        var sequence = (existing.Select(item => Sequence(item.Ref)).DefaultIfEmpty(0).Max()) + 1;
        var reference = prefix + sequence.ToString("D6");
        // The empty old value makes update-ref refuse to overwrite an existing ref.
        if (Git(root, ["update-ref", reference, commit.Trim(), ""]).Code != 0) throw new CheckpointException("git update-ref failed");
        foreach (var old in List(root, prefix).Skip(KeepCount)) Git(root, ["update-ref", "-d", old.Ref]);
        PruneStale(root, workspaceId);
        return new Checkpoint(reference, commit.Trim(), tree, kind);
    }

    /// <summary>The newest checkpoint of a surface, or null.</summary>
    internal static Checkpoint? Newest(string directory, string workspaceId, string surfaceId) =>
        RepoRoot(directory) is { } root ? List(root, Prefix(workspaceId, surfaceId)).FirstOrDefault() : null;

    /// <summary>Puts the files back as the newest checkpoint has them: a turn start (revert) or, after
    /// a revert, the files from before it (undo). The current files are saved first, so a failure
    /// to save changes nothing. Only working-tree files change.</summary>
    internal static void RestoreNewest(string directory, string workspaceId, string surfaceId)
    {
        var root = RepoRoot(directory) ?? throw new CheckpointException(Localizer.Get("ReviewCheckpointNotGit"));
        var prefix = Prefix(workspaceId, surfaceId);
        var target = List(root, prefix).FirstOrDefault() ?? throw new CheckpointException(Localizer.Get("ReviewCheckpointNotFound"));
        // Undoing a revert brings back the turn's start, so the next offer is a revert again.
        var current = SaveIn(root, prefix, workspaceId, target.Kind == BeforeRevert ? TurnStart : BeforeRevert);
        if (current.Tree == target.Tree) return;
        var (code, raw) = Git(root, ["diff-tree", "-r", "-z", "--raw", "--no-renames", "--no-ext-diff", current.Tree, target.Tree]);
        if (code != 0) throw new CheckpointException("git diff-tree failed");
        var fields = raw.Split('\0');
        var deletes = new List<string>();
        var writes = new List<string>();
        for (var index = 0; index + 1 < fields.Length; index += 2)
        {
            var header = fields[index].Split(' ');
            if (header.Length != 5 || !header[0].StartsWith(':')) continue;
            // Submodules and embedded repositories are never touched.
            if (header[0][1..] == "160000" || header[1] == "160000") continue;
            (header[4] == "D" ? deletes : writes).Add(fields[index + 1]);
        }
        // Deletes first, so a path that turns from a directory back into a file is free.
        var undeleted = deletes.Where(path => !RemoveFile(root, path)).ToList();
        if (writes.Count > 0) Checkout(root, target.Tree, writes);
        if (undeleted.Count > 0) throw new CheckpointException($"could not remove {string.Join(", ", undeleted)}");
    }

    /// <summary>Deletes every checkpoint of a closed workspace in this directory's repository.</summary>
    internal static void DeleteWorkspace(string directory, string workspaceId)
    {
        if (RepoRoot(directory) is not { } root) return;
        var (code, refs) = Git(root, ["for-each-ref", "--format=%(refname)", $"{RefRoot}/{workspaceId}/"]);
        if (code != 0) return;
        foreach (var reference in refs.Split('\n', StringSplitOptions.RemoveEmptyEntries)) Git(root, ["update-ref", "-d", reference.Trim()]);
    }

    private static List<Checkpoint> List(string root, string prefix)
    {
        var (code, records) = Git(root, ["for-each-ref", "--sort=-refname", "--format=%(refname)%00%(objectname)%00%(tree)%00%(contents:subject)", prefix]);
        if (code != 0) return [];
        return records.Split('\n', StringSplitOptions.RemoveEmptyEntries)
            .Select(line => line.Split('\0'))
            .Where(fields => fields.Length == 4 && Sequence(fields[0]) > 0)
            .Select(fields => new Checkpoint(fields[0], fields[1], fields[2], fields[3].StartsWith(SubjectPrefix, StringComparison.Ordinal) ? fields[3][SubjectPrefix.Length..] : TurnStart))
            .ToList();
    }

    private static int Sequence(string reference) =>
        reference.Split('/')[^1] is { Length: 6 } last && int.TryParse(last, out var number) ? number : 0;

    /// <summary>Other workspaces' checkpoints older than a week: a workspace closed while Programa
    /// was not running never deletes its own.</summary>
    private static void PruneStale(string root, string workspaceId)
    {
        var (code, records) = Git(root, ["for-each-ref", "--format=%(refname)%00%(committerdate:unix)", $"{RefRoot}/"]);
        if (code != 0) return;
        var cutoff = DateTimeOffset.UtcNow.Subtract(StaleAge).ToUnixTimeSeconds();
        foreach (var fields in records.Split('\n', StringSplitOptions.RemoveEmptyEntries).Select(line => line.Split('\0')))
            if (fields.Length == 2 && !fields[0].StartsWith($"{RefRoot}/{workspaceId}/", StringComparison.Ordinal) && long.TryParse(fields[1], out var time) && time < cutoff)
                Git(root, ["update-ref", "-d", fields[0]]);
    }

    /// <summary>The working tree as a tree object, through a temporary index seeded from the real one.</summary>
    private static string SnapshotTree(string root, bool hasHead)
    {
        var (statusCode, status) = Git(root, ["status", "--porcelain", "-z", "--untracked-files=all"]);
        if (statusCode != 0) throw new CheckpointException("git status failed");
        if (status.Split('\0', StringSplitOptions.RemoveEmptyEntries).Length > MaxChangedPaths) throw new CheckpointException(Localizer.Get("ReviewCheckpointTooLarge"));
        var (_, untracked) = Git(root, ["ls-files", "-z", "--others", "--exclude-standard"]);
        foreach (var path in untracked.Split('\0', StringSplitOptions.RemoveEmptyEntries))
        {
            var info = new FileInfo(Path.Combine(root, path.Replace('/', '\\')));
            if (info.Exists && info.Length > MaxUntrackedFileBytes) throw new CheckpointException(Localizer.Get("ReviewCheckpointTooLarge"));
        }
        var scratch = Directory.CreateTempSubdirectory("programa-checkpoint-").FullName;
        try
        {
            var index = Path.Combine(scratch, "index");
            var environment = new Dictionary<string, string> { ["GIT_INDEX_FILE"] = index };
            var (_, realIndex) = Git(root, ["rev-parse", "--git-path", "index"]);
            var realPath = Path.IsPathRooted(realIndex.Trim()) ? realIndex.Trim() : Path.Combine(root, realIndex.Trim());
            var seeded = false;
            try { if (File.Exists(realPath)) { File.Copy(realPath, index); seeded = true; } } catch (IOException) { }
            if (!seeded && hasHead && Git(root, ["read-tree", "HEAD"], environment).Code != 0) throw new CheckpointException("git read-tree failed");
            if (Git(root, ["add", "-A"], environment).Code != 0) throw new CheckpointException("git add failed");
            var (treeCode, tree) = Git(root, ["write-tree"], environment);
            if (treeCode != 0) throw new CheckpointException("git write-tree failed");
            return tree.Trim();
        }
        finally
        {
            try { Directory.Delete(scratch, recursive: true); } catch (IOException) { }
        }
    }

    /// <summary>`git checkout &lt;tree&gt; -- paths` through a throwaway index, so files are written with
    /// the repository's checkout rules while the real index stays as it is.</summary>
    private static void Checkout(string root, string tree, List<string> paths)
    {
        var scratch = Directory.CreateTempSubdirectory("programa-checkpoint-").FullName;
        try
        {
            var list = Path.Combine(scratch, "paths");
            File.WriteAllText(list, string.Join('\0', paths), new UTF8Encoding(false));
            var (code, _) = Git(root, ["--literal-pathspecs", "checkout", tree, $"--pathspec-from-file={list}", "--pathspec-file-nul"],
                new Dictionary<string, string> { ["GIT_INDEX_FILE"] = Path.Combine(scratch, "index") });
            if (code != 0) throw new CheckpointException("git checkout failed");
        }
        finally
        {
            try { Directory.Delete(scratch, recursive: true); } catch (IOException) { }
        }
    }

    /// <summary>Removes a file the checkpoint does not have, then the parent folders it leaves empty.
    /// False when it is still there; a missing file is success.</summary>
    private static bool RemoveFile(string root, string path)
    {
        var full = Path.Combine(root, path.Replace('/', '\\'));
        if (Directory.Exists(full)) return false;
        if (!File.Exists(full)) return true;
        try { File.Delete(full); }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { return false; }
        for (var parent = Path.GetDirectoryName(full); parent is not null && parent.Length > root.Length && !Directory.EnumerateFileSystemEntries(parent).Any(); parent = Path.GetDirectoryName(parent))
            Directory.Delete(parent);
        return true;
    }

    private static (int Code, string Output) Git(string directory, string[] arguments, Dictionary<string, string>? environment = null)
    {
        // Hooks never run for checkpoint work (checkout would run post-checkout).
        var start = new ProcessStartInfo("git") { WorkingDirectory = directory, CreateNoWindow = true, UseShellExecute = false, RedirectStandardOutput = true, RedirectStandardError = true, StandardOutputEncoding = Encoding.UTF8 };
        foreach (var argument in new[] { "-c", "core.hooksPath=" + Path.Combine(Path.GetTempPath(), "programa-no-hooks"), "-c", "core.quotePath=false" }.Concat(arguments))
            start.ArgumentList.Add(argument);
        foreach (var (key, value) in environment ?? []) start.Environment[key] = value;
        try
        {
            using var process = Process.Start(start)!;
            var error = process.StandardError.ReadToEndAsync();
            var output = process.StandardOutput.ReadToEnd();
            process.WaitForExit();
            _ = error.Result;
            return (process.ExitCode, output);
        }
        catch (System.ComponentModel.Win32Exception)
        {
            throw new CheckpointException("git is not on PATH.");
        }
    }
}
