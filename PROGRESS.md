# Programa fork — execution ledger

Source of truth: `/Users/frz/Developer/@darkroom/programa/PLAN.md` (validated 2026-06-23).
Legend: ✅ done · ⏳ in progress · 🔒 human-gated · 🛠️ needs-build (ghostty pipeline).

## Done (pre-loop)
- ✅ Phase 1 — ghostty fork + submodule repoint (`238bb892`), snapshot tag `upstream-snapshot-7e070da4`
- ✅ Phase 2 — rebrand cmux→Programa (`da1e4571`)
- ✅ node_modules untracked (`b312974e`)

## Phase 3 — CI
- [x] 3.1 Runners → GitHub-hosted (macos-15; macos-26 on the skip_zig compat leg) — ✅ `6a75b07f`
- [x] 3.2 Repoint `manaflow-ai/*` cross-repo refs → `darkroomengineering/*` — ✅ `6a75b07f`
- [x] 3.3 Delete R2 upload steps + `CF_R2_*`; appcast = GitHub Releases only — ✅ `6a75b07f`
- [x] 3.4 Guard test asserts GitHub-hosted runners — ✅ `6a75b07f`
- [x] 3.5 Repoint Sparkle monotonic fetch URLs — ✅ `6a75b07f`
- [ ] 3.6 🛠️ GhosttyKit build-from-source in CI + Zig 0.15.2 setup (trickiest; needs CI iteration)
- [ ] 3.7 🔒 Add CI secrets in repo settings; drop `CF_R2_*`; no `APPLE_RELEASE_PROVISIONING_PROFILE_BASE64`

## Phase 4 — Feed / distribution
- [ ] 4.1 Confirm `SUFeedURL` = darkroomengineering/cmux releases everywhere (app side done in da1e4571; verify CI after Phase 3)
- [ ] 4.2 (deferred) Internal Homebrew tap
- [ ] 4.3 follow-up: README*.md + Swift test fixtures still contain `manaflow-ai` appcast/download URLs (flagged by 3.x; non-blocking)

## Loop log
- Cycle 1 (`6a75b07f`, `44a6d54c`): Phase 3 CI rebrand (3.1–3.5). Also fixed: `Sources/SurfacePool.swift` was untracked and missing from da1e4571 (build-blocker) → committed.

## Phase 5 — Triaged fixes (see PLAN.md Phase 5 table)
- [ ] 5.1 #4948 IPv6 `cmux ssh` — cmux-only (CLI/cmux.swift:4270-4298 + TerminalController.swift:3886)
- [ ] 5.2 🛠️ #4156 minimum-contrast — ghostty engine
- [ ] 5.3 🛠️ #1400 split-divider-color — ghostty engine
- [ ] 5.4 🛠️ #5361 option-as-alt + #1153 alt+backspace — ghostty engine
- [ ] 5.5 🛠️ #4177 right-click-action — ghostty + cmux
- [ ] 5.6 🛠️ #4890 SSH SGR leak — ghostty (needs repro)
- [ ] 5.7 🛠️ #2819 vi-mode selection — ghostty (needs repro)

## Human gates (🔒)
- Apple `.p12` export (Developer ID present; Team ID ZNHHMX2RP6) + add GitHub repo secrets
- `git push` (all commits local) + create `nightly` pre-release tag
- CI run → notarized DMG verification
- ghostty build pipeline (GhosttyKit rebuild + submodule-pin bump) for 🛠️ items
