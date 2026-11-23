using System.Text.RegularExpressions;

namespace Programa;

/// <summary>An agent session a terminal ran, which `programa resume` and the palette start again.</summary>
internal sealed record AgentSession(string Provider, string Id, string? Cwd);

/// <summary>Resuming agents, as on macOS (docs/workspace-interface.md, Resume an agent session).
/// The session id comes from Claude Code's SessionStart hook (`programa claude-hook`, agent.event);
/// for Claude started without the hooks, from Claude Code's own store: each session is
/// `%USERPROFILE%\.claude\projects\&lt;directory slug&gt;\&lt;id&gt;.jsonl`, and the newest one in the
/// terminal's directory when its agent ends a turn is that terminal's.</summary>
internal static class AgentSessions
{
    internal static string ClaudeProjects { get; set; } = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".claude", "projects");

    /// <summary>Claude Code's folder name for a directory: every character but a letter or digit is "-".</summary>
    internal static string ProjectSlug(string directory) => Regex.Replace(directory.TrimEnd('\\'), "[^A-Za-z0-9]", "-");

    /// <summary>The newest Claude Code session written in <paramref name="directory"/>.</summary>
    // ponytail: newest file in the directory wins; two Claude sessions ending turns in one directory
    // at the same moment can swap. Only used when no SessionStart hook reported the session.
    internal static AgentSession? LatestClaude(string directory)
    {
        var folder = new DirectoryInfo(Path.Combine(ClaudeProjects, ProjectSlug(directory)));
        if (!folder.Exists) return null;
        var newest = folder.EnumerateFiles("*.jsonl").MaxBy(file => file.LastWriteTimeUtc);
        var id = newest is null ? null : Path.GetFileNameWithoutExtension(newest.Name);
        return id is not null && IsSessionId(id) ? new AgentSession("claude", id, directory) : null;
    }

    /// <summary>Only letters, digits, dashes and underscores (Codex ids), so an id can be typed into a shell as is.</summary>
    internal static bool IsSessionId(string id) => id.Length is > 0 and <= 128 && Regex.IsMatch(id, "^[A-Za-z0-9_-]+$");

    /// <summary>app.autoResumeAgents, as macOS's autoResumeInput: the line a restored terminal whose shell
    /// did not survive types to start the agent it was running at quit again, or null. A Claude session
    /// whose transcript is gone is not resumed.</summary>
    internal static string? AutoResumeCommand(SessionTerminal? saved, bool enabled) =>
        enabled && saved is { AgentRunning: true, Agent: { } session } && (session.Provider != "claude" || ClaudeTranscriptExists(session.Id))
            ? ResumeCommand(session, saved.Cwd)
            : null;

    /// <summary>Whether a project folder holds the session's transcript; true when the store cannot be read, as on macOS.</summary>
    internal static bool ClaudeTranscriptExists(string id)
    {
        try
        {
            return !Directory.Exists(ClaudeProjects) ||
                Directory.EnumerateDirectories(ClaudeProjects).Any(project => new FileInfo(Path.Combine(project, id + ".jsonl")) is { Exists: true, Length: > 0 });
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { return true; }
    }

    /// <summary>The PowerShell line that resumes the session, entering its directory first when the
    /// terminal is elsewhere and that directory still exists.</summary>
    internal static string ResumeCommand(AgentSession session, string? currentDirectory)
    {
        var resume = session.Provider switch
        {
            "codex" => $"codex resume {session.Id}",
            "opencode" => $"opencode --session {session.Id}",
            _ => $"claude --resume {session.Id}",
        };
        return session.Cwd is { } directory && Directory.Exists(directory) && !Worktrees.SamePath(directory, currentDirectory ?? string.Empty)
            ? $"Set-Location -LiteralPath '{directory.Replace("'", "''")}'; {resume}"
            : resume;
    }
}
