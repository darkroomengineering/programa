# Agent Diff Review Panel — Implementation Plan

Status: proposed, not started. Modeled on Warp's "Interactive Code Review" and the
herdr-reviewr plugin pattern. Read-only w.r.t. git; never mutates worktree/index/branches.

## 0. Research summary (what already exists, and what to mirror)

- **Panel protocol**: `Sources/Panels/Panel.swift` — every panel conforms to `Panel`
  (`@MainActor`, `ObservableObject`, `Identifiable`). `PanelType` enum (`Sources/Panels/Panel.swift:7`)
  currently has `.terminal`, `.browser`, `.markdown`. A new `.review` case is a **source-breaking
  addition** — every exhaustive `switch panel.panelType` in the codebase must gain a case (see
  §2 "switch sites").
- **Closest analog**: `Sources/Panels/MarkdownPanel.swift` (model, read-only, file-watcher-driven
  reload) + `Sources/Panels/MarkdownPanelView.swift` (SwiftUI view, focus-flash overlay,
  find-in-content overlay pattern) + `Sources/Panels/MarkdownDocumentView.swift` (rendering
  boundary, keeps the concrete renderer — MarkdownUI — private to one file).
- **No syntax highlighter dependency exists.** `GhosttyTabs.xcodeproj/project.pbxproj` declares
  exactly two SPM packages: Sparkle (updates) and `swift-markdown-ui` (MarkdownUI, used only by
  `MarkdownDocumentView.swift`). MarkdownUI's own `codeBlock` config in that file does **not**
  tokenize/colorize code — it's monospace text on a background tint, no per-language highlighting.
  Confirms: v1 of this feature must not assume a highlighter is available. See §3.
- **Panel creation (split) pattern**: `Workspace+Surfaces.swift:561` `newMarkdownSplit(from:orientation:insertFirst:filePath:focus:)`
  — resolves the source pane from a panel id via `bonsplitController`, constructs the panel,
  registers it in `panels`/`panelTitles`/`surfaceIdToPanelId`, builds a `Bonsplit.Tab`, calls
  `bonsplitController.splitPane`, handles focus preservation, and installs a title-sync
  subscription (`installMarkdownPanelSubscription`, `Workspace.swift:728`, a Combine sink on
  `$displayTitle` that pushes into the Bonsplit tab title). **Mirror this exactly** for
  `newReviewSplit`.
- **Socket command pattern**: `TerminalController+BrowserAutomation.swift:578` `v2MarkdownOpen(params:)`
  — validates params off the `v2MainSync` hop where possible, resolves workspace/pane inside
  `v2MainSync`, creates the split, returns `window_id/_ref, workspace_id/_ref, pane_id, surface_id/_ref`.
  Dispatched from `TerminalController.swift:1894` (`case "markdown.open":`) and listed in
  `V2CommandCatalog.swift:112`. **Mirror this** for `review.open`.
- **send_text (for "send to agent")**: `TerminalController+Surface.swift:877` `v2SurfaceSendText`
  — resolves workspace/surface inside `v2MainSync`, requires the panel to be a `TerminalPanel`,
  calls `sendSocketText(text, surface:)` (attached surface) or `terminalPanel.sendText(text)`
  (detached/background surface), then `terminalPanel.surface.forceRefresh(reason:)`. The review
  panel's "Send to agent" action reuses this exact code path in-process (no new socket
  round-trip needed for the in-app button; the socket method `review.send_comments` wraps the
  same call for CLI/automation use — see §2 API).
- **Agent activity state**: `Sources/AgentActivityState.swift` defines `.working/.blocked/.idle`.
  The single main-thread mutation point is `Workspace+SidebarTelemetry.swift:163`
  `updatePanelAgentState(panelId:state:)` (and `:180` `clearPanelAgentState`), which fan out to
  `AgentStateWaitRegistry.shared.notify` (one-shot wait registry, used by `surface.wait`/`agent.prompt`)
  and `SocketEventBroadcaster.shared.publishAgentState` (the `subscribe` pub/sub fan-out).
  `Workspace.panelAgentStates` (`Workspace.swift:111`) is `@Published var panelAgentStates: [UUID:
  AgentActivityState]`, so **the cheapest, most idiomatic auto-refresh trigger is a Combine
  subscription on `workspace.$panelAgentStates` filtered to the associated terminal surface's id**,
  detecting a `.working -> .idle` (or "reported -> idle") edge — no new registry, no polling. This
  is installed the same way `installMarkdownPanelSubscription`/`installBrowserPanelSubscription`
  are installed today (`Workspace.swift`).
- **Git subprocess pattern**: `Sources/GitMetadataProber.swift` is a `struct` namespace, fully
  `nonisolated static`, with a private `runCommandResult(directory:executable:arguments:timeout:)`
  helper that resolves the executable via `$PATH` + fallback dirs, runs `Process` with stdout/stderr
  `Pipe`s, uses a `DispatchSemaphore` + `terminationHandler` for optional timeout, and returns a
  `CommandResult(stdout:stderr:exitStatus:timedOut:executionError:)`. **Reuse this exact shape**
  for git-diff invocation (new sibling type, not a modification of `GitMetadataProber` itself, to
  keep it stateless/independent per its own header comment).
- **Working directory resolution**: `Workspace.panelDirectories[UUID]` (set at
  `Workspace.swift:1619` from `report_pwd`) gives the associated terminal surface's current
  working directory — this is the anchor for `git diff` invocations. No separate
  "repo root" concept exists yet; `git rev-parse --show-toplevel` from that cwd is the way to
  find it (also gives a clean "not a git repo" signal).
- **pbxproj is NOT filesystem-synchronized** (`PBXFileSystemSynchronizedRootGroup` absent from
  `project.pbxproj` — confirmed by grep). Every new source file needs **four** manual edits to
  `GhosttyTabs.xcodeproj/project.pbxproj`: a `PBXBuildFile` entry, a `PBXFileReference` entry, a
  `PBXGroup.children` entry (in the `Panels` group for panel files, `CLI` group for CLI files), and
  a `PBXSourcesBuildPhase.files` entry. `MarkdownPanel.swift` appears in exactly these 4 places —
  use it as the template (`project.pbxproj:133,472,892,1332`).
- **CLI command pattern**: `CLI/CLI+Markdown.swift` (arg parsing: workspace/window/surface/direction
  flags, path resolution, `client.sendV2(method:params:)`) + registration in
  `CLI/programa.swift` `commandDescriptors()` (`CommandDescriptor(names:helpLines:execute:)`, e.g.
  `programa.swift:3885` for `markdown`) + a validation-only case in the argument-validation switch
  (`programa.swift:5612` `case "markdown":`).
- **Switch sites requiring a new `.review` case** (exhaustive `switch panel.panelType` /
  `switch panelType`across the codebase — confirmed via grep for `.markdown` case sites):
  1. `Sources/Panels/PanelContentView.swift:48` — view dispatch (`case .markdown:` -> add `case .review:`)
  2. `Sources/ContentView+CommandPalette.swift:544` — `commandPaletteSurfaceKindLabel(for:)`
  3. `Sources/ContentView+CommandPalette.swift:554` — `commandPaletteSurfaceKeywords(for:)`
  4. `Sources/Workspace+Persistence.swift:273` — session-save snapshot builder
  5. `Sources/Workspace+Persistence.swift:457` — session-restore panel rebuild
  6. `Sources/Workspace.swift:795` — `surfaceKind(for:)` (maps to `SurfaceKind.*` string, `Workspace.swift:256`)
  Also check `Sources/TabItemView.swift:1920` (`entry.format == .markdown` — a different enum,
  `SessionPanelSnapshot`/format-related, not `PanelType`; verify during implementation whether it
  needs a parallel branch).

## 1. Scope decision for v1 (lean cut)

Per the task's own steer, v1 keeps:
- Per-file collapsible diff (uncommitted worktree vs HEAD, or whole-branch vs merge-base).
- Click-a-line (or shift-click a range) to attach a comment card. Comments accumulate in a
  sidebar list.
- "Send to agent" — serializes pending comments, sends via the existing `surface.send_text` path,
  clears sent comments.
- Manual refresh + auto-refresh on the associated surface's agent state transitioning to idle.
- Binary/huge file row ("not diffable", skip content).
- **No syntax highlighting in v1** (see §3) — diff is rendered as colored +/- lines in a
  monospace font (git's own coloring model: green add / red remove / gray context), which needs
  zero new dependencies and is what most terminal diff tools show anyway. Add a note in the plan
  for a v1.1 follow-up (see §5) if per-language tokenization is wanted later.
- **No drag-selection UX** — v1 comment attachment is click a line number to toggle a comment
  input inline under that line; shift-click extends to a range. This avoids building a custom
  text-selection gesture recognizer in SwiftUI over a non-native-text view.

Cut from v1, tracked as follow-ups: word-level diff highlighting inside a changed line, diff
against an arbitrary ref (not just HEAD/merge-base), multi-surface/multi-repo review panels,
resolving/dismissing individual comments without sending, comment editing after creation.

## 2. Proposed socket / CLI API surface

### `review.open`

Opens (or re-focuses, see idempotency note) a Diff Review panel split beside a terminal surface.
Mirrors `markdown.open`'s param/response shape.

| Field | Type | Required | Notes |
|---|---|---|---|
| `surface_id` | string (id or ref) | no | Source terminal surface to review + split from. Defaults to the focused surface in the resolved workspace. Its `panelDirectories` entry supplies the git working directory. |
| `workspace_id` / `window_id` | string | no | Same resolution as other `surface.*`/`markdown.*` methods. |
| `mode` | string | no | `"worktree"` (default) — diff vs HEAD, includes uncommitted changes. `"branch"` — diff vs merge-base with `base_branch`. |
| `base_branch` | string | no | Only used when `mode: "branch"`. Default `"origin/main"`. |
| `direction` | string | no | Split direction, default `"right"` (matches `markdown.open`). |

Response (`ok: true`): same shape as `markdown.open` — `window_id/_ref, workspace_id/_ref,
pane_id/_ref, surface_id/_ref` (the new review panel's id/ref) plus `source_surface_id/_ref` (the
terminal it's reviewing) and `diffable_file_count`.

Errors: `not_found` (no focused surface / source surface not found), `invalid_params` (bad `mode`),
`unavailable` (resolved directory is not inside a git worktree — `git rev-parse --show-toplevel`
fails).

### `review.refresh`

Re-runs the diff for an existing review panel. No params beyond surface resolution
(`surface_id` = the *review panel's own* id, or `workspace_id` to target its focused review
panel). Response: `{"file_count": N, "diffable_file_count": M, "generated_at": <unix ts>}`.

### `review.comment.add`

| Field | Type | Required |
|---|---|---|
| `surface_id` | review panel id/ref | yes (or workspace-focused-review-panel fallback) |
| `file_path` | string, repo-relative | yes |
| `start_line` / `end_line` | int (1-based, in the *new*/right-hand file for additions and context; see §4 for how removed-line ranges are addressed) | yes |
| `text` | string | yes |

Response: `{"comment_id": "..."}`.

### `review.comment.remove`

`{"surface_id": ..., "comment_id": "..."}` -> `{"ok": true}`. (Not exposed in v1 UI as a
requirement, but trivial to add alongside `add`, and useful for CLI/test cleanup.)

### `review.comment.list`

`{"surface_id": ...}` -> `{"comments": [{"id", "file_path", "start_line", "end_line", "text",
"created_at"}]}`.

### `review.send_comments`

Serializes all pending comments (see §4 format) and sends them into the *source* terminal
surface via the same path `surface.send_text` uses, then clears the sent comments from the panel.

| Field | Type | Required |
|---|---|---|
| `surface_id` | review panel id/ref | yes (or workspace-focused fallback) |
| `preamble` | string | no — override the default preamble text |

Response: `{"sent_count": N, "target_surface_id": "...", "target_surface_ref": "..."}`. Error
`not_found` if the review panel has no pending comments (mirrors "nothing to do" — return
`sent_count: 0`, not an error, so scripted callers don't need special-case handling) — actually:
returns `ok: true, sent_count: 0` rather than an error, since sending zero comments is a no-op,
not a failure.

### CLI surface

`CLI/CLI+Review.swift` (new), registered in `programa.swift`'s `commandDescriptors()`:

```
programa review open [--workspace <id|ref|index>] [--surface <id|ref|index>] [--window <id|ref|index>]
                      [--direction left|right|up|down] [--mode worktree|branch] [--base-branch <ref>]
programa review refresh [--surface <id|ref|index>]
programa review comment add <file> <start>[-<end>] <text> [--surface <id|ref|index>]
programa review comment remove <comment-id> [--surface <id|ref|index>]
programa review comment list [--surface <id|ref|index>]
programa review send [--surface <id|ref|index>] [--preamble <text>]
```

Follows `CLI+Markdown.swift`'s flag-parsing/help-text/error-message conventions exactly (see
`runMarkdownCommand`, `markdownSubcommandUsage`). Add a `"review"` case to the CLI's
argument-validation switch (`programa.swift:5612` area) mirroring the `"markdown"` case.

### Socket command threading

Per repo policy (root `CLAUDE.md` "Socket command threading policy"): `review.comment.add/remove/list`
are pure in-memory metadata mutations on the review panel's own `@Published` array — off-main
validation/parsing, `DispatchQueue.main.async` for the mutation, same shape as the
`workspace.set_status`-family methods. `review.open`/`review.refresh` mutate UI (panel
creation, git subprocess kick-off) so they run their core logic inside `v2MainSync` like
`markdown.open`, but the actual `git diff` subprocess call itself must NOT block the main thread
(see §3 — kick off async, publish result back via `@Published` on the main actor when done).
`review.send_comments` reuses `v2SurfaceSendText`'s existing threading, which is already
main-actor-scoped for the terminal-mutation part.

### Focus policy

Per repo policy ("Socket focus policy"): `review.open` is the one focus-intent command in this
family (creating and displaying a new split is inherently a focus-intent operation, exactly like
`markdown.open`/`browser.open_split` today — `v2FocusAllowed()` gate already used by
`newMarkdownSplit`'s `focus:` param). `review.refresh`, `review.comment.*`, and
`review.send_comments` must NOT steal focus or change window/workspace selection — they mutate
data on an existing panel only.

## 3. Diff acquisition, parsing, and highlighting strategy

### Git invocation

New file `Sources/ReviewDiffProber.swift` (stateless namespace, same shape as
`GitMetadataProber`— do not add this to `GitMetadataProber` itself, since that file's header
comment explicitly scopes it to sidebar git/PR metadata):

- `nonisolated static func diffSnapshot(directory: String, mode: ReviewDiffMode) -> ReviewDiffSnapshot`
  runs, off the main thread (called from a background `DispatchQueue.global(qos: .userInitiated)`
  or a dedicated serial queue owned by the panel, not `v2MainSync`):
  1. `git rev-parse --show-toplevel` from `directory` — failure means "not a git repository";
     surface as a panel-level empty state, not a crash.
  2. `mode == .worktree`: `git diff --no-color --find-renames HEAD` (tracked, uncommitted changes)
     — this alone misses untracked new files, so also run
     `git ls-files --others --exclude-standard` and synthesize a pseudo-diff entry per untracked
     file (label it "new file", and skip content if binary/huge — see below — rather than trying
     to diff against `/dev/null` through git, which needlessly dumps entire file contents through
     the diff parser).
  3. `mode == .branch`: resolve merge-base with `git merge-base HEAD <base_branch>`, then
     `git diff --no-color --find-renames <merge-base>..HEAD`. If `base_branch` doesn't resolve
     (no such remote-tracking ref), return a specific "unknown base branch" error rather than a
     generic git failure, so the CLI/UI can say something actionable.
  4. Binary detection: `git diff --numstat` reports `-\t-\t<path>` for binary files — use this
     pass (cheap, single extra invocation) to build a binary-file set *before* parsing the full
     diff text, so binary entries can be filtered out of the unified-diff parse and rendered as
     a dedicated "not diffable" row with file size (`stat`) instead.
  5. Size cap: files whose diff hunk text exceeds a constant (`ReviewDiffProber.maxDiffBytesPerFile
     = 400_000`, tune during implementation) are also treated as "not diffable — too large" rather
     than rendered in full, to keep the SwiftUI diff view responsive.
  - Reuse `GitMetadataProber`'s private `runCommandResult`/`resolvedCommandPath` shape (copy, not
    share — it's `private` in that file and the two namespaces should stay independently
    testable) including its timeout-via-semaphore pattern; default timeout ~5s per invocation
    matching `workspacePullRequestProbeTimeout`.

### Parsing

New file `Sources/ReviewDiffParser.swift` — pure value-type parser, `nonisolated`, fully unit
testable without any git process (feed it canned unified-diff text):
- Parses unified diff output into `[ReviewFileDiff]`, each with `oldPath`, `newPath` (rename
  support), `status` (`added/modified/deleted/renamed`), and `[ReviewHunk]`.
- Each `ReviewHunk` holds `[ReviewDiffLine]` with `kind` (`.context/.addition/.deletion`),
  `oldLineNumber: Int?`, `newLineNumber: Int?`, and `text`.
- No third-party diff-parsing library needed — the unified diff format's grammar (`@@ -l,s +l,s @@`
  hunk headers, `+`/`-`/` ` line prefixes) is simple enough to hand-parse in ~150-250 lines, and
  pulling in a new SPM dependency for this is not justified for v1.

### Syntax highlighting

**v1 ships without per-language tokenization**, for two reasons: (1) no highlighter dependency
exists in the project today (confirmed above), and (2) MarkdownUI's own code blocks don't
highlight either, so there's no existing in-app precedent to extend. v1 renders diff line
backgrounds only (git's traditional red/green/gray), monospace font, in a plain SwiftUI `Text`/
`LazyVStack` per line — no `NSAttributedString` tokenizer needed.

If per-language highlighting is wanted later (v1.1+), the two real options to evaluate then:
1. Add `Splash` (SPM, MIT, Swift-only, but Swift-language-only tokenizer — wrong fit for a
   multi-language diff viewer).
2. Add `Highlightr` (SPM, wraps highlight.js via JavaScriptCore — broad language coverage, but
   pulls in a JS engine dependency and a large bundled language-grammar payload).
   This is the more realistic pick if/when it's prioritized, given the app is macOS-only where
   JavaScriptCore is already available system-side (no bundling of a JS runtime itself, just
   the bundled `.js` grammar/theme assets). Out of scope for this plan.

### Refresh triggers

1. **Manual**: `review.refresh` socket call, plus a toolbar refresh button in `ReviewPanelView`.
2. **Auto, on agent idle**: `ReviewPanel` holds a Combine subscription (installed the same way
   `installMarkdownPanelSubscription` is installed in `Workspace.swift`, called
   `installReviewPanelSubscription`) on `workspace.$panelAgentStates`, mapped to the *source*
   terminal surface's id, `.removeDuplicates()`, watching for a transition where the previous
   value was `.working` and the new value is `.idle` (or the state clears) — i.e. "the agent just
   stopped working" — and calls the same refresh path `review.refresh` uses. This deliberately
   does NOT refresh on every keystroke/state change, only the working-to-idle edge, to avoid
   thrashing `git diff` on a fast-moving CLI session.
3. Refresh reruns the full `diffSnapshot` off-main and republishes `@Published var files:
   [ReviewFileDiff]` on the main actor when done; existing per-file collapse state and comments
   are preserved by matching on file path across refreshes (comments on a since-deleted file/line
   range are kept but flagged "line range may have shifted" rather than silently dropped — dropping
   user-authored comments on a background refresh would be a bad surprise).

## 4. Data model and serialization format

### `ReviewComment` (new file, `Sources/Panels/ReviewComment.swift`)

```swift
struct ReviewComment: Identifiable, Codable, Equatable {
    let id: UUID
    var filePath: String       // repo-relative path
    var startLine: Int         // 1-based, right-hand-side (new file) line numbering
    var endLine: Int           // inclusive; == startLine for a single-line comment
    var text: String
    let createdAt: Date
}
```

Line numbering convention: comments always address the **new-file line numbers** (the
right-hand/`+` side), including for context lines. For a pure deletion (no corresponding new-file
line), the comment addresses the nearest preceding new-file line and the serialized format notes
it as a deletion-adjacent comment (`path:N (before deleted lines) — comment`) — this avoids
needing negative/old-side line addressing in the wire format, at a small precision cost that's
acceptable for v1 (an agent reading `path:41-43` can trivially locate the right hunk even if the
exact deleted-line anchor is approximate).

### Serialization sent to the agent

`ReviewCommentSerializer.serialize(comments:) -> String` (pure function, unit-testable):

```
Code review comments (3):

src/foo.swift:12-14 — this branch never runs when `x` is nil, please add a guard
src/bar.swift:41 — typo: "recieve" -> "receive"
tests/baz_test.py:88-92 — this test doesn't actually assert anything after the mock reset
```

- Preamble line + blank line, then one `path:start-end — text` line per comment (or `path:line`
  when `start == end`), grouped in file-then-line order regardless of the order comments were
  created in (stable, scannable output for the agent).
- `text` is single-line-normalized (embedded newlines replaced with `" / "`) so the whole
  serialization stays trivially line-parseable if an agent or test wants to re-split it.
- This exact string is what `review.send_comments` passes as `text` to the same call
  `surface.send_text` uses (`terminalPanel.sendText` / `sendSocketText`), with `Enter` submitted
  after it as `agent.prompt` does for its own text.

## 5. Risks / unknowns

1. **Line-range comment UX without a custom text view.** Diff lines will most likely render as a
   `LazyVStack` of per-line `Text`/`HStack` rows (not a single selectable text blob), so
   "select a line range" becomes "click a line number, shift-click extends" rather than native
   drag-selection. This is deliberately the v1 cut (§1) — flag to the user/implementer early if a
   drag-selection gesture is actually required for v1, since that's materially more work (a custom
   `NSViewRepresentable` gesture recognizer over per-line hit targets).
2. **Comment anchoring across refresh.** If the user edits code while comments are pending (before
   sending), a refresh can shift line numbers under existing comments. §3 point 3 covers the
   mitigation (match by file path, flag rather than drop) but this is inherently best-effort, not
   exact — worth calling out in the UI copy ("line numbers may have shifted since this comment was
   added") rather than promising precision.
3. **Untracked file diffing cost.** Large untracked directories (e.g. a fresh `node_modules`
   accidentally not gitignored) could make the `git ls-files --others` pass slow/huge. Mitigate
   with the same "not diffable — too large" cap applied to untracked files' size, checked via
   `stat` before reading content.
2. **New `PanelType` case is source-breaking across 6 switch sites** (§0 list) — every one must be
   updated in the same PR or the build fails outright (Swift exhaustive switch), which is good
   forcing-function but means this cannot be split into a "just add the panel type" PR followed by
   "wire it up" — it's one atomic change for the enum + all switches.
4. **`git` binary resolution on machines without Xcode CLT / with a customized PATH.** Mirror
   `GitMetadataProber.resolvedCommandPath`'s fallback-directory search (`/opt/homebrew/bin`,
   `/usr/local/bin`, etc.) rather than assuming `/usr/bin/git` — same risk `GitMetadataProber`
   already carries and already mitigates.
5. **pbxproj hand-editing is error-prone.** Four new files (`ReviewPanel.swift`,
   `ReviewPanelView.swift`, `ReviewDiffProber.swift`, `ReviewDiffParser.swift`, `ReviewComment.swift`,
   `ReviewCommentSerializer.swift`, `CLI+Review.swift` — actually seven) each need 4 pbxproj edits
   = 28 manual edits with fresh unique hex IDs. Recommend generating IDs with a small script or
   very carefully copy-pasting the `MarkdownPanel.swift` 4-site pattern per file and verifying with
   a build immediately after each file is wired in, rather than batching all 7 and debugging a
   build failure across all of them at once.
6. **Whole-branch mode default (`origin/main`) may not match the repo's actual default branch**
   (some repos use `main` locally without an `origin` remote, or use `master`, or a
   `trunk`-style name). `git merge-base HEAD origin/main` failing should fall back to trying
   local `main`, then `master`, before surfacing the "unknown base branch" error — small UX
   nicety worth building in from the start rather than patching later once someone hits it.

## 6. Implementation plan (numbered, dependency-ordered, with parallelizable groups)

Effort estimates assume one implementer, familiar with the codebase; add ~30% if new to it.

### Phase A — Data model + parsing (no UI, no pbxproj panel-type risk yet; fully unit-testable)
Can be done in parallel by two implementers (A1+A2 vs A3) since they don't share files.

1. **(30 min)** Create `Sources/ReviewComment.swift` — the struct in §4, plus
   `Sources/ReviewCommentSerializer.swift` — the serializer in §4. Both are pure value types/pure
   functions, no `Panel`/AppKit/Foundation-process dependencies beyond `Foundation.Date`/`UUID`.
2. **(2-3 hr)** Create `Sources/ReviewDiffParser.swift` — unified-diff-text -> `[ReviewFileDiff]`
   parser per §3. Write it against canned diff text fixtures first (this is naturally
   test-first: feed known `git diff` output samples, assert parsed structure).
3. **(2-3 hr)** Create `Sources/ReviewDiffProber.swift` — git subprocess invocation per §3,
   mirroring `GitMetadataProber`'s process-running helper. Depends on nothing else in this list;
   parallel with step 2.
4. Register all 3 new files in `GhosttyTabs.xcodeproj/project.pbxproj` (4 edits each — PBXBuildFile,
   PBXFileReference, PBXGroup children under the top-level `Sources` group or a new `Review`
   subgroup, PBXSourcesBuildPhase). Build with the tagged `xcodebuild` command after each file to
   catch registration mistakes immediately (see §5 risk 5).

### Phase B — Panel model + PanelType wiring (the atomic, source-breaking step)
Sequential — do not parallelize, since every sub-step touches the same enum/switch surface.

5. **(1-2 hr)** Add `case review` to `PanelType` (`Sources/Panels/Panel.swift:7`). Add
   `case reviewPanel(...)` or reuse `.panel` to `PanelFocusIntent` only if review needs its own
   focus intent beyond generic `.panel` (likely not needed for v1 — no text field/webview focus
   concerns beyond the inline comment `TextField`, which can piggyback on `.panel`).
6. **(3-4 hr)** Create `Sources/Panels/ReviewPanel.swift` — the `Panel`-conforming
   `ObservableObject`, modeled directly on `MarkdownPanel.swift`:
   - `let id: UUID`, `let panelType: PanelType = .review`
   - `let workspaceId: UUID`, `let sourceSurfaceId: UUID` (the terminal being reviewed),
     `let directory: String` (from `panelDirectories[sourceSurfaceId]` at creation time)
   - `@Published private(set) var mode: ReviewDiffMode`, `var baseBranch: String`
   - `@Published private(set) var files: [ReviewFileDiff] = []`
   - `@Published private(set) var comments: [ReviewComment] = []`
   - `@Published private(set) var isRefreshing: Bool = false`
   - `@Published private(set) var lastError: String? = nil`
   - `@Published private(set) var displayTitle: String` ("Review: <branch/mode>")
   - `func refresh()` — kicks off `ReviewDiffProber.diffSnapshot` on a background queue, publishes
     back on main.
   - `func addComment(filePath:startLine:endLine:text:) -> ReviewComment`
   - `func removeComment(id:)`
   - `func serializedPendingComments() -> String` (calls `ReviewCommentSerializer`)
   - `func clearSentComments()`
   - `focus()/unfocus()/close()/triggerFlash(reason:)` — mirror `MarkdownPanel`'s mostly-no-op
     implementations (read-only panel, no first-responder surface of its own beyond the comment
     text field).
7. **(2-3 hr)** Add `newReviewSplit(from:orientation:insertFirst:mode:baseBranch:focus:)` to
   `Sources/Workspace+Surfaces.swift`, copied from `newMarkdownSplit` (§0) — same pane resolution,
   panel registration, `Bonsplit.Tab` construction (`kind: SurfaceKind.review` — add this constant
   to `Workspace.swift:256`'s `SurfaceKind` enum alongside `.markdown`), split call, focus handling.
   Add `installReviewPanelSubscription(_:)` to `Workspace.swift` per §3's auto-refresh design
   (mirrors `installMarkdownPanelSubscription` at `Workspace.swift:728`, but subscribes to
   `$panelAgentStates` filtered to `sourceSurfaceId` instead of `$displayTitle`).
8. **(2-3 hr)** Update the 6 switch sites from §0:
   - `PanelContentView.swift:48` — add `case .review:` rendering `ReviewPanelView` (stub view OK
     temporarily, real view lands in Phase C).
   - `ContentView+CommandPalette.swift:544,554` — label + keywords for `.review`.
   - `Workspace+Persistence.swift:273,457` — session snapshot save/restore. Session-restoring a
     review panel re-runs `git diff` fresh on restore rather than persisting stale diff content —
     simpler and always-correct, at the cost of comments-in-flight not surviving an app restart
     for v1 (acceptable; flag as a known limitation, not a bug).
   - `Workspace.swift:795` — `surfaceKind(for:)` returns `SurfaceKind.review`.
   - Check `TabItemView.swift:1920` — confirm whether it's keyed on `PanelType` or a different
     enum (`SessionPanelSnapshot` format); add a branch only if actually needed.
9. Register `ReviewPanel.swift` in pbxproj (4 edits, same caution as step 4). Build.

### Phase C — SwiftUI view (depends on Phase B's `ReviewPanel` model)

10. **(4-6 hr)** Create `Sources/Panels/ReviewPanelView.swift` — modeled on
    `MarkdownPanelView.swift`'s structure (focus-flash overlay via `PhaseAnimator`, pointer
    observer for focus-on-click):
    - Header: source surface path/branch, mode toggle (worktree/branch), refresh button.
    - Per-file collapsible section (disclosure group), one per `ReviewFileDiff`; binary/huge
      files render a fixed "not diffable" row (icon + reason + size) with no expand affordance.
    - Per-line rendering: line-number gutter (click = start/extend comment; shift-click = extend
      range), `+`/`-`/context background tinting, monospace text — no tokenization (§3).
    - Inline comment composer: appears under the selected line range when the user starts typing;
      "Add comment" / "Cancel" buttons.
    - Comment list sidebar or inline markers (implementer's call at build time — inline markers
      under the relevant diff lines is simplest and avoids a second scrollable pane).
    - "Send to agent" button/toolbar item — calls `ReviewPanel.serializedPendingComments()` then
      the send-text path, then `clearSentComments()`.
11. **(1 hr)** Add all new user-facing strings to `Resources/Localizable.xcstrings` (English +
    Japanese) — panel title, empty states, "not diffable" reasons, button labels, mode toggle
    labels, comment composer placeholder text. Per repo policy, no bare string literals anywhere
    in `ReviewPanelView.swift`.
12. Register `ReviewPanelView.swift` in pbxproj. Build + `reload.sh --tag review-panel-v1` for
    manual visual iteration (see §7).

### Phase D — Socket API (depends on Phase B's model + `newReviewSplit`)
Can run in parallel with Phase C once Phase B is done — different files.

13. **(3-4 hr)** Create `Sources/TerminalController+Review.swift` with `v2ReviewOpen`,
    `v2ReviewRefresh`, `v2ReviewCommentAdd`, `v2ReviewCommentRemove`, `v2ReviewCommentList`,
    `v2ReviewSendComments` — each mirroring `v2MarkdownOpen`'s and `v2SurfaceSendText`'s exact
    patterns from §0/§2, with the threading split called out in §2's "Socket command threading"
    subsection (metadata ops off-main + `.main.async` mutate; `open`/`refresh` inside `v2MainSync`
    for the panel-creation part, git subprocess kicked off async).
14. **(30 min)** Wire the 6 new `case "review.*":` entries into `TerminalController.swift`'s
    dispatch switch (near `TerminalController.swift:1894`, alongside `markdown.open`).
15. **(15 min)** Add the 6 new method names to `V2CommandCatalog.swift` (alongside `markdown.open`
    at line 112) and to `docs/v2-api-migration.md`'s method reference (a new "Review" section,
    mirroring the existing "Markdown" section's one-liner + a fuller `### review.open (#<issue>)`
    style subsection like `surface.wait`/`agent.prompt` get, given this is a materially bigger API
    than markdown's single method).
16. Register `TerminalController+Review.swift` in pbxproj.

### Phase E — CLI (depends on Phase D's socket methods existing)

17. **(2-3 hr)** Create `CLI/CLI+Review.swift` — `runReviewCommand` dispatching `open/refresh/
    comment/send` subcommands, following `CLI+Markdown.swift`'s flag-parsing conventions exactly
    (§2's CLI surface spec). Add `reviewSubcommandUsage(_:)` help text function.
18. **(30 min)** Register the `"review"` `CommandDescriptor` in `programa.swift`'s
    `commandDescriptors()` (near the `"markdown"` entry, `programa.swift:3885`) and add a
    `case "review":` to the argument-validation switch (`programa.swift:5612` area).
19. Register `CLI+Review.swift` in pbxproj (note: `CLI/` files may live in a separate pbxproj
    group/target from `Sources/` — verify against `CLI+Markdown.swift`'s existing entries before
    assuming the same 4-edit shape/target membership).

### Phase F — Keyboard shortcut + command palette + Settings wiring
Can run in parallel with Phase E.

20. **(1-2 hr)** Add `case openReview` (or similar) to `KeyboardShortcutSettings.Action`
    (`Sources/KeyboardShortcutSettings.swift:15`-area enum), its `label` string
    (`String(localized:)`), and its default key equivalent (find the analogous switch for default
    key bindings in the same file — not yet located in this research pass; **implementer must grep
    `KeyboardShortcutSettings.swift` for how `.openBrowser`'s default binding is defined and mirror
    it exactly** before finalizing this step — flagged as a research gap, not a design decision,
    see §5-adjacent note below).
21. **(30 min)** Verify the action surfaces automatically in `Settings → Keyboard Shortcuts`
    (likely automatic via `Action: CaseIterable`) and appears in `~/.config/programa/settings.json`
    support (check `KeyboardShortcutSettingsFileStore` — likely also automatic via the same
    enum-driven mechanism, but confirm during implementation).
22. **(30 min)** Wire a command palette entry ("Open Review Panel" / similar) — likely in
    `ContentView+CommandPalette.swift`'s command list construction, alongside how `openBrowser`/
    `markdown` (if present) show up today; and the actual shortcut handler dispatch (likely
    `AppDelegate.swift` or `ContentView.swift`'s keyboard shortcut action switch) needs a case
    calling `newReviewSplit` for the currently focused terminal surface.
23. **(15 min)** Add the new shortcut to `docs/keyboard-shortcuts.md` (new "Review" section,
    following the existing table format shown in that file).
24. **(30 min, optional per task description "ideally")** Add a small button/affordance near the
    agent status badge UI (`TabItemView.swift`'s agent-state badge rendering, or
    wherever `aggregateAgentState`/`panelAgentStates` currently render a badge) that opens the
    review panel for that surface — nice-to-have, cut first if time-constrained.

### Phase G — Tests

25. **(2-3 hr)** `tests_v2/test_review_diff_panel.py` (new) — CLI-driven, following the pattern in
    `tests_v2/test_browser_cli_agent_port.py` (§0): spin up a scratch git repo in a temp dir
    (`git init`, one commit, then dirty the worktree), point a terminal surface's cwd at it via
    `report_pwd` or by launching a surface with that cwd, call `programa review open`, assert the
    response shape (`surface_id`, `pane_id`, `diffable_file_count > 0`), call
    `programa review comment add <file> <line> "test comment"`, call
    `programa review comment list` and assert it round-trips, call `programa review send`, then
    assert (via `surface.wait` on a marker echoed by a trivial `cat`/`read` shell loop, exactly per
    the "marker-in-echo" convention noted in memory `tests-v2-authoring-rules`) that the
    serialized comment text actually arrived in the target surface's scrollback.
26. **(1 hr)** A second test asserting binary-file handling: create a repo with a binary file
    (e.g. a small PNG) modified in the worktree, open review, assert that file appears in the
    file list marked not-diffable rather than causing a parse error or being silently dropped.
27. **(1 hr)** A unit-level-in-spirit CLI test for `review.refresh` after a code change: open
    review, make an additional edit, call refresh, assert `diffable_file_count`/file list reflects
    the new change (proves the refresh path actually re-runs git, not just returns cached state).
    Per repo test-quality policy, all of these assert **runtime behavior through the socket/CLI
    surface**, never source text/pbxproj/plist contents.

## 7. Verification steps

1. **Build** (after each phase's pbxproj edits, not just at the end):
   ```
   xcodebuild -project GhosttyTabs.xcodeproj -scheme programa -configuration Debug \
     -destination 'platform=macOS' -derivedDataPath /tmp/programa-review-panel build
   ```
2. **Manual smoke** (after Phase C):
   ```
   ./scripts/reload.sh --tag review-panel-v1 --launch
   ```
   Then: open a terminal surface in a dirty git worktree, run
   `programa review open --socket /tmp/programa-debug-review-panel-v1.sock`, verify the split
   appears with the expected diff, click a line to add a comment, click "Send to agent", verify
   the serialized text lands in the terminal.
3. **Automated** (CI, per repo's "never run tests locally" policy):
   ```
   gh workflow run test-e2e.yml
   ```
   plus whatever workflow runs `tests_v2/` (check `.github/workflows/` for the exact job name
   during implementation — not confirmed in this research pass) to pick up the three new
   `tests_v2/test_review_diff_panel.py` cases from Phase G.
4. **Unit-level parser tests** for `ReviewDiffParser` (Phase A) run via
   `xcodebuild -scheme programa-unit` per the repo's documented exception to "never run tests
   locally" for that one scheme (root `CLAUDE.md` "Testing policy").

## 8. Delegation recommendation

- **Phase A** (data model + parser + prober, no pbxproj panel-type risk) — good `implementer`
  handoff, self-contained, testable in isolation. Two implementers can split step 2 vs step 3.
- **Phase B** (the atomic `PanelType` + 6-switch-site change) — single `implementer`, sequential,
  do not parallelize (§6 note). This is the highest-risk phase (source-breaking + pbxproj editing)
  — consider a dedicated review pass before merging.
- **Phase C** and **Phase D** — parallelizable against each other once Phase B lands (different
  files, only shared dependency is the `ReviewPanel` model). Two `implementer` handoffs in one
  message.
- **Phase E** and **Phase F** — parallelizable against each other once Phase D (E) / Phase C (F)
  land respectively.
- **Phase G** — hand to `tester` once Phases D/E are merged (needs the CLI + socket surface to
  exist). New test files are a MUST-delegate per the repo's agent-routing table.
- Given this touches 6+ files across panel/model/socket/CLI/settings/tests layers, this is a
  `maestro`-shaped feature end-to-end if the user wants full-stack parallel execution rather than
  phase-by-phase sequential delegation.

## 9. Explicit research gaps for the implementer to close before finishing Phase F

- `KeyboardShortcutSettings.swift`'s default-key-equivalent mechanism was not located in this
  research pass (file is large; only the `Action` enum + `label` switch were read). Grep for
  `.openBrowser` across that file's default-binding section before adding `.openReview`'s default.
- Where exactly command-palette *actions* (not just switcher search metadata) are registered as
  invocable commands was not confirmed — `ContentView+CommandPalette.swift` has the search-metadata
  helpers read in this pass, but the actual command list construction (likely a
  `CommandPaletteCommandsContext`-adjacent builder) needs a fuller read before Phase F step 22.
- `CLI/` files' pbxproj group/target membership was not independently verified against
  `Sources/` files' membership — check `CLI+Markdown.swift`'s 4 pbxproj entries specifically
  before assuming `CLI+Review.swift` needs the identical 4-edit shape.
