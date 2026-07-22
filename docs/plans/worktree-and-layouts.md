# Native git worktree workflow + named layout configs

Status: planning only, no code written yet.
Scope: two independently shippable halves (A: worktrees, B: layout configs) with one
integration point (`worktree create --layout`).

## Key finding from research

Half B is 70% already built. `Sources/ProgramaConfig.swift` already defines a full
pane/split/surface layout DSL (`ProgramaLayoutNode` / `ProgramaSplitDefinition` /
`ProgramaPaneDefinition` / `ProgramaSurfaceDefinition`, all `Codable`), and
`Sources/Workspace+Layout.swift` (`Workspace.applyCustomLayout`) already knows how to
build a live Bonsplit pane tree from that DSL — it's the engine behind `programa.json`'s
per-command `"workspace": { "layout": ... }` blocks, executed via
`Sources/ProgramaConfigExecutor.swift`. Named layout configs must reuse this format and
this apply engine verbatim, not invent a parallel one. The only genuinely new work for
Half B is (1) a *capture* direction (live workspace -> `ProgramaLayoutNode`) that doesn't
exist yet, and (2) a small named-file store + CLI/socket/palette plumbing around it.

Half A has no existing analog — git worktree lifecycle must be built from scratch, but
should shell out to `git` using the same stateless-`Process`-helper style already
established in `Sources/GitMetadataProber.swift` (`runCommand`/`runCommandResult`, off the
UI-mutation path).

## Architectural decisions

1. **Where worktree git logic lives**: server-side (app process), not the CLI. A new
   stateless `Sources/GitWorktreeManager.swift` does all `git worktree ...` shell-outs.
   The CLI (`CLI/programa.swift`) only ever talks to it through the socket (`worktree.*`
   v2 methods), same as every other CLI command. This means any future UI entry point
   (debug menu, command palette action) gets worktree lifecycle for free with no
   duplicate logic, and it satisfies "agents can drive this via socket" directly.

2. **Layout format**: no new schema. A saved layout file is
   `{"schemaVersion":1,"name":...,"savedAt":...,"layout": <ProgramaLayoutNode>}` — the
   `layout` key decodes with the exact same `Codable` types `programa.json` already uses.
   `Workspace.applyCustomLayout(_:baseCwd:)` is called unchanged for both `programa.json`
   commands and named layout apply.

3. **CLI surface shape**: `programa worktree <subcommand>` and `programa layout
   <subcommand>` (space-separated, git-style), not new flat kebab commands. This matches
   the task's requested UX and the existing `workspace-action <action>` precedent in
   `CLI/programa.swift` (`runWorkspaceAction`, ~line 4863) — a single `CommandDescriptor`
   whose `execute` closure reads the first positional arg as the subcommand. Two new
   descriptors (`names: ["worktree"]`, `names: ["layout"]`), not eight new descriptors.

4. **Sidebar grouping is order + badge, not a tree.** `Sources/VerticalTabsSidebar.swift`
   renders a flat `ForEach(tabs, id: \.id)` over `TabManager.tabs: [Workspace]` — there is
   no existing parent/child or grouping concept anywhere in the sidebar stack (confirmed:
   `Sources/WorkspaceSidebarModels.swift`'s `SidebarBranchOrdering` dedupes branch/PR
   *display within one workspace's panels*, it does not group workspaces). Building a real
   collapsible tree is out of scope for v1. Instead: place the new worktree workspace
   immediately adjacent to its parent in the `tabs` array (ordering = grouping) and render
   a small indent + branch-fork glyph on it. This is a deliberate scope cut — see Risks.

5. **`project.pbxproj` is not filesystem-synchronized** (confirmed: explicit
   `PBXBuildFile`/`PBXFileReference` entries, e.g. `NRSP0084A1B2C3D4E5F60719 /*
   WorkspaceSidebarModels.swift in Sources */`). Every new `.swift` file in this plan needs
   manual pbxproj registration (file reference + build file + group + Sources phase
   membership) or it silently won't compile. Build after each new file, not in a batch.

## File list (create / modify)

### New files

| File | Purpose | Depends on |
|---|---|---|
| `Sources/GitWorktreeManager.swift` | Stateless `git worktree add/list/remove` shell-out helper; repo-root resolution (`git rev-parse --show-toplevel`); branch-slug derivation; mirrors `GitMetadataProber.swift`'s `runCommand`/`runCommandResult` pattern | none |
| `Sources/TerminalController+Worktree.swift` | v2 socket handlers `v2WorktreeCreate/Open/Remove/List`, mirrors `Sources/TerminalController+Workspace.swift` style (`.ok`/`.err` `V2CallResult`, `v2MainSync` only around the `tabManager` mutation) | `GitWorktreeManager.swift` |
| `Sources/ProgramaLayoutStore.swift` | `ObservableObject` file-store for named layouts under `~/.config/programa/layouts/*.json`: `list()`, `load(name:)`, `save(name:node:)`, `remove(name:)`; `FileWatcher` on the directory so the command palette live-updates, mirrors the relevant parts of `Sources/ProgramaConfig.swift`'s `ProgramaConfigStore` | none |
| `Sources/TerminalController+Layout.swift` | v2 socket handlers `v2LayoutSave/Apply/List` | `ProgramaLayoutStore.swift`, `Workspace+Layout.swift` capture addition |

### Modified files

| File | Change |
|---|---|
| `CLI/programa.swift` | Two new `CommandDescriptor` entries (`worktree`, `layout`) in `commandDescriptors()`; two new private dispatch funcs `runWorktreeCommand`/`runLayoutCommand` mirroring `runWorkspaceAction`; detailed usage text for both |
| `Sources/TerminalController.swift` | New `switch` cases in `processV2Command` (~line 1541, new `// Worktrees` and `// Layouts` sections next to `// Workspaces`): `worktree.create/open/remove/list`, `layout.save/apply/list` |
| `Sources/Workspace.swift` | Add `@Published var worktreeParentWorkspaceId: UUID?` and `@Published var worktreeBranch: String?` |
| `Sources/Workspace+Layout.swift` | Add capture direction: `func captureCustomLayout() -> ProgramaLayoutNode?` (walks `bonsplitController.treeSnapshot()`, mirrors the existing `applyCustomDividerPositions` tree-walk but in reverse); add shared `func applyNamedLayout(name:baseCwd:store:)` used by both `layout.apply` and `worktree create --layout` |
| `Sources/ContentView.swift` | Command palette: loop over `programaLayoutStore.savedLayouts` contributing `"Apply layout: <name>"` entries (mirror the `programaConfigStore.loadedCommands` loops at ~4334 and ~4714); `TabItemView` indent/fork-glyph rendering gated on `worktreeParentWorkspaceId`, added to the precomputed `let` params and the `==` function (do not read `tab.worktreeParentWorkspaceId` directly in body — typing-latency contract) |
| `Sources/TabManager.swift` | No new reorder implementation — locate and reuse the existing method backing `workspace.reorder` (CLI + `v2WorkspaceReorder`) to place a new worktree workspace adjacent to its parent after creation |
| `Resources/settings.schema.json` | New top-level `"worktrees": { "directory": {...} }` section, `additionalProperties: false`, matching existing section style (`"app"`, `"browser"`) |
| Settings parser (confirm exact file — `Sources/ProgramaSettingsFileStore.swift` or `Sources/KeyboardShortcutSettings.swift`, whichever owns `settings.schema.json` section parsing today) | Parse `worktrees.directory` into a small `WorktreeSettings` struct with a static accessor, default `~/.programa-worktrees` |
| `Resources/Localizable.xcstrings` | New EN+JA keys for command-palette layout entries (`"Apply layout: %@"` / subtitle `"Layout"`) and the sidebar worktree badge tooltip. No new dialog strings — v1 has no confirmation UI for worktree mutation (CLI/socket only) |
| `docs/v2-api-migration.md` | Add `worktree.*` / `layout.*` rows to "Method Parity Reference" (marked "new in v2, no v1 predecessor") |
| `docs/keyboard-shortcuts.md` | Explicit note: no new shortcuts in this feature (CLI + command palette only) — not an oversight |
| `GhosttyTabs.xcodeproj/project.pbxproj` | Manual registration (`PBXBuildFile` + `PBXFileReference` + group + Sources phase) for the 4 new Swift files |
| `CHANGELOG.md` | Entry under the next unreleased version |

### New test files (`tests_v2/`)

| File | Verifies |
|---|---|
| `tests_v2/test_worktree_create_and_list.py` | `worktree.create` against a temp git repo fixture; asserts no focus steal (mirror `test_workspace_create_initial_env.py`'s `current_workspace()` check); `worktree.list` shows it as open with correct `workspace_id` |
| `tests_v2/test_worktree_remove_never_deletes_branch.py` | create -> remove; branch still resolves via a follow-up `git branch --list`/`worktree.create` on the same name; workspace closed |
| `tests_v2/test_worktree_branch_already_checked_out_error.py` | second `worktree.create`/`worktree.open` for a branch already checked out in another worktree returns `branch_checked_out`, not a silent duplicate |
| `tests_v2/test_layout_save_apply_roundtrip.py` | build a 2-pane split workspace, `layout.save`, `layout.apply` into a new workspace, assert pane count/cwd/split ratio match |
| `tests_v2/test_layout_apply_resolves_cwd_relative_to_worktree.py` | save a layout with a relative `cwd`, then `worktree.create --layout`, assert the resulting terminal's cwd is under the new worktree root, not the CLI caller's cwd |

## CLI command specs

### `programa worktree create <branch> [--base <ref>] [--path <dir>] [--repo <dir>] [--layout <name>] [--focus]`

- `<branch>` (positional, required): if it already exists as a local branch, checkout it
  into the new worktree (`git worktree add <path> <branch>`); if it doesn't exist, create
  it from `--base` (default `HEAD`) via `git worktree add -b <branch> <path> <base>`.
- `--repo <dir>`: repo to operate on. Default: resolve `git rev-parse --show-toplevel`
  from the CLI process's own cwd (this is a shell-invoked CLI; it is not automatically the
  currently-selected workspace's cwd).
- `--path <dir>`: override default `<worktrees.directory>/<repo-name>/<branch-slug>`.
- `--layout <name>`: after the workspace is created (cwd = worktree path), apply the named
  layout with `baseCwd` = worktree root, so relative `cwd`s in the layout resolve inside
  the worktree.
- `--focus`: opt-in select/focus of the new workspace. Default false (socket focus
  policy — worktree create must not steal focus).
- Output (text): `OK worktree:<id>  <path>  (branch <branch>)`. `--json`: full worktree +
  workspace object.
- Errors: `not_a_git_repo`, `branch_checked_out` (branch already has a worktree elsewhere —
  detected via `git worktree list --porcelain` before calling `add`), `worktree_path_exists`
  (target path exists, non-empty, not already this worktree), `layout_not_found`,
  `git_command_failed` (git's stderr passed through verbatim).

### `programa worktree open <path-or-branch> [--repo <dir>] [--focus]`

- Resolves an existing worktree by absolute/relative path or by branch name (matched
  against `git worktree list`). Idempotent: if already open as a workspace, returns that
  `workspace_id` rather than duplicating.
- Errors: `worktree_not_found`.

### `programa worktree remove <path-or-branch> [--repo <dir>] [--force]`

- `git worktree remove [--force] <path>`. **Never deletes the branch** (explicit
  non-goal). Closes the associated workspace if currently open.
- `--force` is required (not implied) when the worktree has uncommitted changes — git's
  refusal message is surfaced as `worktree_dirty`, not silently retried with force.
- Errors: `worktree_not_found`, `worktree_dirty`, `git_command_failed`.

### `programa worktree list [--repo <dir>] [--json]`

- `git worktree list --porcelain` for the resolved repo, annotated per-entry with
  `is_open`/`workspace_id` by matching canonical directory path against open workspaces'
  `currentDirectory` (reuse `SidebarBranchOrdering.canonicalDirectoryKey`-style
  normalization already in `Sources/WorkspaceSidebarModels.swift` rather than a new
  path-normalization routine).

### `programa layout save <name> [--force]`

- Captures the current workspace via `Workspace.captureCustomLayout()`, writes
  `~/.config/programa/layouts/<name>.json`.
- Errors: `already_exists` (unless `--force`), `invalid_name` (must be filesystem-safe,
  no `/`).

### `programa layout apply <name> [--workspace <id|ref>] [--cwd <dir>]`

- If `--workspace` omitted, creates a new workspace first (cwd = `--cwd` or caller's cwd),
  then applies the layout into it — matches the `worktree create --layout` code path
  (shared `applyNamedLayout` helper).
- Errors: `not_found` (no such layout file).

### `programa layout list [--json]`

- `{layouts: [{name, savedAt}]}`.

## Socket API specs (`worktree.*`, `layout.*`)

All eight methods: parse/validate params off-main; the `git`/filesystem I/O itself runs
on a background queue inside `GitWorktreeManager`/`ProgramaLayoutStore` (already blocking
by construction, same as `GitMetadataProber`); `v2MainSync` is used only around the final
`tabManager.addWorkspace`/`closeWorkspace` call, matching the existing `v2WorkspaceCreate`
shape. None of the eight steal focus by default (socket focus policy) — `worktree.create`
and `worktree.open` accept `focus: bool` (default false), gated through the existing
`v2FocusAllowed()` check, same as `shouldFocus` in `v2WorkspaceCreate` today.

| Method | Params | Result | Errors |
|---|---|---|---|
| `worktree.create` | `{repo?, branch, base?, path?, layout?, focus?}` | `{worktree:{path,branch,repo}, workspace_id, workspace_ref, window_id, window_ref}` | `not_a_git_repo`, `branch_checked_out`, `worktree_path_exists`, `layout_not_found`, `git_command_failed` |
| `worktree.open` | `{repo?, path?, branch?, focus?}` (one of path/branch required) | same shape as create | `invalid_params`, `worktree_not_found` |
| `worktree.remove` | `{repo?, path?, branch?, force?}` | `{removed: true, closed_workspace_id?}` | `invalid_params`, `worktree_not_found`, `worktree_dirty`, `git_command_failed` |
| `worktree.list` | `{repo?}` | `{repo, worktrees:[{path,branch,head,is_open,workspace_id?,workspace_ref?}]}` | `not_a_git_repo` |
| `layout.save` | `{name, force?}` | `{name, path}` | `already_exists`, `invalid_name`, `no_active_workspace` |
| `layout.apply` | `{name, workspace_id?, cwd?}` | `{workspace_id, workspace_ref}` | `not_found` |
| `layout.list` | `{}` | `{layouts:[{name, savedAt}]}` | — |

## Layout file format

`~/.config/programa/layouts/<name>.json`:

```json
{
  "schemaVersion": 1,
  "name": "fullstack-dev",
  "savedAt": "2026-07-22T10:00:00Z",
  "layout": {
    "direction": "vertical",
    "split": 0.6,
    "children": [
      { "pane": { "surfaces": [ { "type": "terminal", "name": "server", "cwd": ".", "command": "npm run dev" } ] } },
      { "pane": { "surfaces": [ { "type": "terminal", "cwd": "./api" }, { "type": "browser", "url": "http://localhost:3000" } ] } }
    ]
  }
}
```

`layout` decodes with the exact `ProgramaLayoutNode`/`ProgramaSplitDefinition`/
`ProgramaPaneDefinition`/`ProgramaSurfaceDefinition` types already in
`Sources/ProgramaConfig.swift` — no new Codable schema. `cwd` values are stored relative
to the workspace's base cwd where possible (matching `ProgramaConfigStore.resolveCwd`'s
existing relative-path convention), which is what makes `worktree create --layout`'s
worktree-relative resolution work for free.

**v1 capture cuts (documented, not oversights):**
- `command`/`env`/`focus` are always omitted on `layout save` — there is no live signal
  for "what command is currently running" in a terminal panel, only its cwd. A saved
  layout reproduces pane geometry, cwds, and browser URLs; it does not replay startup
  commands. (`command` remains settable by hand-editing the JSON or via `programa.json`
  today, which stays the tool for that.)
- Markdown panels are skipped on capture — `ProgramaSurfaceType` only has
  `.terminal`/`.browser` today; adding `.markdown` is a natural follow-up but touches
  `Workspace+Layout.swift`'s populate/create switch statements and is out of scope for v1.

## Sidebar grouping approach

No existing grouping/tree affordance (see decision #4 above). v1:

1. `Workspace.worktreeParentWorkspaceId: UUID?` set at creation time by
   `v2WorktreeCreate`/`v2WorktreeOpen`.
2. Placement: after `tabManager.addWorkspace(...)`, reuse the existing reorder mechanism
   (backing `workspace.reorder`) to move the new workspace immediately after its parent
   (and after any existing worktree siblings) — adjacency in the flat `tabs` array *is*
   the grouping, no new tree data structure.
3. Rendering: `TabItemView` shows a small leading indent + branch-fork glyph when
   `worktreeParentWorkspaceId != nil`. Passed in as a precomputed `let` param (not read
   from `tab` in body) and added to the `Equatable` `==` — required by the typing-latency
   contract on this exact view (`CLAUDE.md` pitfall).
4. Parent resolution: match `--repo`'s canonical directory against open workspaces'
   `currentDirectory` (`SidebarBranchOrdering.canonicalDirectoryKey`). If no match, the
   worktree workspace still opens correctly — it's just inserted at the end, ungrouped.
5. **Cut for v1**: no collapse/expand, no drag-to-reparent, no nesting depth beyond one
   level, no persistent grouping across session restore reordering. If several worktrees
   share a repo, they simply sit adjacent to the parent in creation order.

## Numbered implementation plan

Two independent tracks (A, B) can run in parallel worktrees; C and D depend on both.

### Track A — git worktrees (~1–1.5 days)

1. **A1** `Sources/GitWorktreeManager.swift` — repo-root resolution, `git worktree
   add/list/remove --porcelain`, branch-slug derivation, "branch already checked out"
   pre-check. No callers yet; unit-testable in isolation. *(~3h)*
2. **A2** `Resources/settings.schema.json` + settings parser — `worktrees.directory`,
   default `~/.programa-worktrees`. *(~1h, parallelizable with A1)*
3. **A3** `Sources/Workspace.swift` — add `worktreeParentWorkspaceId`/`worktreeBranch`.
   *(~30m, parallelizable with A1/A2)*
4. **A4** `Sources/TerminalController+Worktree.swift` — the four `v2Worktree*` handlers,
   using A1 + A2 + A3, plus adjacency placement (locate/reuse the `workspace.reorder`
   backing method in `TabManager.swift`). Register cases in
   `Sources/TerminalController.swift`'s `processV2Command`. *(~4h, depends on A1–A3)*
5. **A5** `CLI/programa.swift` — `worktree` `CommandDescriptor` + `runWorktreeCommand`
   subcommand dispatch + detailed usage text. *(~2h, depends on A4 for method names/shapes
   but can be stubbed against the spec table above in parallel)*
6. **A6** `Sources/ContentView.swift` `TabItemView` indent/glyph + `==` update.
   *(~2h, depends on A3)*
7. **A7** pbxproj registration for `GitWorktreeManager.swift` +
   `TerminalController+Worktree.swift`; build via
   `xcodebuild -derivedDataPath /tmp/programa-worktree`. *(~30m, do this immediately after
   A1/A4 exist, not batched with Track B's files)*

### Track B — named layout configs (~1 day, parallelizable with Track A)

1. **B1** `Sources/ProgramaLayoutStore.swift` — list/load/save/remove + `FileWatcher` on
   `~/.config/programa/layouts/`. *(~2h)*
2. **B2** `Sources/Workspace+Layout.swift` — `captureCustomLayout()` (tree walk, reverse
   of the existing `applyCustomDividerPositions`) + shared `applyNamedLayout(name:
   baseCwd:store:)`. *(~3h)*
3. **B3** `Sources/TerminalController+Layout.swift` — `v2LayoutSave/Apply/List`, register
   cases in `processV2Command`. *(~2h, depends on B1+B2)*
4. **B4** `CLI/programa.swift` — `layout` `CommandDescriptor` + `runLayoutCommand`.
   *(~2h, depends on B3 for shapes, can stub in parallel)*
5. **B5** `Sources/ContentView.swift` — command palette contributions + handlers for
   saved layouts (mirror `programaConfigStore.loadedCommands` loops). *(~2h, depends on
   B1)*
6. **B6** `Resources/Localizable.xcstrings` — palette title/subtitle strings EN+JA.
   *(~30m)*
7. **B7** pbxproj registration for `ProgramaLayoutStore.swift` +
   `TerminalController+Layout.swift`; build. *(~30m)*

### Track C — integration (depends on A + B, ~2–3h)

1. **C1** `worktree.create --layout` wiring: `v2WorktreeCreate` calls
   `applyNamedLayout(name:baseCwd: worktreePath, store:)` (the same helper from B2/B3).
   *(~1h)*
2. **C2** `CLI worktree create --layout <name>` flag plumbing. *(~30m)*
3. **C3** Manual end-to-end pass on a tagged build (see Verification). *(~1h)*

### Track D — docs, tests, release hygiene (depends on A+B+C, ~half day)

1. **D1** `docs/v2-api-migration.md` — add the 7 new methods to the parity table.
   *(~30m)*
2. **D2** `docs/keyboard-shortcuts.md` — explicit "no new shortcuts" note. *(~10m)*
3. **D3** 5 new `tests_v2/` files (see table above). *(~3–4h — the layout-relative-cwd
   test depends on both tracks being merged)*
4. **D4** `CHANGELOG.md` entry. *(~10m)*

## Risks / unknowns

1. **Branch-already-checked-out detection** must happen *before* calling `git worktree
   add`, by parsing `git worktree list --porcelain` — git's own error message here is
   generic and shouldn't be relied on as the sole signal for the `branch_checked_out`
   error code.
2. **Repo resolution ambiguity**: the CLI process's cwd (used for `--repo` default) is
   the *caller's* shell cwd, not necessarily the currently-focused workspace's cwd, when
   invoked by an agent over the socket from an arbitrary directory. Must fail clearly
   (`not_a_git_repo`) rather than guessing.
3. **`git worktree remove` data loss**: must never auto-force; surface git's dirty-worktree
   refusal verbatim as `worktree_dirty` and require an explicit `--force`.
4. **Sidebar grouping is intentionally shallow** (order + badge, no tree) — flag this
   as a v1 simplification up front so it isn't mistaken for a bug; revisit only if there's
   demand for true nesting/collapse.
5. **Layout capture cannot recover startup commands** — only geometry/cwd/URLs are
   captured, not "what's currently running." Document this loudly in `layout save`'s
   CLI help text, not just in this plan.
6. **pbxproj is hand-maintained, not synchronized** — 4 new files each need 4 manual
   pbxproj edits (build file, file reference, group, Sources phase). Build after each
   file lands, not in a batch, to isolate which registration broke if the build fails.
7. **Command palette staleness**: `ProgramaLayoutStore` must be wired into the same
   `FileWatcher` + `ObservableObject` pattern `ProgramaConfigStore` already uses, or saved
   layouts won't appear in the palette until app restart.
8. **Concurrent worktree operations** (two agents creating worktrees in the same repo at
   once) — git serializes via its own `.git/worktrees` locking, expected to be safe, but
   not empirically verified here; call out for the e2e test pass.
9. **`worktree create --layout` is the highest-risk single call** — it composes two new
   subsystems (Track A + Track B) plus cwd-rebasing logic in one code path. Sequence its
   implementation (Track C) strictly after both tracks are independently verified working,
   not concurrently with either.

## Verification

**Build** (tagged, per `CLAUDE.md` — never bare `xcodebuild`/untagged `open`):

```bash
./scripts/reload.sh --tag worktree-layouts
# or, compile-only while iterating:
xcodebuild -project GhosttyTabs.xcodeproj -scheme programa -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath /tmp/programa-worktree-layouts build
```

**Manual test script** (temp git repo, tagged socket — override *both* `PROGRAMA_SOCKET`
and `PROGRAMA_SOCKET_PATH` per the tests-v2-socket-hijack lesson: running these from
inside a Programa terminal otherwise points at production):

```bash
tmp=$(mktemp -d) && cd "$tmp" && git init -q && git commit --allow-empty -qm init

export PROGRAMA_SOCKET=/tmp/programa-debug-worktree-layouts.sock
export PROGRAMA_SOCKET_PATH=/tmp/programa-debug-worktree-layouts.sock

programa-dev worktree create feature-x --repo "$tmp"
programa-dev worktree list --repo "$tmp"
programa-dev layout save my-layout
programa-dev layout list
programa-dev worktree remove feature-x --repo "$tmp"
git -C "$tmp" branch --list feature-x   # must still exist — worktree remove never deletes branches
```

**Tests** (never run locally — CI only, per `CLAUDE.md`):

```bash
gh workflow run test-e2e.yml
```

Add the 5 files listed in Track D3 to `tests_v2/`; they exercise a temp git repo fixture
plus the tagged socket, following the pattern in `tests_v2/test_workspace_create_initial_env.py`.

**Localization check**: `Resources/Localizable.xcstrings` has EN + JA for every new
command-palette string (per `CLAUDE.md` — no bare string literals in SwiftUI `Text()`).
