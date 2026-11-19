using System.Text.Json;

namespace Programa;

/// <summary>What Claude Code in a Programa terminal is started with, as the macOS `claude` wrapper
/// does (the PowerShell integration's `claude` passes both): the MCP config, one server named
/// programa (the bundled programa-mcp, which finds this app through the terminal's
/// PROGRAMA_SOCKET_PATH), and the hook settings, which run `programa claude-hook` so Claude reports
/// its session to the terminal it runs in.</summary>
internal static class McpConfig
{
    /// <summary>The written MCP config, or null when this build has no programa-mcp.</summary>
    internal static string? FilePath { get; private set; }

    /// <summary>The written hook settings, or null when this build has no programa CLI.</summary>
    internal static string? HooksPath { get; private set; }

    /// <summary>The folder holding programa.exe and programa-mcp.exe that terminals put on PATH.</summary>
    internal static string BinDirectory { get; private set; } = Path.Combine(AppContext.BaseDirectory, "bin");

    internal static void Write()
    {
        var folder = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Programa");
        var dev = BuildIdentity.Value.Contains("0.0.0-dev", StringComparison.Ordinal) ? "-dev" : string.Empty;
        BinDirectory = StageTools(Path.Combine(folder, $"bin{dev}"));
        var server = Path.Combine(BinDirectory, "programa-mcp.exe");
        if (File.Exists(server))
            FilePath = TryWrite(Path.Combine(folder, $"mcp{dev}.json"), new { mcpServers = new { programa = new { command = server } } });
        var cli = Path.Combine(BinDirectory, "programa.exe");
        if (File.Exists(cli))
            HooksPath = TryWrite(Path.Combine(folder, $"claude-hooks{dev}.json"), HookSettings(cli));
    }

    /// <summary>The installed app is one file that unpacks to %TEMP%\.net, which temp cleanup can
    /// empty while the app runs; the CLI and MCP server that terminals, Claude Code and its hooks
    /// call are copied out to <paramref name="target"/> instead. Falls back to the unpacked copies.</summary>
    private static string StageTools(string target)
    {
        var source = Path.Combine(AppContext.BaseDirectory, "bin");
        try
        {
            Directory.CreateDirectory(target);
            foreach (var name in new[] { "programa.exe", "programa-mcp.exe" })
            {
                var from = new FileInfo(Path.Combine(source, name));
                if (!from.Exists) continue;
                var to = new FileInfo(Path.Combine(target, name));
                if (to.Exists && to.Length == from.Length && to.LastWriteTimeUtc == from.LastWriteTimeUtc) continue;
                from.CopyTo(to.FullName, overwrite: true);
            }
            return target;
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            // A `programa` still running from the staged copy holds it; the unpacked one works meanwhile.
            LaunchLog.Write($"claude: tools not staged in {target}: {error.Message}");
            return source;
        }
    }

    /// <summary>Claude Code settings with the macOS wrapper's hooks (Resources/bin/claude): session and
    /// state, PreToolUse (async) for an open AskUserQuestion, PermissionRequest and PostToolUseFailure
    /// for which agent has a prompt open, and SubagentStart/SubagentStop for the helpers popover.</summary>
    internal static object HookSettings(string cli)
    {
        // Forward slashes and no quotes run the same in Git Bash, cmd and PowerShell, whichever
        // shell Claude Code uses for hooks. ponytail: a path with spaces is quoted, which
        // PowerShell would read as a string; quote with & if Claude ever runs hooks there.
        var program = cli.Replace('\\', '/');
        if (program.Contains(' ')) program = $"\"{program}\"";
        object Hook(string evt, int timeout, bool isAsync = false, string matcher = "")
        {
            var command = $"{program} claude-hook {evt}";
            object hook = isAsync ? new { type = "command", command, timeout, @async = true } : new { type = "command", command, timeout };
            return new[] { new { matcher, hooks = new[] { hook } } };
        }
        return new
        {
            hooks = new
            {
                SessionStart = Hook("session-start", 10),
                UserPromptSubmit = Hook("prompt-submit", 10),
                Stop = Hook("stop", 10),
                Notification = Hook("notification", 10),
                PreToolUse = Hook("pre-tool-use", 5, isAsync: true),
                PostToolUse = Hook("post-tool-use", 5),
                PostToolUseFailure = Hook("post-tool-use", 5, matcher: "*"),
                PermissionRequest = Hook("permission-request", 5, matcher: "*"),
                SubagentStart = Hook("subagent-start", 5),
                SubagentStop = Hook("subagent-stop", 5),
                SessionEnd = Hook("session-end", 1),
            },
        };
    }

    private static string? TryWrite(string file, object content)
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(file)!);
            File.WriteAllText(file, JsonSerializer.Serialize(content));
            return file;
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            LaunchLog.Write($"claude: {Path.GetFileName(file)} not written: {error.Message}");
            return null;
        }
    }
}
