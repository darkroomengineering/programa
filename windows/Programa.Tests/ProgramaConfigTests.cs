using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace Programa.Tests;

[TestClass]
public sealed class ProgramaConfigTests
{
    private string _root = string.Empty;

    [TestInitialize]
    public void Setup()
    {
        _root = Directory.CreateTempSubdirectory("programa-config-").FullName;
        ProgramaConfig.GlobalPath = Path.Combine(_root, "home", "programa.json");
        ProgramaConfig.TrustStorePath = Path.Combine(_root, "store", "trusted-directories.json");
        ProgramaConfig.ManagedRoots = () => null;
    }

    [TestCleanup]
    public void Cleanup() => Directory.Delete(_root, recursive: true);

    private string Write(string relative, string text)
    {
        var path = Path.GetFullPath(Path.Combine(_root, relative));
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        File.WriteAllText(path, text);
        return path;
    }

    [TestMethod]
    public void CommandsAndRecipesParseAndBadFilesLoadNothing()
    {
        var entries = ProgramaConfig.Parse("""
            {
              // comments and trailing commas are fine
              "commands": [
                { "name": "Run tests", "description": "npm", "keywords": ["ci"], "command": "npm test", "confirm": true },
                { "name": "Dev", "restart": "recreate", "workspace": { "name": "dev", "cwd": "app", "color": "a1b2c3",
                  "layout": { "pane": { "surfaces": [{ "type": "terminal", "command": "npm run dev" }] } } } },
              ],
              "recipes": [{ "name": "Fix", "prompt": "Fix {{file}}", "parameters": [{ "name": "file", "default": "a.ts" }] }],
              "routes": [{ "name": "ignored here" }]
            }
            """, "x");
        Assert.AreEqual(3, entries.Count);
        Assert.AreEqual(("npm test", true, "ignore"), (entries[0].Text, entries[0].Confirm, entries[0].Restart));
        Assert.AreEqual(("#A1B2C3", "recreate", "npm run dev"), (entries[1].Workspace!.Color, entries[1].Restart, ((LayoutPane)entries[1].Workspace!.Layout!).Surfaces[0].Command));
        Assert.IsTrue(entries[2].Recipe);
        Assert.AreEqual("a.ts", entries[2].Parameters.Single().Default);
        Assert.AreEqual(0, ProgramaConfig.Parse("""{"routes":[]}""", "x").Count);

        foreach (var (json, reason) in new[]
        {
            ("""{"commands":[{"name":"a","command":"x","workspace":{}}]}""", "both"),
            ("""{"commands":[{"name":"a"}]}""", "either"),
            ("""{"commands":[{"name":" ","command":"x"}]}""", "blank"),
            ("""{"commands":[{"name":"a","command":"  "}]}""", "blank 'command'"),
            ("""{"commands":[{"name":"a","workspace":{"color":"red"}}]}""", "#RRGGBB"),
            ("""{"commands":[{"name":"a","command":"x","restart":"always"}]}""", "restart"),
            ("""{"recipes":[{"name":"a","prompt":""}]}""", "blank 'prompt'"),
            ("""{"commands":[{"name":"a","command":"x","command":"y"}]}""", "repeats a key"),
        })
            StringAssert.Contains(Assert.ThrowsExactly<FormatException>(() => ProgramaConfig.Parse(json, "x")).Message, reason);
    }

    [TestMethod]
    public void TheNearestLocalFileWinsOverTheGlobalOne()
    {
        Write("home/programa.json", """{"commands":[{"name":"Shared","command":"global"},{"name":"Global only","command":"g"}]}""");
        var local = Write("repo/programa.json", """{"commands":[{"name":"Shared","command":"local"}]}""");
        Directory.CreateDirectory(Path.Combine(_root, "repo", "src", "deep"));
        var entries = ProgramaConfig.Load(Path.Combine(_root, "repo", "src", "deep"));
        CollectionAssert.AreEqual(new[] { "local", "g" }, entries.Select(entry => entry.Text).ToArray());
        Assert.AreEqual(local, entries[0].Source);
        // A broken local file costs only itself.
        Write("repo/programa.json", "{ not json");
        CollectionAssert.AreEqual(new[] { "global", "g" }, ProgramaConfig.Load(Path.Combine(_root, "repo")).Select(entry => entry.Text).ToArray());
    }

    [TestMethod]
    public void TrustIsPinnedToTheRepoRootAndTheFileContent()
    {
        Directory.CreateDirectory(Path.Combine(_root, "repo", ".git"));
        var path = Write("repo/tools/programa.json", """{"commands":[{"name":"a","command":"x"}]}""");
        var entry = ProgramaConfig.Load(Path.Combine(_root, "repo", "tools")).Single(item => item.Source == path);
        Assert.AreEqual(Path.Combine(_root, "repo"), ProgramaConfig.TrustRoot(path));
        Assert.AreEqual(TrustState.Untrusted, ProgramaConfig.State(path, entry.Digest));

        ProgramaConfig.Trust(path, entry.Digest!);
        Assert.AreEqual(TrustState.Trusted, ProgramaConfig.State(path, entry.Digest));
        // A comment or reformat keeps trust; a changed command does not, even for entries parsed before.
        File.WriteAllText(path, "// note\n{ \"commands\": [ { \"command\": \"x\", \"name\": \"a\" } ] }");
        Assert.AreEqual(TrustState.Trusted, ProgramaConfig.State(path, entry.Digest));
        File.WriteAllText(path, """{"commands":[{"name":"a","command":"rm -rf"}]}""");
        Assert.AreEqual(TrustState.Changed, ProgramaConfig.State(path, entry.Digest));
        Assert.IsTrue(ProgramaConfig.HasRecordedDigest(path));

        // A root added by hand has no digest yet, so its files prompt once.
        var other = Write("other/programa.json", """{"commands":[{"name":"b","command":"y"}]}""");
        var otherDigest = ProgramaConfig.DigestOf(other);
        ProgramaConfig.ReplaceRoots([Path.Combine(_root, "repo"), Path.Combine(_root, "other")]);
        Assert.AreEqual(TrustState.Changed, ProgramaConfig.State(other, otherDigest));
        Assert.IsFalse(ProgramaConfig.HasRecordedDigest(other));
        Assert.IsTrue(ProgramaConfig.HasRecordedDigest(path), "a root that stays keeps its digests");

        // settings.json's list replaces the stored roots.
        ProgramaConfig.Trust(other, otherDigest!);
        ProgramaConfig.ManagedRoots = () => [Path.Combine(_root, "repo")];
        Assert.AreEqual(TrustState.Untrusted, ProgramaConfig.State(other, otherDigest));
        Assert.AreEqual(TrustState.Trusted, ProgramaConfig.State(Write("home/programa.json", "{}"), null), "the global file is always trusted");
    }

    [TestMethod]
    public void OnlyATrustedFileWithoutConfirmRunsUnasked()
    {
        Assert.IsTrue(ProgramaConfig.RequiresConfirmation(confirmFlag: false, trusted: false));
        Assert.IsTrue(ProgramaConfig.RequiresConfirmation(confirmFlag: true, trusted: false));
        Assert.IsFalse(ProgramaConfig.RequiresConfirmation(confirmFlag: false, trusted: true));
        Assert.IsTrue(ProgramaConfig.RequiresConfirmation(confirmFlag: true, trusted: true));
    }

    [TestMethod]
    public void ParametersSubstituteAndTheDialogShowsEverything()
    {
        var values = new Dictionary<string, string> { ["file"] = "a.ts" };
        Assert.AreEqual("fix a.ts {{other}} a.ts", ProgramaConfig.Substitute("fix {{file}} {{other}} {{ file }}", values));

        var entry = ProgramaConfig.Parse("""
            {"commands":[{"name":"Dev","workspace":{"cwd":"app","layout":{"direction":"horizontal","children":[
              {"pane":{"surfaces":[{"type":"terminal","name":"server","command":"npm run dev"}]}},
              {"pane":{"surfaces":[{"type":"terminal","env":{"ZDOTDIR":"evil","A":"1"}},{"type":"terminal"}]}}]}}}]}
            """, "x").Single();
        Assert.AreEqual("Open workspace \"Dev\"\n  cwd=app\n\n  server: npm run dev\n  env: A=1 ZDOTDIR=evil", ProgramaConfig.Describe(entry, null, "Open workspace \"{0}\"", "…"));

        var spoof = "rm -rf ~" + (char)0x202E + "txt.";
        Assert.AreEqual("echo a ⏎ rm -rf ~txt.", ProgramaConfig.Display("echo a\n" + spoof, "…"));
        Assert.AreEqual(new string('x', 200) + "…", ProgramaConfig.Display(new string('x', 500), "…"));
        Assert.AreEqual(500, ProgramaConfig.ForExecution(new string('x', 500)).Length, "what runs is never shortened");
    }

    [TestMethod]
    public void ControlCharactersAreRefused()
    {
        Assert.IsFalse(ProgramaConfig.HasControlCharacters("npm test\nnpm run lint"));
        Assert.IsTrue(ProgramaConfig.HasControlCharacters("npm test" + (char)0x1B + "[2K"));
        Assert.IsTrue(ProgramaConfig.HasControlCharacters("a\tb"));
        Assert.IsNull(ProgramaConfig.Insertable("line one\nline two"));
        Assert.IsNull(ProgramaConfig.Insertable("a" + (char)0x2028 + "b"));
        Assert.AreEqual("fix it", ProgramaConfig.Insertable("fix" + (char)0x200B + " it"));
    }
}
