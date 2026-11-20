using System.Diagnostics;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace Programa.Tests;

[TestClass]
public sealed class ReviewTests
{
    private const string Unified = """
        diff --git a/src/app.rs b/src/app.rs
        index 1111111..2222222 100644
        --- a/src/app.rs
        +++ b/src/app.rs
        @@ -10,3 +10,4 @@ fn main() {
             let a = 1;
        -    let b = 2;
        +    let b = 3;
        +    let c = 4;
             a + b
        diff --git a/old.txt b/new.txt
        similarity index 90%
        rename from old.txt
        rename to new.txt
        diff --git a/gone.md b/gone.md
        deleted file mode 100644
        --- a/gone.md
        +++ /dev/null
        @@ -1 +0,0 @@
        -bye
        """;

    [TestMethod]
    public void UnifiedDiffParsesFilesHunksAndLineNumbers()
    {
        var files = ReviewDiff.Parse(Unified);
        Assert.AreEqual(3, files.Count);
        var app = files[0];
        Assert.AreEqual(("src/app.rs", "modified"), (app.Path, app.Status));
        var lines = app.Hunks.Single().Lines;
        Assert.AreEqual(5, lines.Count);
        Assert.AreEqual(new ReviewDiffLine('-', 11, null, "    let b = 2;"), lines[1]);
        Assert.AreEqual(new ReviewDiffLine('+', null, 12, "    let c = 4;"), lines[3]);
        Assert.AreEqual(new ReviewDiffLine(' ', 12, 13, "    a + b"), lines[4]);
        Assert.AreEqual(("new.txt", "old.txt", "renamed"), (files[1].Path, files[1].OldPath, files[1].Status));
        Assert.AreEqual(("gone.md", "deleted"), (files[2].Path, files[2].Status));
    }

    [TestMethod]
    public void CommentsSerializeInFileThenLineOrderOnOneLineEach()
    {
        var now = DateTimeOffset.Now;
        var text = ReviewDiff.Serialize([
            new ReviewComment("2", "src/b.rs", 41, 41, "typo", now),
            new ReviewComment("1", "src/a.rs", 12, 14, "add a guard\nfor nil", now),
        ]);
        Assert.AreEqual("Code review comments (2):\n\nsrc/a.rs:12-14 — add a guard / for nil\nsrc/b.rs:41 — typo", text);
        var files = ReviewDiff.Parse(Unified);
        Assert.IsTrue(ReviewDiff.Anchored(new ReviewComment("x", "src/app.rs", 12, 13, "t", now), files));
        Assert.IsFalse(ReviewDiff.Anchored(new ReviewComment("x", "src/app.rs", 40, 41, "t", now), files));
    }

    [TestMethod]
    public void TheSnapshotHasUncommittedUntrackedAndBinaryFiles()
    {
        var repo = Directory.CreateTempSubdirectory("programa-review-").FullName;
        try
        {
            Git(repo, "init -q -b main");
            // The tests compare exact bytes; a machine's core.autocrlf (CI runners: true) would add CRs.
            Git(repo, "config core.autocrlf false");
            File.WriteAllText(Path.Combine(repo, "a.txt"), "one\ntwo\n");
            Git(repo, "add a.txt");
            Git(repo, "-c user.email=t@t -c user.name=t commit -q -m init");
            File.WriteAllText(Path.Combine(repo, "a.txt"), "one\n2\n");
            File.WriteAllText(Path.Combine(repo, "new.txt"), "fresh\n");
            File.WriteAllBytes(Path.Combine(repo, "blob.bin"), [1, 0, 2]);
            var snapshot = ReviewDiff.Snapshot(Path.Combine(repo), "uncommitted", null);
            CollectionAssert.AreEqual(new[] { "a.txt", "blob.bin", "new.txt" }, snapshot.Files.Select(file => file.Path).ToArray());
            Assert.AreEqual(new ReviewDiffLine('+', null, 2, "2"), snapshot.Files[0].Hunks[0].Lines.Single(line => line.Kind == '+'));
            Assert.AreEqual("binary", snapshot.Files[1].Note);
            Assert.AreEqual(("added", "fresh"), (snapshot.Files[2].Status, snapshot.Files[2].Hunks[0].Lines[0].Text));
            Assert.AreEqual("unavailable", Assert.ThrowsExactly<ReviewDiff.ReviewException>(() => ReviewDiff.Snapshot(Path.GetTempPath(), "uncommitted", null)).Code);
        }
        finally
        {
            foreach (var file in Directory.EnumerateFiles(repo, "*", SearchOption.AllDirectories)) File.SetAttributes(file, FileAttributes.Normal);
            Directory.Delete(repo, recursive: true);
        }
    }

    private static void Git(string directory, string arguments) =>
        Process.Start(new ProcessStartInfo("git", arguments) { WorkingDirectory = directory, CreateNoWindow = true })!.WaitForExit();
}

[TestClass]
public sealed class CheckpointTests
{
    [TestMethod]
    public void ARevertPutsFilesBackAndCanBeUndone()
    {
        var repo = Directory.CreateTempSubdirectory("programa-checkpoint-test-").FullName;
        try
        {
            Git(repo, "init -q -b main");
            // The tests compare exact bytes; a machine's core.autocrlf (CI runners: true) would add CRs.
            Git(repo, "config core.autocrlf false");
            File.WriteAllText(Path.Combine(repo, "a.txt"), "one\n");
            File.WriteAllText(Path.Combine(repo, ".gitignore"), "ignored.txt\n");
            Git(repo, "add -A");
            Git(repo, "-c user.email=t@t -c user.name=t commit -q -m init");
            File.WriteAllText(Path.Combine(repo, "ignored.txt"), "keep me");
            File.WriteAllText(Path.Combine(repo, "draft.txt"), "untracked before the turn");

            var turn = Checkpoints.Save(repo, "workspace-1", "surface-1", Checkpoints.TurnStart)!;
            Assert.AreEqual(Checkpoints.TurnStart, turn.Kind);
            // Saving the same files again keeps the newest checkpoint.
            Assert.AreEqual(turn.Ref, Checkpoints.Save(repo, "workspace-1", "surface-1", Checkpoints.TurnStart)!.Ref);

            // The agent's turn: edits a file, deletes one, creates one in a new folder.
            File.WriteAllText(Path.Combine(repo, "a.txt"), "changed by the agent\n");
            File.Delete(Path.Combine(repo, "draft.txt"));
            Directory.CreateDirectory(Path.Combine(repo, "src", "new"));
            File.WriteAllText(Path.Combine(repo, "src", "new", "made.txt"), "new");

            Checkpoints.RestoreNewest(repo, "workspace-1", "surface-1");
            Assert.AreEqual("one\n", File.ReadAllText(Path.Combine(repo, "a.txt")));
            Assert.AreEqual("untracked before the turn", File.ReadAllText(Path.Combine(repo, "draft.txt")));
            Assert.IsFalse(Directory.Exists(Path.Combine(repo, "src")));
            Assert.AreEqual("keep me", File.ReadAllText(Path.Combine(repo, "ignored.txt")));
            Assert.AreEqual(Checkpoints.BeforeRevert, Checkpoints.Newest(repo, "workspace-1", "surface-1")!.Kind);
            // The real index still only knows the committed files.
            Assert.AreEqual(".gitignore\na.txt", GitOutput(repo, "ls-files").Trim().Replace("\r", ""));

            Checkpoints.RestoreNewest(repo, "workspace-1", "surface-1");
            Assert.AreEqual("changed by the agent\n", File.ReadAllText(Path.Combine(repo, "a.txt")));
            Assert.IsTrue(File.Exists(Path.Combine(repo, "src", "new", "made.txt")));
            Assert.IsFalse(File.Exists(Path.Combine(repo, "draft.txt")));
            Assert.AreEqual(Checkpoints.TurnStart, Checkpoints.Newest(repo, "workspace-1", "surface-1")!.Kind);

            Checkpoints.DeleteWorkspace(repo, "workspace-1");
            Assert.IsNull(Checkpoints.Newest(repo, "workspace-1", "surface-1"));
            Assert.IsNull(Checkpoints.Save(Path.GetTempPath(), "workspace-1", "surface-1", Checkpoints.TurnStart));
        }
        finally
        {
            foreach (var file in Directory.EnumerateFiles(repo, "*", SearchOption.AllDirectories)) File.SetAttributes(file, FileAttributes.Normal);
            Directory.Delete(repo, recursive: true);
        }
    }

    private static void Git(string directory, string arguments) =>
        System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo("git", arguments) { WorkingDirectory = directory, CreateNoWindow = true })!.WaitForExit();

    private static string GitOutput(string directory, string arguments)
    {
        using var process = System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo("git", arguments) { WorkingDirectory = directory, CreateNoWindow = true, RedirectStandardOutput = true })!;
        var output = process.StandardOutput.ReadToEnd();
        process.WaitForExit();
        return output;
    }
}
