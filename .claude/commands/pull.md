# Pull

Pull latest main and check out the submodule commits main pins. No commits, no pushes.

## Steps

1. `git pull origin main`
2. `git submodule update --init --recursive`
   - This checks out the exact `ghostty` commit the parent repo pins. Never merge the fork's
     `main` into `ghostty/`: it is far ahead of the pin, and moving the pin pulls in unrelated
     upstream changes (see `docs/ghostty-fork.md`).
3. Report: current commit, and whether the `ghostty` pin changed (`git diff HEAD@{1} --stat -- ghostty`)
