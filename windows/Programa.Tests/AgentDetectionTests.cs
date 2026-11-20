using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace Programa.Tests;

[TestClass]
public sealed class AgentDetectionTests
{
    private static string Bundled => Path.GetFullPath(Path.Combine(AppContext.BaseDirectory, "..", "..", "..", "..", "..", "..", "Resources", "AgentDetection"));

    [TestMethod]
    public void BundledManifestsRecognizeAndClassifyCodex()
    {
        var manifests = AgentDetection.Load(Bundled, Path.Combine(Path.GetTempPath(), "programa-no-overrides"));
        Assert.IsTrue(manifests.Count >= 7, $"loaded {manifests.Count} from {Bundled}");
        var codex = AgentDetection.Recognize(manifests, "OpenAI Codex (v0.50)\n\n> fix the build\n");
        Assert.AreEqual("codex", codex?.Agent);
        Assert.AreEqual("working", codex!.Classify("OpenAI Codex\n• Working (12s • esc to interrupt)\n"));
        Assert.AreEqual("blocked", codex.Classify("OpenAI Codex\nAllow command?\n  git push (y/n)\n"));
        Assert.IsNull(AgentDetection.Recognize(manifests, "PS C:\\> dir\n"));
    }

    [TestMethod]
    public void AnOverrideReplacesTheBundledManifestWhole()
    {
        var user = Directory.CreateTempSubdirectory("programa-detect-").FullName;
        try
        {
            File.WriteAllText(Path.Combine(user, "codex.json"), """
                {"version":1,"agent":"codex","display_name":"Mine","recognize":{"screen_patterns":["MY CODEX"]},
                 "states":[{"bucket":"done","priority":1,"anchor_last_n_lines":2,"patterns":["finished"]}]}
                """);
            File.WriteAllText(Path.Combine(user, "broken.json"), "{");
            var manifests = AgentDetection.Load(Bundled, user);
            var codex = manifests.Single(manifest => manifest.Agent == "codex");
            Assert.AreEqual("Mine", codex.DisplayName);
            Assert.IsNull(AgentDetection.Recognize([codex], "OpenAI Codex"));
            // "done" reads as idle, and only the last N lines count.
            Assert.AreEqual("idle", codex.Classify("a\nfinished\n"));
            Assert.IsNull(codex.Classify("finished\nb\nc\n"));
        }
        finally
        {
            Directory.Delete(user, recursive: true);
        }
    }

    [TestMethod]
    public void ListAndClassifyReportSourcesRejectsAndTheMatch()
    {
        var user = Directory.CreateTempSubdirectory("programa-detect-").FullName;
        try
        {
            File.WriteAllText(Path.Combine(user, "aider.json"), """
                {"version":1,"agent":"aider","display_name":"My Aider","recognize":{"process_names":["aider"],"screen_patterns":["MY AIDER"]},
                 "states":[{"bucket":"blocked","priority":9,"anchor_last_n_lines":3,"patterns":["Proceed\\?"],"confidence":"high","source_notes":"mine"}]}
                """);
            File.WriteAllText(Path.Combine(user, "bad.json"), """{"agent":"bad","states":[{"bucket":"idle","patterns":["(unclosed"]}]}""");
            var (manifests, rejected) = AgentDetection.LoadAll(Bundled, user);
            var aider = manifests.Single(manifest => manifest.Agent == "aider");
            Assert.AreEqual(("override", "My Aider"), (aider.Source, aider.DisplayName));
            CollectionAssert.AreEqual(new[] { "aider" }, aider.ProcessNames);
            Assert.AreEqual("bundled", manifests.Single(manifest => manifest.Agent == "codex").Source);
            Assert.AreEqual(("bad", "(unclosed"), (rejected.Single().Agent, rejected.Single().InvalidPatterns.Single()));
            Assert.IsFalse(manifests.Any(manifest => manifest.Agent == "bad"));

            var matched = AgentDetection.Classify("MY AIDER\nwork\nProceed?\n", null, manifests);
            Assert.AreEqual(("screen_pattern", "aider", "blocked", "high", @"Proceed\?"),
                ((string?)matched["recognized_via"], (string?)matched["agent"], (string?)matched["bucket"], (string?)matched["confidence"], (string?)matched["matched_pattern"]));
            var explicitNoMatch = AgentDetection.Classify("nothing here", "aider", manifests);
            Assert.AreEqual(("explicit", "aider", null), ((string?)explicitNoMatch["recognized_via"], (string?)explicitNoMatch["agent"], (string?)explicitNoMatch["bucket"]));
            Assert.IsNull(AgentDetection.Classify("PS C:\\> dir", null, manifests)["agent"]);
            Assert.AreEqual("not_found", Assert.ThrowsExactly<ControlException>(() => AgentDetection.Classify("x", "nobody", manifests)).Code);
        }
        finally
        {
            Directory.Delete(user, recursive: true);
        }
    }

    [TestMethod]
    public void AHelperIsNamedAfterItsTaskThenItsRole()
    {
        Assert.AreEqual("Fix the flaky test", MainWindow.AutomaticHelperTitle("Fix the flaky test\nThen report back", "Explore", 2));
        Assert.AreEqual("Explore", MainWindow.AutomaticHelperTitle(null, "Explore", 2));
        Assert.AreEqual(80, MainWindow.AutomaticHelperTitle(new string('x', 200), null, 1).Length);
    }
}

[TestClass]
public sealed class AgentSessionTests
{
    [TestMethod]
    public void TheNewestClaudeSessionInTheDirectoryIsResumed()
    {
        var previous = AgentSessions.ClaudeProjects;
        AgentSessions.ClaudeProjects = Directory.CreateTempSubdirectory("programa-claude-").FullName;
        try
        {
            Assert.AreEqual("C--Users-me-src-app-v2", AgentSessions.ProjectSlug(@"C:\Users\me\src\app.v2\"));
            var folder = Directory.CreateDirectory(Path.Combine(AgentSessions.ClaudeProjects, AgentSessions.ProjectSlug(@"C:\src\app"))).FullName;
            File.WriteAllText(Path.Combine(folder, "11111111-aaaa.jsonl"), "{}");
            File.SetLastWriteTimeUtc(Path.Combine(folder, "11111111-aaaa.jsonl"), DateTime.UtcNow.AddMinutes(-5));
            File.WriteAllText(Path.Combine(folder, "22222222-bbbb.jsonl"), "{}");
            var session = AgentSessions.LatestClaude(@"C:\src\app");
            Assert.AreEqual(new AgentSession("claude", "22222222-bbbb", @"C:\src\app"), session);
            Assert.IsNull(AgentSessions.LatestClaude(@"C:\nowhere"));
            Assert.AreEqual("claude --resume 22222222-bbbb", AgentSessions.ResumeCommand(session!, @"C:\src\app"));
            var elsewhere = session! with { Cwd = AgentSessions.ClaudeProjects };
            Assert.AreEqual($"Set-Location -LiteralPath '{AgentSessions.ClaudeProjects}'; claude --resume 22222222-bbbb", AgentSessions.ResumeCommand(elsewhere, @"C:\src\app"));
            Assert.AreEqual("codex resume abc", AgentSessions.ResumeCommand(new AgentSession("codex", "abc", null), null));
            Assert.IsFalse(AgentSessions.IsSessionId("abc; rm -rf"));
            Assert.IsTrue(AgentSessions.IsSessionId("thr_123"), "Codex thread ids have underscores");
        }
        finally
        {
            Directory.Delete(AgentSessions.ClaudeProjects, recursive: true);
            AgentSessions.ClaudeProjects = previous;
        }
    }
}
