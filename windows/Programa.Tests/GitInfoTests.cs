using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace Programa.Tests;

[TestClass]
public sealed class GitInfoTests
{
    [TestMethod]
    public void BranchComesFromTheNearestRepository()
    {
        var root = Directory.CreateTempSubdirectory("programa-git-").FullName;
        try
        {
            var repository = Directory.CreateDirectory(Path.Combine(root, "repo", ".git")).FullName;
            File.WriteAllText(Path.Combine(repository, "HEAD"), "ref: refs/heads/feature/sidebar\n");
            var nested = Directory.CreateDirectory(Path.Combine(root, "repo", "src", "app")).FullName;
            Assert.AreEqual("feature/sidebar", GitInfo.Branch(nested));

            // A worktree's .git is a file naming its git directory.
            var worktreeGit = Directory.CreateDirectory(Path.Combine(root, "repo", ".git", "worktrees", "wt")).FullName;
            File.WriteAllText(Path.Combine(worktreeGit, "HEAD"), "0123456789abcdef0123456789abcdef01234567\n");
            var worktree = Directory.CreateDirectory(Path.Combine(root, "wt")).FullName;
            File.WriteAllText(Path.Combine(worktree, ".git"), "gitdir: ../repo/.git/worktrees/wt\n");
            Assert.AreEqual("0123456", GitInfo.Branch(worktree));

            Assert.IsNull(GitInfo.Branch(Directory.CreateDirectory(Path.Combine(root, "plain")).FullName));
        }
        finally
        {
            Directory.Delete(root, recursive: true);
        }
    }

    [TestMethod]
    public void HomeIsAbbreviated()
    {
        Assert.AreEqual(@"~\Desktop\app", GitInfo.AbbreviateHome(@"C:\Users\me\Desktop\app", @"C:\Users\me"));
        Assert.AreEqual("~", GitInfo.AbbreviateHome(@"C:\Users\me", @"C:\Users\me"));
        Assert.AreEqual(@"C:\Users\meadow", GitInfo.AbbreviateHome(@"C:\Users\meadow", @"C:\Users\me"));
    }
}

[TestClass]
public sealed class ProcessTreeTests
{
    [TestMethod]
    public void FindsTheChildrenOfAShell()
    {
        using var child = System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo("cmd.exe", "/c ping -n 5 127.0.0.1 >nul") { CreateNoWindow = true, UseShellExecute = false })!;
        try
        {
            var self = (uint)Environment.ProcessId;
            var children = ProcessTree.ChildrenOf(new HashSet<uint> { self });
            CollectionAssert.Contains(children[self], "cmd.exe");
            Assert.AreEqual(0, ProcessTree.ChildrenOf(new HashSet<uint> { (uint)child.Id + 1_000_000 }).Count);
        }
        finally
        {
            child.Kill(entireProcessTree: true);
        }
    }

    [TestMethod]
    public void AListenerBelongsToTheNearestShellAboveIt()
    {
        var processes = new Dictionary<uint, ProcessTree.ProcessInfo>
        {
            [10] = new(1, "pwsh.exe"),
            [11] = new(10, "node.exe"),
            [12] = new(11, "node.exe"),
            [20] = new(21, "a.exe"),
            [21] = new(20, "b.exe"), // a parent cycle from pid reuse
        };
        var shells = new HashSet<uint> { 10 };
        Assert.AreEqual(10u, ProcessTree.OwningShell(12, processes, shells));
        Assert.AreEqual(10u, ProcessTree.OwningShell(10, processes, shells));
        Assert.AreEqual(0u, ProcessTree.OwningShell(20, processes, shells));
        Assert.AreEqual(0u, ProcessTree.OwningShell(99, processes, shells));
    }

    [TestMethod]
    public void ListeningPortsIncludeOurOwnListener()
    {
        var listener = new System.Net.Sockets.TcpListener(System.Net.IPAddress.Loopback, 0);
        listener.Start();
        try
        {
            var port = ((System.Net.IPEndPoint)listener.LocalEndpoint).Port;
            CollectionAssert.Contains(ProcessTree.ListeningPorts(), (port, (uint)Environment.ProcessId));
        }
        finally
        {
            listener.Stop();
        }
    }
}

[TestClass]
public sealed class PullRequestTests
{
    [TestMethod]
    public void AnOpenPullRequestWinsThenTheLatest()
    {
        var json = """
            [{"number":1,"state":"MERGED","url":"https://x/1","updatedAt":"2026-11-02T00:00:00Z"},
             {"number":2,"state":"OPEN","url":"https://x/2","updatedAt":"2026-10-01T00:00:00Z"},
             {"number":3,"state":"CLOSED","url":"https://x/3","updatedAt":"2026-11-03T00:00:00Z"}]
            """;
        Assert.AreEqual(new PullRequestInfo(2, "open", "https://x/2"), PullRequests.Preferred(json));
        Assert.AreEqual(new PullRequestInfo(1, "merged", "https://x/1"), PullRequests.Preferred("""[{"number":1,"state":"MERGED","url":"https://x/1","updatedAt":"2026-11-02T00:00:00Z"},{"number":3,"state":"CLOSED","url":"https://x/3","updatedAt":"2026-11-03T00:00:00Z"}]"""));
        Assert.IsNull(PullRequests.Preferred("[]"));
    }
}

[TestClass]
public sealed class WorktreeTests
{
    [TestMethod]
    public void PorcelainListsPathsBranchesAndDetachedHeads()
    {
        var entries = Worktrees.ParsePorcelain("worktree C:/src/app\nHEAD 1111\nbranch refs/heads/main\n\nworktree C:/Users/me/.programa/worktrees/app/feature-x\nHEAD 2222\nbranch refs/heads/feature/x\n\nworktree C:/tmp/detached\nHEAD 3333\ndetached\n\n");
        CollectionAssert.AreEqual(new[] { @"C:\src\app", @"C:\Users\me\.programa\worktrees\app\feature-x", @"C:\tmp\detached" }, entries.Select(entry => entry.Path).ToArray());
        CollectionAssert.AreEqual(new[] { "main", "feature/x", null }, entries.Select(entry => entry.Branch).ToArray());
        Assert.AreEqual("feature-x", Worktrees.BranchSlug("feature/x"));
        Assert.IsTrue(Worktrees.Contains(@"C:\src\app", @"C:\src\app\sub"));
        Assert.IsFalse(Worktrees.Contains(@"C:\src\app", @"C:\src\application"));
    }

    [TestMethod]
    public void CreatesListsAndRemovesAWorktree()
    {
        var root = Directory.CreateTempSubdirectory("programa-wt-").FullName;
        try
        {
            var repo = Path.Combine(root, "repo");
            Directory.CreateDirectory(repo);
            foreach (var args in new[] { "init -q -b main", "-c user.email=t@t -c user.name=t commit -q --allow-empty -m init" })
                System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo("git", args) { WorkingDirectory = repo, CreateNoWindow = true })!.WaitForExit();
            var target = Path.Combine(root, "wt");
            var created = Worktrees.Create(Worktrees.RepoRoot(repo), "feature/x", null, target);
            Assert.AreEqual("feature/x", created.Branch);
            Assert.AreEqual(2, Worktrees.List(repo).Count);
            Assert.AreEqual("branch_checked_out", Assert.ThrowsExactly<Worktrees.GitException>(() => Worktrees.Create(repo, "feature/x", null, null)).Code);
            File.WriteAllText(Path.Combine(target, "new.txt"), "x");
            Assert.AreEqual("worktree_dirty", Assert.ThrowsExactly<Worktrees.GitException>(() => Worktrees.Remove(repo, created, force: false)).Code);
            Worktrees.Remove(repo, created, force: true);
            Assert.AreEqual(1, Worktrees.List(repo).Count);
        }
        finally
        {
            foreach (var file in Directory.EnumerateFiles(root, "*", SearchOption.AllDirectories)) File.SetAttributes(file, FileAttributes.Normal);
            Directory.Delete(root, recursive: true);
        }
    }
}

[TestClass]
public sealed class WorktreeCleanupTests
{
    [TestMethod]
    public void OnlyMergedCleanIdleClosedWorktreesAreRemoved()
    {
        var root = Directory.CreateTempSubdirectory("programa-cleanup-").FullName;
        try
        {
            var origin = Path.Combine(root, "origin.git");
            var repo = Path.Combine(root, "repo");
            Git(root, $"init -q --bare -b main \"{origin}\"");
            Git(root, $"clone -q \"{origin}\" \"{repo}\"");
            File.WriteAllText(Path.Combine(repo, ".gitignore"), "*.local\nbuild/\n");
            Git(repo, "add -A");
            Git(repo, "-c user.email=t@t -c user.name=t commit -q -m init");
            Git(repo, "push -q origin main");
            var folder = Path.Combine(root, "worktrees");
            string Add(string branch)
            {
                var path = Path.Combine(folder, "repo", branch);
                Git(repo, $"worktree add -q -b {branch} \"{path}\"");
                return path;
            }
            var merged = Add("merged");
            var dirty = Add("dirty");
            File.WriteAllText(Path.Combine(dirty, "new.txt"), "x");
            var ahead = Add("ahead");
            File.WriteAllText(Path.Combine(ahead, "work.txt"), "x");
            Git(ahead, "add -A");
            Git(ahead, "-c user.email=t@t -c user.name=t commit -q -m work");
            var secrets = Add("secrets");
            Directory.CreateDirectory(Path.Combine(secrets, "build"));
            File.WriteAllText(Path.Combine(secrets, "build", ".env.local"), "KEY=1");
            var local = Add("local");
            File.WriteAllText(Path.Combine(local, "db.local"), "data");
            var open = Add("open");

            var none = TimeSpan.Zero;
            Assert.AreEqual("recently_used", WorktreeCleanup.Blocker(merged, [], TimeSpan.FromHours(24)));
            Assert.AreEqual("dirty", WorktreeCleanup.Blocker(dirty, [], none));
            Assert.AreEqual("not_merged", WorktreeCleanup.Blocker(ahead, [], none));
            Assert.AreEqual("env_files", WorktreeCleanup.Blocker(secrets, [], none));
            Assert.AreEqual("ignored_files", WorktreeCleanup.Blocker(local, [], none));
            Assert.AreEqual("open_in_workspace", WorktreeCleanup.Blocker(open, [Path.Combine(open, "src")], none));

            var removed = WorktreeCleanup.Run(folder, [open], none);
            CollectionAssert.AreEqual(new[] { merged }, removed);
            Assert.IsFalse(Directory.Exists(merged));
            // The branch stays.
            Assert.AreEqual(0, GitCode(repo, "rev-parse --verify --quiet refs/heads/merged"));
        }
        finally
        {
            foreach (var file in Directory.EnumerateFiles(root, "*", SearchOption.AllDirectories)) File.SetAttributes(file, FileAttributes.Normal);
            Directory.Delete(root, recursive: true);
        }
    }

    private static void Git(string directory, string arguments) => GitCode(directory, arguments);

    private static int GitCode(string directory, string arguments)
    {
        using var process = System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo("git", arguments) { WorkingDirectory = directory, CreateNoWindow = true, RedirectStandardError = true })!;
        process.StandardError.ReadToEnd();
        process.WaitForExit();
        return process.ExitCode;
    }
}
