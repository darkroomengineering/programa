using System.Text.Json;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace Programa.Tests;

[TestClass]
public sealed class ClaudeHookTests
{
    private static string Command(string cli, string hook) =>
        JsonDocument.Parse(JsonSerializer.Serialize(McpConfig.HookSettings(cli))).RootElement
            .GetProperty("hooks").GetProperty(hook)[0].GetProperty("hooks")[0].GetProperty("command").GetString()!;

    [TestMethod]
    public void HooksRunTheBundledCliInAnyShell()
    {
        // Forward slashes, unquoted: the same line works in Git Bash, cmd and PowerShell.
        Assert.AreEqual("C:/Apps/Programa/bin/programa.exe claude-hook session-start", Command(@"C:\Apps\Programa\bin\programa.exe", "SessionStart"));
        Assert.AreEqual("\"C:/Users/Ada Lovelace/bin/programa.exe\" claude-hook session-end", Command(@"C:\Users\Ada Lovelace\bin\programa.exe", "SessionEnd"));
    }

    [TestMethod]
    public void HooksCoverSubagentsAndPermissionRequests()
    {
        var hooks = JsonDocument.Parse(JsonSerializer.Serialize(McpConfig.HookSettings("programa"))).RootElement.GetProperty("hooks");
        Assert.AreEqual("programa claude-hook subagent-stop", Command("programa", "SubagentStop"));
        // A failed tool ends a stop for input like a finished one.
        Assert.AreEqual("programa claude-hook post-tool-use", Command("programa", "PostToolUseFailure"));
        Assert.AreEqual("programa claude-hook permission-request", Command("programa", "PermissionRequest"));
        // PreToolUse runs on every tool, so Claude does not wait for it.
        Assert.IsTrue(hooks.GetProperty("PreToolUse")[0].GetProperty("hooks")[0].GetProperty("async").GetBoolean());
        Assert.IsFalse(hooks.GetProperty("PostToolUse")[0].GetProperty("hooks")[0].TryGetProperty("async", out _), "PostToolUse must land before the next tool's prompt");
    }
}
