// Grammar modules (file names under @shikijs/langs/dist) shipped with the
// viewer. cpp pulls in cpp-macro, regexp and glsl; html pulls in javascript
// and css.
export const HIGHLIGHTED_GRAMMAR_MODULES: ReadonlySet<string> = new Set([
  "c",
  "cpp",
  "cpp-macro",
  "css",
  "glsl",
  "go",
  "html",
  "javascript",
  "json",
  "jsonc",
  "jsx",
  "markdown",
  "python",
  "regexp",
  "rust",
  "shellscript",
  "swift",
  "toml",
  "tsx",
  "typescript",
  "yaml",
  "zig",
]);

// Language ids `getFiletypeFromFileName` returns that resolve to a shipped
// grammar (shiki aliases included). Anything else renders as plain text.
export const HIGHLIGHTED_LANGUAGE_IDS: ReadonlySet<string> = new Set([
  ...HIGHLIGHTED_GRAMMAR_MODULES,
  "bash",
  "sh",
  "shell",
  "yml",
  "zsh",
]);
