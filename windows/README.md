# Programa for Windows

Programa's Windows frontend uses C# on .NET 10 and native WinUI 3 controls. The portable Rust core owns workspace, pane, surface, selection, split, and tab-order behavior. `programa_terminal.dll` owns each ConPTY session and terminal model; the WinUI shell keeps one `TerminalView` alive per core surface ID so selecting, splitting, and reordering controls never restarts a shell.

## Build on Windows

Install the .NET 10 SDK, stable Rust MSVC toolchain, Visual Studio Build Tools with the Desktop development with C++ workload, and a current Windows SDK. Then run from PowerShell at the repository root:

```powershell
rustup default stable-msvc
rustup target add x86_64-pc-windows-msvc
./scripts/build-windows.ps1 -Version 0.4.123 -Build 123 -Commit 0123456789abcdef0123456789abcdef01234567 -OutputDirectory ./artifacts/windows
```

The output directory must be new or empty. The script formats and tests both Rust libraries, runs the managed projection tests, publishes the unpackaged self-contained WinUI application, validates its x64 PE header and exact `--version` output, and emits only these byte-identical files:

- `programa-windows.exe`
- `programa-windows-<build>.exe`

Windows App SDK single-file publishing extracts its bundled managed, WinUI, `programa_core.dll`, and `programa_terminal.dll` dependencies into the .NET single-file extraction area on first launch. It does not download code or require a separately installed Windows App SDK runtime.

Release builds are signed via Azure Trusted Signing once the account is configured (see `docs/windows-signing.md`). Until then, `programa-windows.exe` ships unsigned and SmartScreen shows "Run anyway" the first time someone launches it.

For an ordinary development build after the native DLLs exist:

```powershell
dotnet build windows/Programa/Programa.csproj -p:ProgramaNativeDirectory=C:\path\to\native-dlls
```

## Windows behavior

The app uses WinUI `TabView` document tabs with within-pane reordering and cross-pane moves inside the current workspace. Cross-workspace moves and tear-out are disabled. Each pane has its own tab strip, and recursive WinUI `Grid` layouts provide draggable native split dividers. Closing a pane's final tab collapses that pane; closing the final workspace tab closes the window. The toolbar exposes new tab, both split directions, and Settings. WinUI supplies keyboard focus, system theme and high-contrast behavior, accessibility peers, DPI scaling, and native dialogs.

Default shortcuts avoid terminal control sequences:

| Action | Default |
|---|---|
| New tab | `Ctrl+Shift+T` |
| Close tab | `Ctrl+Shift+W` |
| Split vertically | `Ctrl+Shift+D` |
| Split horizontally | `Ctrl+Shift+E` |
| Select tab 1–9 | `Alt+1` through `Alt+9` |
| Copy | `Ctrl+Shift+C` |
| Paste | `Ctrl+Shift+V` or `Shift+Insert` |
| Open Settings | `Ctrl+,` |

Every Programa-owned shortcut is editable in Settings and stored under `windows.shortcuts` in `%USERPROFILE%\.config\programa\settings.json`. Saving preserves unknown JSON fields, rejects duplicate or malformed shortcuts, and reserves raw `Ctrl+C`, `Ctrl+D`, and `Ctrl+W` for the terminal. English and Japanese UI resources ship with the executable.

## Validation

The Windows CI job is the reproducible compiler and test environment. Interactive validation must use Windows 11 and cover real shell startup, input, IME composition, copy and paste, tab drag in both directions, nested splits and divider resizing, 100/150/200% scaling, light/dark/high-contrast themes, keyboard-only navigation, and Narrator. macOS cannot validate WinUI XAML compilation, ConPTY, native UI Automation peers, or single-file extraction.
