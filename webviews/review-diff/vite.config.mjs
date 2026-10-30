// Adapted from cmux (manaflow-ai/cmux), GPL-3.0
import { defineConfig } from "vite";
import { HIGHLIGHTED_GRAMMAR_MODULES } from "./src/languages.ts";

const grammarModulePattern = /\/@shikijs\/langs\/dist\/([^/]+)\.mjs$/;
const shikiThemeModulePattern = /\/@shikijs\/themes\/dist\/[^/]+\.mjs$/;

export default defineConfig({
  define: {
    "process.env.NODE_ENV": JSON.stringify("production"),
  },
  plugins: [
    {
      // `@pierre/diffs` marks the worker entry side-effect free, so without
      // this the self-registering `onmessage` script tree-shakes to nothing.
      name: "programa-diff-worker-side-effects",
      transform(code, id) {
        if (id.endsWith("/@pierre/diffs/dist/worker/worker.js")) {
          return { code, map: null, moduleSideEffects: true };
        }
        return null;
      },
    },
    {
      // shiki's full bundle lists every grammar and theme as a lazy import.
      // Only the grammars in `HIGHLIGHTED_GRAMMAR_MODULES` are shipped; the
      // viewer forces every other file to plain text, so the stubs never load.
      // Pierre renders with its own themes from `@pierre/theme`.
      name: "programa-grammar-allowlist",
      load(id) {
        const grammar = id.match(grammarModulePattern);
        if (grammar && !HIGHLIGHTED_GRAMMAR_MODULES.has(grammar[1])) {
          return "export default [];";
        }
        if (shikiThemeModulePattern.test(id)) {
          return "export default {};";
        }
        return null;
      },
    },
  ],
  build: {
    emptyOutDir: true,
    minify: "esbuild",
    outDir: "../../Resources/review-diff-viewer",
    modulePreload: false,
    reportCompressedSize: false,
    chunkSizeWarningLimit: 1024,
    rollupOptions: {
      input: { main: "src/main.ts", "diff-worker": "src/diff-worker.ts" },
      output: {
        format: "es",
        entryFileNames: (chunk) => (chunk.name === "main" ? "main.mjs" : "chunks/[name].mjs"),
        // Stable names: the bundle is checked in, and content hashes would turn
        // every rebuild into a delete-and-add of every file.
        chunkFileNames: "chunks/[name].mjs",
        assetFileNames: "assets/[name][extname]",
        manualChunks(id) {
          const grammar = id.match(grammarModulePattern);
          if (grammar) {
            return HIGHLIGHTED_GRAMMAR_MODULES.has(grammar[1]) ? `shiki-lang-${grammar[1]}` : "shiki-lang-stub";
          }
          if (shikiThemeModulePattern.test(id)) {
            return "shiki-theme-stub";
          }
          if (id.includes("/shiki/dist/wasm.mjs") || id.includes("/@shikijs/engine-oniguruma/dist/wasm-inlined.mjs")) {
            return "shiki-wasm";
          }
          const pierreTheme = id.match(/\/@pierre\/theme\/dist\/(pierre-[^/]+)\.mjs$/);
          if (pierreTheme) {
            return `pierre-theme-${pierreTheme[1]}`;
          }
          if (id.includes("vite/preload-helper")) {
            return "preload-helper";
          }
          // The worker entry keeps its own chunk so starting a worker does not
          // evaluate the main-thread renderer.
          if (id.endsWith("/@pierre/diffs/dist/worker/worker.js")) {
            return undefined;
          }
          if (!id.includes("node_modules")) {
            return undefined;
          }
          if (
            id.includes("/shiki/") ||
            id.includes("/@shikijs/") ||
            id.includes("/oniguruma-parser/") ||
            id.includes("/oniguruma-to-es/") ||
            id.includes("/node_modules/diff/")
          ) {
            return "shiki-core";
          }
          // Theming is shared by both threads; inside `diff-vendor` it would make
          // every worker evaluate the main-thread renderer.
          if (id.includes("/@pierre/theming/")) {
            return "pierre-theming";
          }
          if (id.includes("/@pierre/")) {
            return "diff-vendor";
          }
          return undefined;
        },
      },
    },
  },
});
