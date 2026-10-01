# Sync Branch

Get the current branch ready: update main, rebase onto it, and check out the submodule commits main pins.

**Important: Never push automatically. Always ask the user before any push.**

## Steps

1. **Update main**
   - `git checkout main && git pull origin main`

2. **Rebase current branch on main**
   - `git checkout <original-branch>`
   - `git rebase main`
   - If conflicts, resolve them and continue
   - **Do not push.** Ask the user if they want to force-push the rebased branch.

3. **Check out pinned submodules**
   - `git submodule update --init --recursive`
   - This checks out the exact `ghostty` commit the branch pins. Never merge the fork's `main`
     into `ghostty/` to "update" it: the fork's `main` is far ahead of the pin, and moving the
     pin pulls in unrelated upstream changes. Ghostty changes follow `docs/ghostty-fork.md`.

4. **Report status**
   - Show whether the `ghostty` pin differs from main
   - Show if rebase was clean or had conflicts
   - Show current branch and commit

## Notes

- Never commit a submodule pointer in the parent repo unless the submodule commit is pushed to the fork (per CLAUDE.md pitfall about orphaned commits)
- If main has no new commits, just say "Already up to date"
- If on main already, skip step 2
