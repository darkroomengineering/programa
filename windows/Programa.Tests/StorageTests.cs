using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace Programa.Tests;

[TestClass]
public sealed class StorageTests
{
    [TestMethod]
    public void AnInstallRunningBlocksItsManagersCache()
    {
        string[] lines =
        [
            "\"C:\\Program Files\\nodejs\\node.exe\" \"C:\\Program Files\\nodejs\\node_modules\\npm\\bin\\npm-cli.js\" install",
            "C:\\Users\\a\\AppData\\Local\\pnpm\\pnpm.exe store path",
            "node C:\\x\\.yarn\\releases\\yarn-4.1.0.cjs",
        ];
        Assert.IsTrue(Storage.InstallRunning("npm", lines));
        Assert.IsFalse(Storage.InstallRunning("pnpm", lines), "store path is not an install");
        Assert.IsTrue(Storage.InstallRunning("yarn", lines), "a bare yarn installs");
        Assert.IsFalse(Storage.InstallRunning("bun", lines));
        Assert.IsTrue(Storage.InstallRunning("bun", null), "no process list keeps the cache");
    }

    [TestMethod]
    public void OnlyCacheFoldersOutsideRepositoriesAreSafe()
    {
        var root = Directory.CreateTempSubdirectory("programa-storage-").FullName;
        try
        {
            var home = Directory.CreateDirectory(Path.Combine(root, "home")).FullName;
            var npm = Directory.CreateDirectory(Path.Combine(home, "npm-cache", "_cacache")).FullName;
            var plain = Directory.CreateDirectory(Path.Combine(home, "Documents")).FullName;
            var repo = Directory.CreateDirectory(Path.Combine(root, "repo")).FullName;
            Directory.CreateDirectory(Path.Combine(repo, ".git"));
            var inRepo = Directory.CreateDirectory(Path.Combine(repo, ".cache")).FullName;
            var project = Directory.CreateDirectory(Path.Combine(root, "project", "store")).FullName;
            Assert.IsTrue(Storage.SafeCachePath(npm, home, []));
            Assert.IsFalse(Storage.SafeCachePath(plain, home, []), "not named like a cache");
            Assert.IsFalse(Storage.SafeCachePath(home, home, []), "the home folder itself");
            Assert.IsFalse(Storage.SafeCachePath(inRepo, home, []), "inside a repository");
            Assert.IsFalse(Storage.SafeCachePath(project, home, [Path.GetDirectoryName(project)!]), "inside a project");
            Assert.IsFalse(Storage.SafeCachePath(Path.Combine(home, "missing-cache"), home, []));
        }
        finally { Directory.Delete(root, recursive: true); }
    }

    [TestMethod]
    public void TheLowDiskWarningRearmsFiveGigabytesAboveTheThreshold()
    {
        var warning = new LowDiskWarning();
        const long GB = 1_000_000_000;
        Assert.IsTrue(warning.Check(19 * GB, 20));
        Assert.IsFalse(warning.Check(10 * GB, 20), "once until space comes back");
        Assert.IsFalse(warning.Check(24 * GB, 20));
        Assert.IsFalse(warning.Check(19 * GB, 20), "24 GB did not re-arm it");
        Assert.IsFalse(warning.Check(26 * GB, 20));
        Assert.IsTrue(warning.Check(19 * GB, 20));
        Assert.IsFalse(new LowDiskWarning().Check(1 * GB, 0), "0 turns it off");
        Assert.AreEqual("1.5 GB", Storage.Bytes(1_500_000_000).Replace(',', '.'));
    }

    [TestMethod]
    public void ScanAndCleanFollowTheMacRules()
    {
        var root = Directory.CreateTempSubdirectory("programa-storage-git-").FullName;
        try
        {
            var origin = Path.Combine(root, "origin.git");
            var repo = Path.Combine(root, "repo");
            Git(root, $"init -q --bare -b main \"{origin}\"");
            Git(root, $"clone -q \"{origin}\" \"{repo}\"");
            File.WriteAllText(Path.Combine(repo, "a.txt"), "a");
            Git(repo, "add -A");
            Git(repo, "-c user.email=t@t -c user.name=t commit -q -m init");
            Git(repo, "push -q origin main");
            var folder = Path.Combine(root, "worktrees");
            var merged = Path.Combine(folder, "repo", "merged");
            Git(repo, $"worktree add -q -b merged \"{merged}\"");
            var outside = Path.Combine(root, "outside");
            Git(repo, $"worktree add -q -b outside \"{outside}\"");
            var settings = new WorktreeSettings(folder, true, 24);

            var scan = Storage.ScanWorktrees([repo], settings);
            Assert.AreEqual(2, scan.Count, "the main checkout is never listed");
            var mergedScan = scan.Single(item => item.Branch == "merged");
            Assert.AreEqual("recently_used", mergedScan.Blocker);
            Assert.IsTrue(mergedScan.ProgramaCreated);
            Assert.IsTrue(mergedScan.SizeBytes > 0);
            Assert.AreEqual("external", scan.Single(item => item.Branch == "outside").Blocker);

            var preview = Storage.Clean(new Storage.CleanOptions(DryRun: true, IgnoreGracePeriod: true), [repo], settings);
            CollectionAssert.AreEqual(new[] { merged }, preview.Removed.Select(item => item.Path).ToArray());
            Assert.IsTrue(Directory.Exists(merged), "a dry run removes nothing");

            var cleaned = Storage.Clean(new Storage.CleanOptions(DryRun: false, IgnoreGracePeriod: true, Paths: [folder]), [repo], settings);
            CollectionAssert.AreEqual(new[] { merged }, cleaned.Removed.Select(item => item.Path).ToArray());
            Assert.IsFalse(Directory.Exists(merged));
            Assert.IsTrue(Directory.Exists(outside), "external worktrees stay without include_external");
            Assert.AreEqual(0, cleaned.CachesRemoved.Count + cleaned.CachesKept.Count, "no cache without a category or item");
        }
        finally
        {
            foreach (var file in Directory.EnumerateFiles(root, "*", SearchOption.AllDirectories)) File.SetAttributes(file, FileAttributes.Normal);
            Directory.Delete(root, recursive: true);
        }
    }

    private static void Git(string directory, string arguments)
    {
        using var process = System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo("git", arguments) { WorkingDirectory = directory, CreateNoWindow = true, RedirectStandardError = true })!;
        process.StandardError.ReadToEnd();
        process.WaitForExit();
    }
}
