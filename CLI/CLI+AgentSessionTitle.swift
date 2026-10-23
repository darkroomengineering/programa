import Foundation

extension AgentHookContext {
    /// Claude Code often never writes its session topic as a terminal title (notably on
    /// `--resume`), so tabs keep the shell's cwd. Reads the topic from the transcript
    /// instead and sets it as the pane's title. Sent on every call rather than only when it
    /// changed: the app forgets the title when it restarts, and the hook has no way to know.
    /// Best effort: any failure leaves the pane title as it was.
    func reportSessionTitle(
        _ hook: AgentHookProvider,
        storedTranscriptPath: String?,
        workspaceId: String,
        surfaceId: String
    ) {
        guard hook.provider == "claude-code",
              let transcriptPath = parsed.transcriptPath ?? storedTranscriptPath,
              let title = ClaudeTranscriptTitle.latestTitle(atPath: NSString(string: transcriptPath).expandingTildeInPath) else {
            return
        }
        _ = try? client.sendV2(method: V2MethodNames.surfaceReportAgentTitle, params: [
            "workspace_id": workspaceId,
            "surface_id": surfaceId,
            "title": title,
        ])
    }
}
