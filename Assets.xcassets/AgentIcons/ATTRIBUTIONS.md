# Agent tab icons

The SVGs in this folder are the agent logos shown on terminal tabs when Programa detects a coding agent in that terminal.

- **Source:** https://github.com/lobehub/lobe-icons, `packages/static-svg/icons/`
- **Pinned commit:** `a94750e3f5f8fc33757b839d85030e742284e43a`
- **License:** MIT, Copyright (c) 2023 LobeHub (text below)

| Asset | Lobe Icons file |
|---|---|
| `AgentIconClaudeCode` | `claudecode-color.svg` |
| `AgentIconCodex` | `codex-color.svg` |
| `AgentIconCopilot` | `githubcopilot.svg` |
| `AgentIconCursor` | `cursor.svg` |
| `AgentIconGeminiCLI` | `geminicli-color.svg` |
| `AgentIconOpenCode` | `opencode.svg` |

Aider has no icon in Lobe Icons, so Aider terminals keep the terminal symbol.

Local changes to each file: the `<title>` element and the inline `style` attribute are removed, and `width`/`height` of `1em` become `24`. The monochrome logos (Copilot, Cursor, OpenCode) replace `fill="currentColor"` with `#000000` for the light appearance and a second file with `#FFFFFF` for the dark appearance. Path data is re-serialized with spaces between values and explicit arc flags, because Xcode's SVG compiler rejects the compact flag form; the geometry is identical.

The logos are trademarks of their respective owners and are used here only to identify the tool running in a tab.

## Lobe Icons license

MIT License

Copyright (c) 2023 LobeHub

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
