# Terminal themes and appearance

Programa reads the themes installed with its embedded Ghostty, Ghostty's standard user theme directories, and any directories configured through `GHOSTTY_RESOURCES_DIR` or `XDG_DATA_DIRS`. Two Programa-specific themes, **Min Light** and **Min Dark**, ship alongside Ghostty's bundled catalog — minimal, low-saturation palettes in the style of the [Min Theme](https://marketplace.visualstudio.com/items?itemName=miguelsolorio.min-theme) VS Code extension.

Choose separate light and dark themes and a terminal font in **Settings → Appearance → Terminal**. Background opacity and blur are set with `programa themes set` or in your Ghostty config. Changes apply to every open terminal without relaunching Programa. Choosing **Use Ghostty Configuration** for a theme removes Programa's managed override for that field and returns it to your Ghostty config.

The same settings are available from the CLI:

```bash
programa themes list
programa themes set --light "Catppuccin Latte" --dark "Catppuccin Mocha"
programa themes set --opacity 0.85 --blur --font "JetBrains Mono" --font-size 13
programa themes clear
```

All surfaces write the same managed block in `~/Library/Application Support/com.darkroom.programa/config.ghostty`, preserving unrelated directives in that file. Setting one field (e.g. opacity) never disturbs another field Programa already manages there (e.g. theme or font) — but it also never captures a field it doesn't yet manage, even if that field currently resolves to a value from your own raw Ghostty config. Programa only ever writes the specific field you changed.

## settings.json

Two independent `app.*` keys manage these settings as configuration in `~/.config/programa/settings.json`:

```jsonc
{
  "app": {
    "terminalTheme": {
      "light": "Catppuccin Latte",
      "dark": "Catppuccin Mocha"
    },
    "terminalFont": {
      "family": "JetBrains Mono",
      "size": 13
    }
  }
}
```

Each key is managed independently — pin `terminalFont` while leaving `terminalTheme` editable in Settings, or the reverse. While a key is present, its corresponding Settings row (or pair of rows, for theme) is read-only. Removing a key restores the value that was active before `settings.json` took ownership of it. Set `terminalTheme` or `terminalFont` to `null` to explicitly inherit your Ghostty configuration for that field while keeping it file-managed.
