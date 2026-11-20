namespace Programa;

/// <summary>Git facts the sidebar shows, read from the repository files rather than by running git.</summary>
internal static class GitInfo
{
    /// <summary>The branch checked out in the repository holding <paramref name="directory"/> (a
    /// worktree's own branch for a worktree), the short commit when HEAD is detached, or null
    /// outside a repository.</summary>
    internal static string? Branch(string directory)
    {
        try
        {
            for (var current = new DirectoryInfo(directory); current is not null; current = current.Parent)
            {
                var dotGit = Path.Combine(current.FullName, ".git");
                var gitDirectory = Directory.Exists(dotGit) ? dotGit : File.Exists(dotGit) ? LinkedGitDirectory(dotGit, current.FullName) : null;
                if (gitDirectory is null) continue;
                var head = File.ReadAllText(Path.Combine(gitDirectory, "HEAD")).Trim();
                const string BranchPrefix = "ref: refs/heads/";
                if (head.StartsWith(BranchPrefix, StringComparison.Ordinal)) return head[BranchPrefix.Length..];
                return head.Length >= 7 && !head.StartsWith("ref:", StringComparison.Ordinal) ? head[..7] : null;
            }
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or ArgumentException)
        {
            // An unreadable repository shows no branch.
        }
        return null;
    }

    /// <summary>A worktree or submodule's <c>.git</c> file names its git directory: "gitdir: path".</summary>
    private static string? LinkedGitDirectory(string file, string owner)
    {
        var line = File.ReadAllText(file).Trim();
        const string Prefix = "gitdir:";
        if (!line.StartsWith(Prefix, StringComparison.Ordinal)) return null;
        var path = line[Prefix.Length..].Trim();
        return Path.GetFullPath(Path.IsPathRooted(path) ? path : Path.Combine(owner, path));
    }

    /// <summary>A path under the user's profile as "~\rest", as the macOS sidebar abbreviates home.</summary>
    internal static string AbbreviateHome(string path, string? home = null)
    {
        home ??= Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        if (home.Length == 0 || !path.StartsWith(home, StringComparison.OrdinalIgnoreCase)) return path;
        var rest = path[home.Length..];
        return rest.Length == 0 ? "~" : rest[0] is '\\' or '/' ? "~" + rest : path;
    }
}
