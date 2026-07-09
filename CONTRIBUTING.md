# Contributing to Programa

## Prerequisites

- macOS 14+
- Xcode 15+
- [Zig](https://ziglang.org/) (install via `brew install zig`)

## Getting Started

1. Clone the repository with submodules:
   ```bash
   git clone --recursive https://github.com/darkroomengineering/programa.git
   cd programa
   ```

2. Run the setup script:
   ```bash
   ./scripts/setup.sh
   ```

   This will:
   - Initialize git submodules (ghostty, homebrew-programa)
   - Build the GhosttyKit.xcframework from source
   - Create the necessary symlinks

3. Build the debug app:
   ```bash
   ./scripts/reload.sh --tag my-feature
   ```
   The script prints the `.app` path. Cmd-click to open, or pass `--launch` to open automatically.

## Development Scripts

| Script | Description |
|--------|-------------|
| `./scripts/setup.sh` | One-time setup (submodules + xcframework) |
| `./scripts/reload.sh` | Build Debug app (pass `--launch` to also open it) |
| `./scripts/reloadp.sh` | Build and launch Release app |
| `./scripts/reload2.sh` | Reload both Debug and Release |

## Rebuilding GhosttyKit

If you make changes to the ghostty submodule, rebuild the xcframework:

```bash
cd ghostty
zig build -Demit-xcframework=true -Doptimize=ReleaseFast
```

## Running Tests

### Basic tests (run on VM)

```bash
ssh programa-vm 'cd /Users/programa/GhosttyTabs && xcodebuild -project GhosttyTabs.xcodeproj -scheme programa -configuration Debug -destination "platform=macOS" build && pkill -x "programa DEV" || true && APP=$(find /Users/programa/Library/Developer/Xcode/DerivedData -path "*/Build/Products/Debug/programa DEV.app" -print -quit) && open "$APP" && for i in {1..20}; do [ -S /tmp/programa.sock ] && break; sleep 0.5; done && python3 tests/test_update_timing.py && python3 tests/test_signals_auto.py && python3 tests/test_ctrl_socket.py && python3 tests/test_notifications.py'
```

### UI tests (run on VM)

```bash
ssh programa-vm 'cd /Users/programa/GhosttyTabs && xcodebuild -project GhosttyTabs.xcodeproj -scheme programa -configuration Debug -destination "platform=macOS" -only-testing:programaUITests test'
```

## Ghostty Submodule

The `ghostty` submodule points to a fork of the upstream Ghostty project maintained by Darkroom Engineering.

### Making changes to ghostty

```bash
cd ghostty
git checkout -b my-feature
# make changes
git add .
git commit -m "Description of changes"
git push darkroom my-feature
```

### Keeping the fork updated

```bash
cd ghostty
git fetch origin
git checkout main
git merge origin/main
git push darkroom main
```

Then update the parent repo:

```bash
cd ..
git add ghostty
git commit -m "Update ghostty submodule"
```

See `docs/ghostty-fork.md` for details on fork changes and conflict notes.

## License

By contributing to this repository, you agree that:

1. Your contributions are licensed under the project's GNU General Public License v3.0 or later (`GPL-3.0-or-later`).
2. You grant Darkroom Engineering a perpetual, worldwide, non-exclusive, royalty-free, irrevocable license to use, reproduce, modify, sublicense, and distribute your contributions under any license, including a commercial license offered to third parties.
