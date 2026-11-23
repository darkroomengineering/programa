using System.Diagnostics;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace Programa.Tests;

[TestClass]
public sealed class RemainingSettingsTests
{
    [TestMethod]
    public void NewKeysDefaultAsOnMacOS()
    {
        var settings = AppSettings.Parse("{}");
        Assert.IsTrue(settings.AutoResumeAgents);
        Assert.IsTrue(settings.ReapLeftoverAgentProcesses);
        Assert.AreEqual("programaOnly", settings.SocketControlMode);
        Assert.IsNull(settings.SocketPassword);
        Assert.AreEqual(0, settings.ExternalAppOpenAllowlist.Count);
        Assert.IsTrue(settings.SaveScrollbackOnQuit);
        Assert.IsTrue(settings.AgentScreenDetection);
        // The macOS keys for both, in the shared file.
        var off = AppSettings.Parse("""{ "app": { "saveScrollbackOnQuit": false }, "automation": { "agentScreenDetection": false } }""");
        Assert.IsFalse(off.SaveScrollbackOnQuit);
        Assert.IsFalse(off.AgentScreenDetection);
    }

    [TestMethod]
    public void SocketModesAndLegacyAliasesNormalize()
    {
        static string Mode(string value) => AppSettings.Parse($$"""{ "automation": { "socketControlMode": "{{value}}" } }""").SocketControlMode;
        Assert.AreEqual("off", Mode("Off"));
        Assert.AreEqual("programaOnly", Mode("programa-only"));
        Assert.AreEqual("password", Mode("password"));
        // The pipe never admits other users, so every open mode is automation on Windows.
        Assert.AreEqual("automation", Mode("notifications"));
        Assert.AreEqual("automation", Mode("allowAll"));
        Assert.AreEqual("automation", Mode("full_open_access"));
        Assert.AreEqual("programaOnly", Mode("everyone"));
    }

    [TestMethod]
    public void PasswordAndAllowlistAreRead()
    {
        var settings = AppSettings.Parse("""
            { "automation": { "socketPassword": "hunter2" },
              "browser": { "externalAppOpenAllowlist": ["slack.exe|slack", "Bare.App", "|zoommtg", "Teams|", 3] } }
            """);
        Assert.AreEqual("hunter2", settings.SocketPassword);
        CollectionAssert.AreEqual(new[] { "slack.exe|slack" }, settings.ExternalAppOpenAllowlist.ToArray());
        Assert.IsNull(AppSettings.Parse("""{ "automation": { "socketPassword": "" } }""").SocketPassword);
    }

    [TestMethod]
    public void AlwaysAllowIsPerAppAndSchemeAndNeverForFiles()
    {
        Assert.AreEqual("SlackProtocol|slack", MainWindow.AllowlistEntry(new Uri("SLACK://open?team=1"), "SlackProtocol"));
        Assert.AreEqual("zoom.exe|zoommtg", MainWindow.AllowlistEntry(new Uri("zoommtg://join"), "zoom.exe"));
        Assert.IsNull(MainWindow.AllowlistEntry(new Uri(@"C:\notes\run.cmd"), "cmdfile"));
        Assert.IsNull(MainWindow.AllowlistEntry(new Uri("slack://open"), null));
        Assert.IsNull(MainWindow.AllowlistEntry(new Uri("slack://open"), "odd|id"));
        // What the prompt writes is what settings.json reads back.
        var written = $$"""{ "browser": { "externalAppOpenAllowlist": ["{{MainWindow.AllowlistEntry(new Uri("slack://x"), "SlackProtocol")}}"] } }""";
        CollectionAssert.AreEqual(new[] { "SlackProtocol|slack" }, AppSettings.Parse(written).ExternalAppOpenAllowlist.ToArray());
    }

    [TestMethod]
    public void ResetRemovesTheManagedKeysAndKeepsEverythingElse()
    {
        const string original = """
            {
              // shared with the Mac
              "app": {
                "appearance": "dark", // gone
                "minimalMode": true,
                "warnBeforeQuit": false
              },
              "notifications": { "sound": "Glass" },
              "automation": { "socketControlMode": "automation", "socketPassword": "keep" },
              "customCommands": { "trustedDirectories": ["C:\\code"] },
              "windows": { "shortcuts": { "new_tab": "ctrl-t" } }
            }
            """;
        var bytes = System.Text.Encoding.UTF8.GetBytes(original);
        foreach (var (section, key) in MainWindow.ResetKeys) bytes = ShortcutSettings.RemoveValue(bytes, section, key);
        var text = System.Text.Encoding.UTF8.GetString(bytes);
        var reset = AppSettings.Parse(text);
        Assert.AreEqual("system", reset.Appearance);
        Assert.IsTrue(reset.WarnBeforeQuit);
        Assert.AreEqual("default", reset.Sound);
        Assert.AreEqual("programaOnly", reset.SocketControlMode);
        Assert.AreEqual("keep", reset.SocketPassword);
        CollectionAssert.AreEqual(new[] { @"C:\code" }, reset.TrustedDirectories!.ToArray());
        StringAssert.Contains(text, "// shared with the Mac");
        StringAssert.Contains(text, "\"minimalMode\": true");
        Assert.IsFalse(text.Contains("shortcuts", StringComparison.Ordinal));
        // Nothing left to remove leaves the bytes as they are.
        CollectionAssert.AreEqual(bytes, ShortcutSettings.RemoveValue(bytes, "app", "appearance"));
    }

    [TestMethod]
    public void EveryMacSoundPlaysAWindowsSoundAndEachChoiceRoundTrips()
    {
        string[] mac = ["default", "Basso", "Blow", "Bottle", "Frog", "Funk", "Glass", "Hero", "Morse", "Ping", "Pop", "Purr", "Sosumi", "Submarine", "Tink"];
        var events = AppSettings.WindowsSounds.Select(item => item.Event).ToHashSet();
        foreach (var name in mac) Assert.IsTrue(events.Contains(AppSettings.SoundEventFor(name)!), name);
        // What the picker writes is a macOS name that plays the sound it picked.
        foreach (var (soundEvent, value) in AppSettings.WindowsSounds)
        {
            CollectionAssert.Contains(mac, value);
            Assert.AreEqual(soundEvent, AppSettings.SoundEventFor(value));
        }
        Assert.IsNull(AppSettings.SoundEventFor("None"));
        Assert.AreEqual("Default", AppSettings.SoundEventFor("MyCustom.aiff"));
    }

    [TestMethod]
    public void OnlyARunningAgentIsResumedAndOnlyWhenOn()
    {
        var directory = Directory.CreateTempSubdirectory().FullName;
        var projects = AgentSessions.ClaudeProjects;
        try
        {
            AgentSessions.ClaudeProjects = Path.Combine(directory, "projects");
            var session = new AgentSession("claude", "0b5d-11aa", directory);
            var running = new SessionTerminal(directory, null, null, session, AgentRunning: true);
            Assert.AreEqual("claude --resume 0b5d-11aa", AgentSessions.AutoResumeCommand(running, enabled: true));
            Assert.IsNull(AgentSessions.AutoResumeCommand(running, enabled: false));
            Assert.IsNull(AgentSessions.AutoResumeCommand(running with { AgentRunning = false }, enabled: true));
            Assert.IsNull(AgentSessions.AutoResumeCommand(null, enabled: true));

            // Claude's store exists but no longer holds the transcript: nothing to resume.
            var project = Directory.CreateDirectory(Path.Combine(AgentSessions.ClaudeProjects, "C--work")).FullName;
            Assert.IsNull(AgentSessions.AutoResumeCommand(running, enabled: true));
            File.WriteAllText(Path.Combine(project, "0b5d-11aa.jsonl"), "{}\n");
            Assert.AreEqual("claude --resume 0b5d-11aa", AgentSessions.AutoResumeCommand(running, enabled: true));

            // Codex has no transcript check; a session elsewhere enters its directory first.
            var codex = running with { Agent = new AgentSession("codex", "abc", directory), Cwd = Path.GetTempPath() };
            StringAssert.EndsWith(AgentSessions.AutoResumeCommand(codex, enabled: true), "; codex resume abc");
        }
        finally
        {
            AgentSessions.ClaudeProjects = projects;
            Directory.Delete(directory, recursive: true);
        }
    }

    [TestMethod]
    public void LineageStopsWhatTheSessionLeftAndKeepsNohup()
    {
        var lineage = new LeftoverReaper.Lineage(shell: 100);
        lineage.Started(200, parent: 100, started: 10, "claude.exe");
        lineage.Started(300, parent: 200, started: 11, "bash.exe");
        lineage.Started(301, parent: 300, started: 12, "node.exe");
        lineage.Started(310, parent: 300, started: 13, "nohup.exe");
        lineage.Started(311, parent: 310, started: 14, "node.exe");
        // A pid whose recorded parent started later belongs to someone else.
        lineage.Started(400, parent: 301, started: 5, "stranger.exe");
        // Started before the job: no known parent, never stopped.
        lineage.Started(500, parent: 999, started: 15, "orphan.exe");
        Assert.IsFalse(lineage.Exited(300), "bash is not a session");
        Assert.IsTrue(lineage.Exited(200), "claude.exe is a session");
        var (stop, kept) = lineage.TakeLeftovers(200);
        CollectionAssert.AreEquivalent(new uint[] { 301 }, stop.Select(entry => entry.Pid).ToArray());
        CollectionAssert.AreEquivalent(new uint[] { 310, 311 }, kept.Select(entry => entry.Pid).ToArray());
        Assert.AreEqual(0, lineage.TakeLeftovers(200).Stop.Count);
    }

    [TestMethod]
    public void ASessionIsWhatRunsWhenTheStatusSaysClaude()
    {
        var lineage = new LeftoverReaper.Lineage(shell: 100);
        lineage.Started(200, parent: 100, started: 10, "node.exe");
        lineage.Started(201, parent: 200, started: 11, "node.exe");
        lineage.MarkAgents();
        lineage.Started(210, parent: 100, started: 20, "cargo.exe");
        Assert.IsFalse(lineage.Exited(210), "started after the status was seen");
        Assert.IsTrue(lineage.Exited(200));
        Assert.AreEqual(201u, lineage.TakeLeftovers(200).Stop.Single().Pid);
    }

    /// <summary>Real processes in a real job: a stand-in shell runs a stand-in agent (cmd, never claude), which
    /// starts one process plainly and one under Git Bash's nohup, then exits.</summary>
    [TestMethod]
    public void AJobReapsTheAgentsLeftoversButNotNohup()
    {
        const string bash = @"C:\Program Files\Git\bin\bash.exe";
        if (!File.Exists(bash)) Assert.Inconclusive("Git Bash is not installed.");
        var directory = Directory.CreateTempSubdirectory().FullName;
        File.WriteAllText(Path.Combine(directory, "agent.cmd"),
            "@echo off\r\nstart /b ping -n 60 127.0.0.4 >nul\r\n\"" + bash + "\" -c \"nohup ping -n 60 127.0.0.5 >/dev/null 2>&1 &\"\r\nping -n 2 127.0.0.1 >nul\r\n");
        File.WriteAllText(Path.Combine(directory, "shell.cmd"),
            "@echo off\r\nping -n 3 127.0.0.1 >nul\r\ncmd /c \"" + Path.Combine(directory, "agent.cmd") + "\"\r\nping -n 20 127.0.0.1 >nul\r\n");
        var reaped = new TaskCompletionSource<(IReadOnlyList<LeftoverReaper.Entry> Stopped, IReadOnlyList<LeftoverReaper.Entry> Kept)>();
        void OnReaped(uint root, IReadOnlyList<LeftoverReaper.Entry> stopped, IReadOnlyList<LeftoverReaper.Entry> kept) => reaped.TrySetResult((stopped, kept));
        var (images, enabled) = (LeftoverReaper.AgentImages.ToList(), LeftoverReaper.Enabled);
        LeftoverReaper.AgentImages.Add("cmd.exe");
        LeftoverReaper.Enabled = () => true;
        LeftoverReaper.Reaped += OnReaped;
        using var shell = Process.Start(new ProcessStartInfo("cmd.exe", $"/c \"{Path.Combine(directory, "shell.cmd")}\"") { UseShellExecute = false, CreateNoWindow = true })!;
        var started = new List<uint>();
        try
        {
            LeftoverReaper.Watch((uint)shell.Id);
            Assert.IsTrue(LeftoverReaper.Watching((uint)shell.Id));
            Assert.IsTrue(reaped.Task.Wait(TimeSpan.FromSeconds(30)), "the agent's exit was not reaped");
            var (stopped, kept) = reaped.Task.Result;
            started.AddRange(kept.Select(entry => entry.Pid));
            var ping = stopped.Single(entry => entry.Name.Equals("PING.EXE", StringComparison.OrdinalIgnoreCase));
            Assert.IsFalse(IsRunning(ping.Pid), "the plain leftover still runs");
            var kept_ = kept.Single(entry => entry.Name.Equals("PING.EXE", StringComparison.OrdinalIgnoreCase));
            Assert.IsTrue(IsRunning(kept_.Pid), "nohup's process was stopped");
        }
        finally
        {
            LeftoverReaper.Reaped -= OnReaped;
            LeftoverReaper.Enabled = enabled;
            LeftoverReaper.AgentImages.Clear();
            LeftoverReaper.AgentImages.UnionWith(images);
            // Only what this test started: the stand-in shell and what nohup kept.
            foreach (var pid in started) Kill(pid);
            try { shell.Kill(entireProcessTree: true); } catch (InvalidOperationException) { }
            try { Directory.Delete(directory, recursive: true); } catch (IOException) { }
        }
    }

    private static bool IsRunning(uint pid)
    {
        try { using var process = Process.GetProcessById((int)pid); return !process.HasExited; }
        catch (ArgumentException) { return false; }
    }

    private static void Kill(uint pid)
    {
        try { using var process = Process.GetProcessById((int)pid); process.Kill(); }
        catch (Exception error) when (error is ArgumentException or InvalidOperationException or System.ComponentModel.Win32Exception) { }
    }
}
