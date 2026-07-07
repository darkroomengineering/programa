# Release

Programa ships from a single continuously-updating lane: every commit on `main` that passes the
`CI` GitHub Actions workflow is automatically built, signed, notarized, and published as the
latest release by `.github/workflows/release.yml` (triggered via `workflow_run` on `CI`
completing with `conclusion: success`). There is no nightly/beta channel and no manual publish
step for ordinary changes — merge to `main`, let CI go green, and the release ships itself.

This command is only for **milestone marketing-version bumps** (e.g. `0.15.0` → `0.16.0`), which
are still done manually via a PR + optional `vX.Y.Z` tag marker.

## When to use this

- The user wants to bump the marketing version and record a changelog entry for a milestone.
- Not needed for routine fixes/features — those ship automatically on the next green `main` build.

## Steps

1. **Determine the new version number**
   - Get the current version from `GhosttyTabs.xcodeproj/project.pbxproj` (look for `MARKETING_VERSION`)
   - Bump the minor version unless the user specifies otherwise (e.g., 0.15.0 → 0.16.0)

2. **Create a release branch**
   - Create branch: `git checkout -b release/vX.Y.Z`

3. **Gather changes and contributors since the last release**
   - Find the most recent git tag: `git describe --tags --abbrev=0`
   - Get commits since that tag: `git log --oneline <last-tag>..HEAD --no-merges`
   - **Filter for end-user visible changes only** - ignore developer tooling, CI, docs, tests
   - Categorize changes into: Added, Changed, Fixed, Removed
   - **Collect contributors:** For each PR referenced in the commits, get the author:
     ```bash
     gh pr view <N> --repo darkroomengineering/programa --json author --jq '.author.login'
     ```
   - Also check for linked issue reporters (the person who filed the bug):
     ```bash
     gh issue view <N> --repo darkroomengineering/programa --json author --jq '.author.login'
     ```
   - Build a deduplicated list of all contributor `@handle`s for the release

4. **Update the changelog**
   - Add a new section at the top of `CHANGELOG.md` with the new version and today's date
   - **Only include changes that affect the end-user experience** - things users will see, feel, or interact with
   - Write clear, user-facing descriptions (not raw commit messages)
   - **Credit contributors inline** (see Contributor Credits below)
   - Also update the docs changelog page at `web/app/docs/changelog/page.tsx` with the same content
   - If there are no user-facing changes, ask the user if they still want to bump the version

5. **Bump the version**
   - Run `./scripts/bump-version.sh` (bumps minor by default; accepts `patch`, `major`, or an explicit version)

6. **Commit and push the release branch**
   - Stage: `CHANGELOG.md`, `web/app/docs/changelog/page.tsx`, `GhosttyTabs.xcodeproj/project.pbxproj`
   - Commit message: `Bump version to X.Y.Z`
   - Push: `git push -u origin release/vX.Y.Z`

7. **Create a pull request**
   - Create PR: `gh pr create --title "Bump version to vX.Y.Z" --body "...changelog summary..."`
   - Include the changelog entries in the PR body

8. **Monitor CI**
   - Watch: `gh pr checks --watch`
   - If CI fails, fix the issues and push again
   - Wait for all checks to pass before proceeding

9. **Merge the PR**
   - Merge: `gh pr merge --squash --delete-branch`
   - Switch back to main: `git checkout main && git pull`
   - Once `CI` goes green on this merge commit, `release.yml` auto-ships it as the new latest
     release — no further action is required.

10. **(Optional) Tag the milestone**
    - If you want a durable `vX.Y.Z` marker in the release history (in addition to the
      auto-shipped release), tag it:
      ```bash
      git tag vX.Y.Z
      git push origin vX.Y.Z
      ```
    - This also triggers `release.yml` via its `push: tags: v*` trigger, publishing under that
      exact tag.

11. **Monitor the release workflow**
    - Watch: `gh run watch --repo darkroomengineering/programa`
    - Verify the release appears at: https://github.com/darkroomengineering/programa/releases
    - Check that `programa-macos.dmg` is attached to the release

12. **Notify**
    - On success: `say "programa release complete"`
    - On failure: `say "programa release failed"`

## Changelog Guidelines

**Include only end-user visible changes:**
- New features users can see or interact with
- Bug fixes users would notice (crashes, UI glitches, incorrect behavior)
- Performance improvements users would feel
- UI/UX changes
- Breaking changes or removed features

**Exclude internal/developer changes:**
- Setup scripts, build scripts, reload scripts
- CI/workflow changes
- Documentation updates (README, CONTRIBUTING, CLAUDE.md)
- Test additions or fixes
- Internal refactoring with no user-visible effect
- Dependency updates (unless they fix a user-facing bug)

**Writing style:**
- Use present tense ("Add feature" not "Added feature")
- Group by category: Added, Changed, Fixed, Removed
- Be concise but descriptive
- Focus on what the user experiences, not how it was implemented
- Link to issues/PRs if relevant

## Contributor Credits

Credit the people who made each release happen. This builds community and encourages contributions.

**Per-entry attribution** — append contributor credit after each changelog bullet:
- For code contributions (PR author): `— thanks @user!`
- For bug reports (issue reporter, if different from PR author): `— thanks @reporter for the report!`

**Summary section** — add a "Thanks to N contributors!" section at the bottom of each release:
```markdown
### Thanks to N contributors!

- [@user1](https://github.com/user1)
- [@user2](https://github.com/user2)
```
- List all contributors alphabetically by GitHub handle
- Link each handle to their GitHub profile
- Include everyone: PR authors, issue reporters, anyone whose work is in the release

**GitHub Release body** — when the release is published, the GitHub Release should also include the "Thanks to N contributors!" section with linked handles.

## Example Changelog Entry

```markdown
## [0.16.0] - 2026-07-07

### Added
- New keyboard shortcut for quick tab switching ([#42](https://github.com/darkroomengineering/programa/pull/42)) — thanks @contributor!

### Fixed
- Memory leak when closing split panes ([#38](https://github.com/darkroomengineering/programa/pull/38)) — thanks @fixer!
- Notification badges not clearing properly ([#35](https://github.com/darkroomengineering/programa/pull/35)) — thanks @reporter for the report!

### Changed
- Improved terminal rendering performance ([#40](https://github.com/darkroomengineering/programa/pull/40))

### Thanks to 3 contributors!

- [@contributor](https://github.com/contributor)
- [@fixer](https://github.com/fixer)
- [@reporter](https://github.com/reporter)
```
