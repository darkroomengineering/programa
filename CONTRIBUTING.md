# Contributing to Programa

## Prerequisites

- macOS 14+
- Xcode 26+ (Swift 6 and the macOS 26 SDK)
- [Zig](https://ziglang.org/), the exact version printed by `scripts/required-zig-version.sh` (currently 0.16.0). `brew install zig` may install a different version, which fails the GhosttyKit build
- [Rust](https://rustup.rs/) with Cargo, only when working on the Windows app or the
  `core/` crates. The macOS app does not build or link the Rust core.

For the native WinUI frontend, use Windows with the .NET SDK and Rust MSVC
toolchain described in [windows/README.md](windows/README.md). Its build script
produces the rolling `.exe` artifact. Windows interaction validation is covered
in [docs/windows-testing.md](docs/windows-testing.md).

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
   - Initialize git submodules (ghostty)
   - Build the GhosttyKit.xcframework from source
   - Create the necessary symlinks

3. Build the debug app:
   ```bash
   ./scripts/reload.sh --tag my-feature
   ```
   The script prints the `.app` path. Cmd-click to open, or pass `--launch` to open automatically.

   If your local Zig doesn't match the version the ghostty submodule needs
   (`scripts/required-zig-version.sh`), skip the Zig steps and build against the
   existing GhosttyKit.xcframework:
   ```bash
   PROGRAMA_SKIP_ZIG_BUILD=1 ./scripts/reload.sh --tag my-feature
   ```
   If the xcframework is missing, `./scripts/download-prebuilt-ghosttykit.sh`
   fetches a prebuilt copy.

## Development Scripts

| Script | Description |
|--------|-------------|
| `./scripts/setup.sh` | One-time setup (submodules + xcframework) |
| `./scripts/reload.sh --tag my-feature` | Build Debug app (pass `--launch` to also open it) |
| `./scripts/reloadp.sh` | Build and launch Release app |
| `./scripts/reload2.sh --tag my-feature` | Reload both Debug and Release |

## Rebuilding GhosttyKit

If you make changes to the ghostty submodule, rebuild the xcframework:

```bash
cd ghostty
zig build -Demit-xcframework=true -Doptimize=ReleaseFast
```

## Running Tests

Run tests through GitHub Actions or the designated VM. See [the testing layout](docs/testing-layout.md) for the four harnesses and their scope. Do not point socket tests at your everyday Programa instance.

Run the CI suite on your pushed branch:

```bash
gh workflow run ci.yml --ref my-feature
```

Run the focused notification UI regression on the macOS 26 lane:

```bash
gh workflow run ci.yml --ref my-feature -f notification_ui=true
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
git push origin my-feature
```

### Keeping the fork updated

```bash
cd ghostty
git fetch origin
git checkout main
git merge origin/main
git push origin main
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
