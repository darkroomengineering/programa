import Foundation

extension ProgramaCLI {
    func worktreeAndLayoutDescriptors() -> [CommandDescriptor] {
        [
            CommandDescriptor(
                names: ["worktree"],
                helpLines: ["worktree <create|open|remove|list> ..."],
                detailedUsage: """
                Usage: programa worktree <subcommand> [flags]

                Native git worktree workflow: create/open a worktree as its own workspace,
                grouped next to its parent repo's workspace in the sidebar.

                Subcommands:
                  create <branch> [--base <ref>] [--path <dir>] [--repo <dir>] [--layout <name>] [--focus]
                      Create (or check out) a worktree for <branch> and open it as a workspace.
                      If <branch> already exists locally, it is checked out; otherwise it is
                      created from --base (default HEAD). Default --path is
                      <worktrees.directory>/<repo-name>/<branch-slug>. --layout applies a saved
                      layout (see 'programa layout') into the new workspace. --focus opts in to
                      focusing the new workspace (default: does not steal focus).

                  create [<branch>] --from-issue <number> [--agent <name>] [create flags]
                      Read GitHub issue <number> with 'gh issue view' (run in the repo, so gh
                      must be installed and logged in) and create the worktree on branch
                      issue-<number>-<title-slug>. An explicit <branch> wins over the derived
                      name. --agent (claude, opencode, or codex) then starts that agent in the
                      new workspace, pointed at a temp file holding the issue title, link and
                      body; the issue text is never typed into the shell. Prompt files are
                      kept in $TMPDIR/programa-issue-prompts for 7 days.

                  open <path-or-branch> [--repo <dir>] [--focus]
                  open --all [--repo <dir>]
                      Open an existing worktree (by path or branch name) as a workspace.
                      Idempotent: returns the existing workspace if already open. --all opens
                      every worktree of the repo at once instead of one <path-or-branch>;
                      mutually exclusive with a positional target and with --focus.

                  remove <path-or-branch> [--repo <dir>] [--force]
                      Remove a worktree (never deletes the branch). Closes its workspace if
                      open. Requires --force if the worktree has uncommitted changes.

                  list [--repo <dir>] [--json]
                      List worktrees for the resolved repo, noting which are open as workspaces.

                Flags:
                  --repo <dir>       Repo to operate on. Default: resolved from the current
                                     directory via 'git rev-parse --show-toplevel'.
                  --base <ref>       Base ref for a new branch (create only). Default: HEAD.
                  --path <dir>       Worktree directory (create only). Default: computed from
                                     the worktrees.directory setting.
                  --layout <name>    Apply a saved layout (see 'programa layout') after creating
                                     the workspace (create only).
                  --from-issue <n>   Name the branch after GitHub issue <n> (create only).
                  --agent <name>     Start claude, opencode, or codex on the issue (needs
                                     --from-issue).
                  --focus            Focus the workspace after create/open (default: off).
                  --all              Open every worktree of the repo (open only).
                  --force            Allow removing a worktree with uncommitted changes.

                Example:
                  programa worktree create feature-x
                  programa worktree create feature-x --base main --layout fullstack-dev
                  programa worktree create --from-issue 42 --agent claude
                  programa worktree list --repo ~/code/programa
                  programa worktree open --all
                  programa worktree remove feature-x
                """,
                grammar: CLIArgumentGrammar(valueOptions: ["repo", "base", "path", "layout", "from-issue", "agent"], booleanOptions: ["focus", "force", "json", "all"], minPositionals: 1, maxPositionals: nil, validate: { _, parsed in
                    guard ["create", "open", "remove", "list"].contains(parsed.positional[0].lowercased()) else {
                        throw CLIError(message: "worktree: unknown subcommand \(parsed.positional[0])")
                    }
                    if parsed.options["from-issue"] != nil || parsed.options["agent"] != nil {
                        guard parsed.positional[0].lowercased() == "create" else {
                            throw CLIError(message: "worktree: --from-issue and --agent are only valid for create")
                        }
                        let issueNumber = try parsed.options["from-issue"].map(self.parseWorktreeIssueNumber)
                        if let agent = parsed.options["agent"] {
                            _ = try self.validateWorktreeIssueAgent(agent, issueNumber: issueNumber)
                        }
                    }
                    if parsed.options["all"] != nil {
                        guard parsed.positional[0].lowercased() == "open" else {
                            throw CLIError(message: "worktree: --all is only valid for open")
                        }
                        guard parsed.options["focus"] == nil else {
                            throw CLIError(message: "worktree open: --focus cannot be combined with --all")
                        }
                        guard parsed.positional.count == 1 else {
                            throw CLIError(message: "worktree open --all does not take a <path-or-branch> argument")
                        }
                        if let unsupported = parsed.options.keys.first(where: { !["all", "repo"].contains($0) }) {
                            throw CLIError(message: "worktree open --all: unexpected option --\(unsupported)")
                        }
                    }
                }),
                execute: { ctx in
                    try self.runWorktreeCommand(commandArgs: ctx.commandArgs, client: ctx.client, jsonOutput: ctx.jsonOutput, idFormat: ctx.idFormat)
                }
            ),

            CommandDescriptor(
                names: ["agent-detection"],
                helpLines: ["agent-detection <list|scaffold|test> ..."],
                detailedUsage: """
                Usage: programa agent-detection <subcommand> [flags]

                Screen-manifest agent detection is a best-effort tier: regex patterns matched
                against visible terminal text to guess whether a coding agent is
                working/blocked/idle, used only when an agent doesn't report its own lifecycle
                via hooks. Programa ships manifests for a handful of agents; this command lets
                you author your own for anything else, at
                ~/.config/programa/agent-detection/<agent-id>.json -- a user override there
                fully replaces any bundled manifest with the same agent id.

                Subcommands:
                  list [--json]
                      List every loaded manifest (bundled + user overrides): agent id, display
                      name, source, and recognized process names.

                  scaffold <agent-id> [--surface <id|ref>] [--workspace <id|ref>] [--force]
                      Capture the target surface's current screen and write a starter manifest
                      to ~/.config/programa/agent-detection/<agent-id>.json, with the captured
                      screen embedded as reference text in each state's notes. Refuses to
                      overwrite an existing file unless --force. Also refuses <agent-id>s that
                      match one of the seven bundled agents (claude-code, codex, gemini-cli,
                      opencode, copilot-cli, cursor-agent, aider) unless --force, since an
                      override fully replaces the bundled manifest and a fresh scaffold starts
                      with empty patterns -- without --force this would silently disable working
                      detection for that agent. --force seeds the new file from the bundled
                      manifest's own patterns instead of starting blank.

                  test [<agent-id>] [--surface <id|ref>] [--workspace <id|ref>]
                      Classify the target surface's current screen through the real
                      recognition + classification path. With <agent-id>, tests that manifest's
                      state patterns directly (bypasses recognition -- useful right after
                      scaffolding, before recognize.screen_patterns is filled in). Without it,
                      reports whichever loaded manifest's recognize.screen_patterns first
                      matches the screen, the same way live detection would.

                Flags:
                  --surface <id|ref>     Target surface (default: $PROGRAMA_SURFACE_ID)
                  --workspace <id|ref>   Target workspace (default: $PROGRAMA_WORKSPACE_ID)
                  --force                Overwrite an existing scaffolded manifest, and/or
                                         confirm scaffolding one of the bundled agent ids
                                         (scaffold only)

                Example:
                  programa agent-detection list
                  programa agent-detection scaffold my-agent
                  programa agent-detection test my-agent
                  programa agent-detection test
                """,
                grammar: CLIArgumentGrammar(valueOptions: ["surface", "workspace"], booleanOptions: ["force", "json"], minPositionals: 1, maxPositionals: 2, validate: { _, parsed in
                    let subcommand = parsed.positional[0].lowercased()
                    guard ["list", "scaffold", "test"].contains(subcommand) else {
                        throw CLIError(message: "agent-detection: unknown subcommand \(parsed.positional[0])")
                    }
                    if subcommand == "scaffold", parsed.positional.count != 2 {
                        throw CLIError(message: "agent-detection scaffold requires <agent-id>")
                    }
                }),
                execute: { ctx in
                    try self.runAgentDetectionCommand(commandArgs: ctx.commandArgs, client: ctx.client, jsonOutput: ctx.jsonOutput, idFormat: ctx.idFormat, windowId: ctx.windowId)
                }
            ),

            CommandDescriptor(
                names: ["race"],
                helpLines: ["race <prompt> [--n <count>] [--agent <name>] [--base <ref>] [--prefix <slug>] [--layout <name>]"],
                detailedUsage: """
                Usage: programa race <prompt> [flags]

                Fan one prompt across N agents, each in its own isolated git worktree, so you
                can compare their approaches and pick a winner. v1: spawns the fleet only --
                comparison/merge is manual (open each workspace, review its diff, merge the one
                you like via 'programa worktree remove' for the rest).

                For each index 1...N: creates a worktree + workspace on branch <prefix>/<index>
                (via 'programa worktree create', never stealing focus), then types the agent's
                launch command with your prompt into that workspace's focused terminal.

                Flags:
                  --n <count>        Number of parallel agents. Default 3. Must be 1-8.
                  --agent <name>     Agent to launch: claude, opencode, or codex. Default claude.
                                     Only these three report state via lifecycle hooks, which
                                     racing needs for a trustworthy idle signal.
                  --base <ref>       Git ref to branch from. Default: HEAD (see 'worktree create').
                  --prefix <slug>    Branch-name prefix. Default 'race'. Branches are
                                     <prefix>/<n>, continuing after any that already
                                     exist, so racing twice gives you race/1, race/2
                                     then race/3, race/4 rather than a collision.
                  --layout <name>    Saved layout to apply into each new workspace (see
                                     'programa layout').

                If a branch or worktree path already exists for one index, that index is
                reported as failed and the rest of the fleet still spawns; the command exits
                non-zero if any index failed.

                Example:
                  programa race "fix the failing test"
                  programa race "add dark mode" --n 5 --agent codex
                  programa race "refactor the parser" --n 2 --base main --prefix spike
                """,
                grammar: CLIArgumentGrammar(valueOptions: ["n", "agent", "base", "prefix", "layout"], minPositionals: 1, maxPositionals: nil, validate: { _, parsed in
                    if let rawN = parsed.options["n"] {
                        guard let n = Int(rawN), n >= 1, n <= 8 else {
                            throw CLIError(message: "race: --n must be between 1 and 8")
                        }
                    }
                    if let rawAgent = parsed.options["agent"] {
                        guard ["claude", "opencode", "codex"].contains(rawAgent.lowercased()) else {
                            throw CLIError(message: "race: --agent must be one of claude, opencode, codex")
                        }
                    }
                }),
                execute: { ctx in
                    try self.runRaceCommand(commandArgs: ctx.commandArgs, client: ctx.client, jsonOutput: ctx.jsonOutput, idFormat: ctx.idFormat)
                }
            ),

            CommandDescriptor(
                names: ["layout"],
                helpLines: ["layout <save|apply|list> ..."],
                detailedUsage: """
                Usage: programa layout <subcommand> [flags]

                Named layout configs: save the current workspace's pane/split layout under a
                name, and re-apply it later (from the CLI or the command palette).

                Subcommands:
                  save <name> [--force]
                      Capture the current workspace's pane/split layout and cwds
                      into ~/.config/programa/layouts/<name>.json. Does NOT capture what
                      command is currently running in each pane -- only geometry and cwd are saved.

                  apply <name> [--workspace <id|ref>] [--cwd <dir>]
                      Apply a saved layout. If --workspace is omitted, creates a new (unfocused)
                      workspace first, with cwd = --cwd (or the current directory), then applies
                      the layout into it -- relative cwds in the saved layout resolve against
                      that new workspace's root.

                  list [--json]
                      List saved layout names.

                Flags:
                  --force            Overwrite an existing layout with the same name (save only).
                  --workspace <id|ref>
                                     Target an existing workspace (apply only).
                  --cwd <dir>        Base directory for a newly created workspace (apply only).

                Example:
                  programa layout save fullstack-dev
                  programa layout apply fullstack-dev
                  programa layout list
                """,
                grammar: CLIArgumentGrammar(valueOptions: ["workspace", "cwd"], booleanOptions: ["force", "json"], minPositionals: 1, maxPositionals: nil, validate: { _, parsed in
                    guard ["save", "apply", "list"].contains(parsed.positional[0].lowercased()) else {
                        throw CLIError(message: "layout: unknown subcommand \(parsed.positional[0])")
                    }
                }),
                execute: { ctx in
                    try self.runLayoutCommand(commandArgs: ctx.commandArgs, client: ctx.client, jsonOutput: ctx.jsonOutput, idFormat: ctx.idFormat)
                }
            ),

            CommandDescriptor(
                names: ["snapshot"],
                helpLines: ["snapshot <list|restore> ..."],
                detailedUsage: """
                Usage: programa snapshot <subcommand> [flags]

                Session-restore history: every launch archives the previous session snapshot
                into ~/Library/Application Support/programa/session-history/ before it can be
                overwritten, so a crash, a forced shutdown, or a launch that skips restore
                never loses your last window layout for good.

                Subcommands:
                  list [--json]
                      List archived snapshots, newest first: id, saved-at, clean/unclean
                      shutdown, and window/workspace/panel counts.

                  restore [<id>|latest]
                      Restore an archived snapshot by opening a new window for every window
                      it contains. Never closes or changes a window that is already open.
                      Defaults to the newest archived snapshot when <id> is omitted or
                      "latest".

                Example:
                  programa snapshot list
                  programa snapshot restore
                  programa snapshot restore 20260731-153000-com.darkroom.programa
                """,
                grammar: CLIArgumentGrammar(booleanOptions: ["json"], minPositionals: 1, maxPositionals: 2, validate: { _, parsed in
                    switch parsed.positional[0].lowercased() {
                    case "list":
                        guard parsed.positional.count == 1 else {
                            throw CLIError(message: "snapshot list does not take a target")
                        }
                    case "restore":
                        guard parsed.options["json"] == nil else {
                            throw CLIError(message: "snapshot restore: unknown flag '--json'")
                        }
                    default:
                        throw CLIError(message: "snapshot: unknown subcommand \(parsed.positional[0])")
                    }
                }),
                execute: { ctx in
                    try self.runSnapshotCommand(commandArgs: ctx.commandArgs, client: ctx.client, jsonOutput: ctx.jsonOutput, idFormat: ctx.idFormat)
                }
            ),
        ]
    }
}
