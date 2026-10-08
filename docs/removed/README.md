# Removed features

Each file here records one feature that was deleted from Programa on purpose, so it can be brought back with what we learned the first time. Every doc names the last commit that contained the feature and the exact `git checkout <sha> -- <paths>` command that restores its files. Restoring the files is the easy part; read the "What we learned" section before wiring it back in.

Reductive pass of 2026-09-02, base commit 903027ccef. Core kept: the Ghostty terminal, workspaces and splits, the sidebar, agent status detection and hooks, notifications, the diff review panel, worktrees and race, layouts, the markdown recap panel, the CLI, socket API, and MCP server, updates, session persistence and escrow, the Claude quota footer, and the local tmux-compat CLI.

| Feature | Doc | Approx. lines removed |
|---|---|---|
| SSH remote workspaces and the Go daemon | [ssh-remote-workspaces.md](ssh-remote-workspaces.md) | 25,600 |
| Mobile bridge, iOS companion, vendored iroh packages | [mobile-bridge-and-ios.md](mobile-bridge-and-ios.md) | 67,000 |
| Built-in browser and its automation API | [built-in-browser.md](built-in-browser.md) | 35,000 |
| Browser data import wizard | [browser-data-import.md](browser-data-import.md) | 3,800 |
| Browser extensions | [browser-extensions.md](browser-extensions.md) | 950 |
| Browser React Grab overlay | [browser-react-grab.md](browser-react-grab.md) | 470 |
| AppleScript support | [applescript.md](applescript.md) | 720 |
| Inline VS Code (serve-web) | [inline-vscode.md](inline-vscode.md) | 610 |
| Custom notification sound files | [custom-notification-sounds.md](custom-notification-sounds.md) | 400 |

Line counts are git-tracked lines at removal time and include tests and vendored code.
