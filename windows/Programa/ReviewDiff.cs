using System.Diagnostics;
using System.Text;

namespace Programa;

/// <summary>One line of a hunk: ' ' context, '+' addition, '-' deletion, with its line numbers.</summary>
internal sealed record ReviewDiffLine(char Kind, int? Old, int? New, string Text);

internal sealed record ReviewHunk(string Header, List<ReviewDiffLine> Lines);

/// <summary>A changed file. <see cref="Note"/> replaces the hunks of a binary or oversized file.</summary>
internal sealed record ReviewFileDiff(string Path, string? OldPath, string Status, List<ReviewHunk> Hunks, string? Note = null);

internal sealed record ReviewComment(string Id, string FilePath, int Start, int End, string Text, DateTimeOffset CreatedAt, bool IsStale = false);

internal sealed record ReviewSnapshot(string Root, List<ReviewFileDiff> Files);

/// <summary>The diff behind a review panel, as on macOS (docs/plans/diff-review-panel.md): the
/// uncommitted changes (`git diff HEAD` plus untracked files), or the branch against its merge base
/// with a base branch. Pure parsing and serialization, plus the git calls, which block.</summary>
internal static class ReviewDiff
{
    internal const int MaxBytesPerFile = 400_000;

    internal sealed class ReviewException(string code, string message) : Exception(message)
    {
        internal string Code { get; } = code;
    }

    /// <summary>Parses `git diff` unified output.</summary>
    internal static List<ReviewFileDiff> Parse(string unified)
    {
        var files = new List<ReviewFileDiff>();
        string? path = null, oldPath = null, status = "modified";
        List<ReviewHunk> hunks = [];
        ReviewHunk? hunk = null;
        int oldLine = 0, newLine = 0;
        void Flush()
        {
            if (path is not null) files.Add(new ReviewFileDiff(path, oldPath != path ? oldPath : null, status!, hunks));
            path = oldPath = null;
            status = "modified";
            hunks = [];
            hunk = null;
        }
        foreach (var raw in unified.Replace("\r\n", "\n").Split('\n'))
        {
            if (raw.StartsWith("diff --git ", StringComparison.Ordinal))
            {
                Flush();
                // "diff --git a/x b/y": the b/ side, refined by +++ and rename lines below.
                var b = raw.LastIndexOf(" b/", StringComparison.Ordinal);
                path = b >= 0 ? raw[(b + 3)..] : raw[11..];
                oldPath = path;
            }
            else if (hunk is null && raw.StartsWith("new file mode", StringComparison.Ordinal)) status = "added";
            else if (hunk is null && raw.StartsWith("deleted file mode", StringComparison.Ordinal)) status = "deleted";
            else if (hunk is null && raw.StartsWith("rename from ", StringComparison.Ordinal)) { oldPath = raw[12..]; status = "renamed"; }
            else if (hunk is null && raw.StartsWith("rename to ", StringComparison.Ordinal)) path = raw[10..];
            else if (hunk is null && raw.StartsWith("--- ", StringComparison.Ordinal)) { if (raw != "--- /dev/null" && raw.StartsWith("--- a/", StringComparison.Ordinal)) oldPath = raw[6..]; }
            else if (hunk is null && raw.StartsWith("+++ ", StringComparison.Ordinal)) { if (raw.StartsWith("+++ b/", StringComparison.Ordinal)) path = raw[6..]; }
            else if (raw.StartsWith("@@", StringComparison.Ordinal) && path is not null)
            {
                // @@ -old,count +new,count @@ context
                var parts = raw.Split(' ');
                oldLine = int.Parse(parts[1].TrimStart('-').Split(',')[0]);
                newLine = int.Parse(parts[2].TrimStart('+').Split(',')[0]);
                hunk = new ReviewHunk(raw, []);
                hunks.Add(hunk);
            }
            else if (hunk is not null && raw.Length > 0 && raw[0] is ' ' or '+' or '-')
            {
                var kind = raw[0];
                hunk.Lines.Add(new ReviewDiffLine(kind, kind == '+' ? null : oldLine, kind == '-' ? null : newLine, raw[1..]));
                if (kind != '+') oldLine++;
                if (kind != '-') newLine++;
            }
            else if (hunk is not null && raw.Length == 0) { } // the split's trailing empty line
        }
        Flush();
        return files;
    }

    /// <summary>"Code review comments (N):", a blank line, then `path:start-end — text` per comment
    /// in file then line order, each text on one line.</summary>
    internal static string Serialize(IEnumerable<ReviewComment> comments, string? preamble = null)
    {
        var ordered = comments.OrderBy(comment => comment.FilePath, StringComparer.Ordinal).ThenBy(comment => comment.Start).ThenBy(comment => comment.End).ToList();
        var text = new StringBuilder($"{preamble ?? "Code review comments"} ({ordered.Count}):\n\n");
        foreach (var comment in ordered)
        {
            var range = comment.Start == comment.End ? $"{comment.Start}" : $"{comment.Start}-{comment.End}";
            text.Append($"{comment.FilePath}:{range} — {comment.Text.Replace("\r\n", "\n").Replace("\n", " / ")}\n");
        }
        return text.ToString().TrimEnd('\n');
    }

    /// <summary>Whether a comment's file and lines still exist on the new side of the diff.</summary>
    internal static bool Anchored(ReviewComment comment, IReadOnlyList<ReviewFileDiff> files) =>
        files.FirstOrDefault(file => file.Path == comment.FilePath) is { } file
        && file.Hunks.SelectMany(hunk => hunk.Lines).Any(line => line.New >= comment.Start && line.New <= comment.End);

    internal static ReviewSnapshot Snapshot(string directory, string mode, string? baseBranch)
    {
        var (code, output, _) = Git(directory, "rev-parse", "--show-toplevel");
        if (code != 0) throw new ReviewException("unavailable", $"{directory} is not inside a git worktree.");
        var root = Path.GetFullPath(output.Trim().Replace('/', '\\'));
        string range;
        if (mode == "branch")
        {
            var merge = new[] { baseBranch ?? "origin/main", "main", "master" }
                .Select(candidate => Git(root, "merge-base", "HEAD", candidate))
                .FirstOrDefault(result => result.Code == 0);
            if (merge.Output is null) throw new ReviewException("unavailable", $"Unknown base branch {baseBranch ?? "origin/main"}.");
            range = merge.Output.Trim();
        }
        else range = "HEAD";
        var binary = Git(root, "diff", "--numstat", range).Output.Split('\n')
            .Where(line => line.StartsWith("-\t-\t", StringComparison.Ordinal)).Select(line => line[4..].Trim()).ToHashSet();
        var files = Parse(Git(root, "-c", "core.quotepath=off", "diff", "--no-color", "--find-renames", range).Output)
            .Select(file => binary.Contains(file.Path) ? file with { Hunks = [], Note = "binary" }
                : file.Hunks.Sum(hunk => hunk.Lines.Sum(line => line.Text.Length + 1)) > MaxBytesPerFile ? file with { Hunks = [], Note = "too_large" } : file)
            .ToList();
        if (mode != "branch")
        {
            foreach (var relative in Git(root, "-c", "core.quotepath=off", "ls-files", "--others", "--exclude-standard").Output.Split('\n', StringSplitOptions.RemoveEmptyEntries))
                files.Add(Untracked(root, relative.Trim()));
        }
        return new ReviewSnapshot(root, files.OrderBy(file => file.Path, StringComparer.Ordinal).ToList());
    }

    /// <summary>An untracked file as an all-added diff, read directly instead of through git.</summary>
    private static ReviewFileDiff Untracked(string root, string relative)
    {
        var full = Path.Combine(root, relative.Replace('/', '\\'));
        try
        {
            var info = new FileInfo(full);
            if (info.Length > MaxBytesPerFile) return new ReviewFileDiff(relative, null, "added", [], "too_large");
            var bytes = File.ReadAllBytes(full);
            if (bytes.Contains((byte)0)) return new ReviewFileDiff(relative, null, "added", [], "binary");
            var lines = Encoding.UTF8.GetString(bytes).Replace("\r\n", "\n").TrimEnd('\n').Split('\n');
            return new ReviewFileDiff(relative, null, "added", [new ReviewHunk($"@@ -0,0 +1,{lines.Length} @@", lines.Select((line, index) => new ReviewDiffLine('+', null, index + 1, line)).ToList())]);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            return new ReviewFileDiff(relative, null, "added", [], "unreadable");
        }
    }

    private static (int Code, string Output, string Error) Git(string directory, params string[] arguments)
    {
        var start = new ProcessStartInfo("git") { WorkingDirectory = directory, CreateNoWindow = true, UseShellExecute = false, RedirectStandardOutput = true, RedirectStandardError = true, StandardOutputEncoding = Encoding.UTF8 };
        foreach (var argument in arguments) start.ArgumentList.Add(argument);
        try
        {
            using var process = Process.Start(start) ?? throw new ReviewException("unavailable", "git did not start.");
            var error = process.StandardError.ReadToEndAsync();
            var output = process.StandardOutput.ReadToEnd();
            process.WaitForExit();
            return (process.ExitCode, output, error.Result);
        }
        catch (System.ComponentModel.Win32Exception)
        {
            throw new ReviewException("unavailable", "git is not on PATH.");
        }
    }
}
