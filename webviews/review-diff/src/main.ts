// Adapted from cmux (manaflow-ai/cmux), GPL-3.0
import {
  CodeView,
  getFiletypeFromFileName,
  parsePatchFiles,
  type CodeViewDiffItem,
  type CodeViewItem,
  type CodeViewOptions,
  type SelectedLineRange,
} from "@pierre/diffs";
import { getOrCreateWorkerPoolSingleton } from "@pierre/diffs/worker";
import { HIGHLIGHTED_LANGUAGE_IDS } from "./languages.ts";

type DiffStyle = "split" | "unified";
type Options = CodeViewOptions<undefined, undefined>;

interface NativeBridge {
  postMessage(message: unknown): void;
}

declare global {
  interface Window {
    webkit?: { messageHandlers?: { programaReview?: NativeBridge } };
    programaReview: { reload(): Promise<void>; setDiffStyle(style: DiffStyle): void };
  }
}

function postToNative(message: Record<string, unknown>): void {
  window.webkit?.messageHandlers?.programaReview?.postMessage(message);
}

const root = document.getElementById("root");
if (!root) throw new Error("Missing #root");

const initialStyle: DiffStyle =
  new URLSearchParams(location.search).get("style") === "unified" ? "unified" : "split";

const workerPool = getOrCreateWorkerPoolSingleton({
  poolOptions: {
    // SHORTCUT: fixed two-worker pool. ceiling: highlighting of very large diffs
    // queues behind two workers. upgrade: size by file count once memory numbers allow.
    poolSize: 2,
    workerFactory: () =>
      new Worker(new URL("/chunks/diff-worker.mjs", location.href), { type: "module" }),
  },
  highlighterOptions: {
    langs: ["text"],
    preferredHighlighter: "shiki-wasm",
    lineDiffType: "word",
    maxLineDiffLength: 1000,
    tokenizeMaxLineLength: 1000,
    useTokenTransformer: false,
  },
});

// Only new-side (additions) lines can carry a review comment: the native
// comment model addresses new-file line numbers.
function handleGutterUtilityClick(range: SelectedLineRange, context: { item: CodeViewItem<undefined> }): void {
  if (context.item.type !== "diff") return;
  const startSide = range.side ?? "additions";
  const endSide = range.endSide ?? startSide;
  if (startSide !== "additions" || endSide !== "additions") return;
  postToNative({
    type: "selectLines",
    filePath: context.item.fileDiff.name,
    side: "additions",
    startLine: Math.min(range.start, range.end),
    endLine: Math.max(range.start, range.end),
  });
}

function viewOptions(diffStyle: DiffStyle): Options {
  return {
    theme: { dark: "pierre-dark", light: "pierre-light" },
    themeType: "system",
    diffStyle,
    diffIndicators: "bars",
    overflow: "scroll",
    lineDiffType: "word",
    maxLineDiffLength: 1000,
    tokenizeMaxLineLength: 1000,
    lineHoverHighlight: "number",
    enableLineSelection: true,
    enableGutterUtility: true,
    stickyHeaders: true,
    layout: { paddingTop: 0, gap: 1, paddingBottom: 16 },
    unsafeCSS: UNSAFE_CSS,
    onGutterUtilityClick: handleGutterUtilityClick as Options["onGutterUtilityClick"],
  };
}

const UNSAFE_CSS = `
  :host {
    --diffs-light-bg: transparent;
    --diffs-dark-bg: transparent;
    --diffs-bg-context-override: transparent;
    --diffs-bg-context-gutter-override: transparent;
    --diffs-bg-separator-override: transparent;
    --diffs-font-family: ui-monospace, "SF Mono", Menlo, monospace;
    --diffs-font-size: 12px;
  }
  :host, pre, code { background-color: transparent; }
  [data-diffs-header] {
    background-color: color-mix(in srgb, Canvas 70%, transparent) !important;
    -webkit-backdrop-filter: blur(8px);
    backdrop-filter: blur(8px);
  }
`;

let diffStyle = initialStyle;
const view = new CodeView<undefined, undefined>(viewOptions(diffStyle), workerPool);
view.setup(root);

let generation = 0;

function itemsFromPatch(patchText: string, cacheKey: string): CodeViewDiffItem[] {
  const items: CodeViewDiffItem[] = [];
  const seenIds = new Map<string, number>();
  for (const patch of parsePatchFiles(patchText, cacheKey)) {
    for (const fileDiff of patch.files) {
      const filetype = getFiletypeFromFileName(fileDiff.name);
      if (!HIGHLIGHTED_LANGUAGE_IDS.has(filetype)) {
        fileDiff.lang = "text";
      }
      const occurrence = seenIds.get(fileDiff.name) ?? 0;
      seenIds.set(fileDiff.name, occurrence + 1);
      items.push({
        id: occurrence === 0 ? fileDiff.name : `${fileDiff.name}#${occurrence}`,
        type: "diff",
        fileDiff,
        version: generation,
      });
    }
  }
  return items;
}

async function reload(): Promise<void> {
  const current = ++generation;
  try {
    const response = await fetch("/patch", { cache: "no-store" });
    if (!response.ok) throw new Error(`patch request failed: ${response.status}`);
    const patchText = await response.text();
    if (current !== generation) return;
    view.setItems(itemsFromPatch(patchText, `review-${current}`));
    view.render();
  } catch (error) {
    postToNative({ type: "error", message: String((error as Error)?.stack ?? error) });
  }
}

window.programaReview = {
  reload,
  setDiffStyle(style) {
    if (style === diffStyle) return;
    diffStyle = style;
    view.setOptions(viewOptions(diffStyle));
    view.render();
  },
};

window.addEventListener("error", (event) => postToNative({ type: "error", message: String(event.message) }));
void reload();
