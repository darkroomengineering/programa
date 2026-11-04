import Foundation

extension ProgramaCLI {
    /// `codex`, `claude` and `opencode`: one subcommand plus `--yes`. `-y` is a
    /// single-dash token, so it arrives as a positional after the subcommand.
    private var integrationInstallGrammar: CLIArgumentGrammar {
        CLIArgumentGrammar(booleanOptions: ["yes", "y"], minPositionals: 1, maxPositionals: 2, shortFlags: ["-y"], validate: { command, parsed in
            guard parsed.positional.count == 1 || parsed.positional[1] == "-y" else {
                throw CLIError(message: "\(command): unexpected arguments: \(parsed.positional[1])")
            }
        })
    }

    /// Commands dispatched before any socket work (`CLICommandDispatcher.run()`),
    /// listed here so `usage()` has one source for their help text.
    func localCommandDescriptors() -> [CommandDescriptor] {
        [
            CommandDescriptor(
                names: ["welcome"],
                helpLines: ["welcome"],
                connectionPolicy: .local,
                detailedUsage: """
                Usage: programa welcome

                Show a welcome screen with the programa logo and useful shortcuts.
                Auto-runs once on first launch.
                """,
                grammar: CLIArgumentGrammar(),
                execute: nil
            ),
            CommandDescriptor(
                names: ["shortcuts"],
                helpLines: ["shortcuts"],
                connectionPolicy: .local,
                argumentContract: .handlerParsed,
                detailedUsage: """
                Usage: programa shortcuts

                Open the Settings window to Keyboard Shortcuts.
                """,
                execute: nil
            ),
            CommandDescriptor(
                names: ["feedback"],
                helpLines: ["feedback [--email <email> --body <text> [--image <path> ...]]  (opens GitHub issues; direct submission disabled)"],
                connectionPolicy: .local,
                argumentContract: .handlerParsed,
                detailedUsage: """
                Usage: programa feedback
                       programa feedback --email <email> --body <text> [--image <path> ...]

                Without args, opens the GitHub issues page (https://github.com/darkroomengineering/programa/issues) in your browser.

                Direct feedback submission is disabled; --email/--body/--image are accepted but the app will
                return an error telling you to report the issue on GitHub instead.

                Flags:
                  --email <email>   Contact email for follow-up (submission disabled)
                  --body <text>     Feedback body (submission disabled)
                  --image <path>    Attach an image file, repeat for multiple images (submission disabled)
                """,
                execute: nil
            ),
            CommandDescriptor(names: ["themes"], helpLines: ["themes [list|set|clear]"], connectionPolicy: .local, argumentContract: .handlerParsed, execute: nil),
            CommandDescriptor(names: ["claude-teams"], helpLines: ["claude-teams [claude-args...]"], connectionPolicy: .local, helpPolicy: .passthrough, argumentContract: .handlerParsed, execute: nil),
            CommandDescriptor(
                names: ["codex"],
                helpLines: ["codex <install-integration|uninstall-integration> [--yes]"],
                connectionPolicy: .local,
                detailedUsage: """
                Usage: programa codex <install-integration|uninstall-integration> [--yes]

                Shows the changes and asks before applying them. --yes (-y) applies
                without asking; without it a non-interactive stdin exits 1 unchanged.

                Install or remove Programa's Codex notification hooks in
                ~/.codex/hooks.json (or $CODEX_HOME/hooks.json), the
                `programa` agent skill (SKILL.md) into ~/.agents/skills/programa/,
                and the bundled programa-mcp server (via `codex mcp add programa`).
                """,
                grammar: integrationInstallGrammar,
                execute: nil
            ),
            CommandDescriptor(
                names: ["claude"],
                helpLines: ["claude <install-integration|uninstall-integration> [--yes]"],
                connectionPolicy: .local,
                detailedUsage: """
                Usage: programa claude <install-integration|uninstall-integration> [--yes]

                Install or remove Programa's persistent Claude Code hooks in
                ~/.claude/settings.json (or $CLAUDE_CONFIG_DIR/settings.json),
                and the `programa` agent skill (SKILL.md) into
                ~/.claude/skills/programa/.
                Unlike the runtime wrapper, this makes the integration work from
                any terminal, not just programa's.
                --yes (-y) applies without asking; without it a non-interactive
                stdin exits 1 unchanged.
                """,
                grammar: integrationInstallGrammar,
                execute: nil
            ),
            CommandDescriptor(
                names: ["opencode"],
                helpLines: ["opencode <install-integration|uninstall-integration> [--yes]"],
                connectionPolicy: .local,
                detailedUsage: """
                Usage: programa opencode <install-integration|uninstall-integration> [--yes]

                Install or remove Programa's OpenCode plugin in
                ~/.config/opencode/plugins/programa.js (or $OPENCODE_CONFIG_DIR/plugins/programa.js),
                and the `programa` agent skill (SKILL.md) into
                ~/.config/opencode/skills/programa/ (or $OPENCODE_CONFIG_DIR/skills/programa/),
                and the bundled programa-mcp server as `mcp.programa` in
                ~/.config/opencode/opencode.json (or $OPENCODE_CONFIG_DIR/opencode.json).
                A JSONC config is never rewritten; the command prints the entry to add.
                OpenCode auto-loads local plugin files, so no npm install is needed.
                The MCP registration is untested against a live OpenCode.
                --yes (-y) applies without asking; without it a non-interactive
                stdin exits 1 unchanged.
                """,
                grammar: integrationInstallGrammar,
                execute: nil
            ),
            CommandDescriptor(
                names: ["aside"],
                helpLines: ["aside <status|install-mcp|uninstall-mcp> [--with-devtools] [--yes]"],
                connectionPolicy: .local,
                detailedUsage: """
                Usage: programa aside <status|install-mcp|uninstall-mcp> [--with-devtools] [--yes]

                Detect the Aside agent browser CLI and register its MCP server with
                Claude Code and Codex. `status` reports the detected aside binary,
                the DevTools endpoint if Aside is running, and each client's
                registration state. `install-mcp` runs `claude mcp add` / `codex mcp add`
                for each detected client; `--with-devtools` also registers a
                chrome-devtools-mcp server pointed at Aside's DevTools port.
                `uninstall-mcp` removes both. `--yes`/`-y` skips the confirmation prompt.
                """,
                grammar: CLIArgumentGrammar(booleanOptions: ["yes", "y", "with-devtools"], minPositionals: 1, maxPositionals: 1),
                execute: nil
            ),
        ]
    }
}
