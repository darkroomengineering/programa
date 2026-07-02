# Changelog

All notable changes to Programa are documented here.

Programa is a fork of [cmux](https://github.com/manaflow-ai/cmux); for history prior to the fork, see the upstream changelog.

## [Unreleased]

## [0.2.0] - 2026-07-02

### Changed
- Completed the rename to **Programa** across the whole app and CLI. The command-line tool is now `programa`, and configuration lives in `~/.config/programa/` (`programa.json`, `settings.json`). Existing `~/.config/cmux` files, project-root `cmux.json`, and saved preferences are migrated automatically, so upgrading keeps your setup.

### Added
- New app icon.
- Setting to disable terminal scrollback persistence.
- Cmd+F find support in Markdown panels.
- `browser.proxy` config key for per-WebView proxy settings.

### Fixed
- Split-pane dividers are now visible on dark themes.
- Browser downloads, including those started from iframes/subframes, now save to ~/Downloads.
- VS Code serve-web port and sign-in now persist across restarts.
- VS Code sign-in popup no longer briefly shows about:blank before loading.
- Color-picker hue indicator no longer jumps while adjusting brightness.

## [0.1.0] - 2026-06-25
- First Programa release: forked from cmux and rebranded under Darkroom Engineering.
- Signed and notarized DMG distributed from the Programa repository with its own
  Sparkle auto-update feed.
