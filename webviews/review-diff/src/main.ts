// Adapted from cmux (manaflow-ai/cmux), GPL-3.0
import {
  CodeView,
  getFiletypeFromFileName,
  processFile,
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
    renderHeaderMetadata: renderNotice as Options["renderHeaderMetadata"],
  };
}

// Item id -> label for files the native side reduced to a bare header (too
// large, binary, untracked). The text comes localized from Swift.
let notices = new Map<string, string>();

function renderNotice(_fileDiff: unknown, context: { item: CodeViewItem<undefined> }): Element | undefined {
  const label = notices.get(context.item.id);
  if (label == null) return undefined;
  // Header slots sit in the light DOM, out of reach of `unsafeCSS`, so style inline.
  const element = document.createElement("span");
  element.style.opacity = "0.6";
  element.style.fontStyle = "italic";
  element.textContent = label;
  return element;
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
  :host, pre, code { background-color: transparent; }  [data-diffs-header] {
    background-color: color-mix(in srgb, Canvas 70%, transparent) !important;
    -webkit-backdrop-filter: blur(8px);
    backdrop-filter: blur(8px);
  }
`;

let diffStyle = initialStyle;
const view = new CodeView<undefined, undefined>(viewOptions(diffStyle), workerPool);
view.setup(root);

let generation = 0;

// The native side writes one `diff --git` entry per file and keys its notices
// by entry index, so entries are split and parsed one by one: an entry Pierre
// cannot parse must not shift the index of the ones after it.
function splitEntries(patchText: string): string[] {
  const starts: number[] = patchText.startsWith("diff --git ") ? [0] : [];
  for (let at = patchText.indexOf("\ndiff --git "); at !== -1; at = patchText.indexOf("\ndiff --git ", at + 1)) {
    starts.push(at + 1);
  }
  return starts.map((start, n) => patchText.slice(start, starts[n + 1] ?? patchText.length));
}

function itemsFromPatch(
  patchText: string,
  entryNotices: Record<string, string>,
  cacheKey: string,
): { items: CodeViewDiffItem[]; notices: Map<string, string> } {
  const items: CodeViewDiffItem[] = [];
  const itemNotices = new Map<string, string>();
  const seenIds = new Map<string, number>();
  splitEntries(patchText).forEach((entry, index) => {
    const fileDiff = processFile(entry, { cacheKey: `${cacheKey}-${index}`, isGitDiff: true });
    if (fileDiff == null) return;
    const filetype = getFiletypeFromFileName(fileDiff.name);
    if (!HIGHLIGHTED_LANGUAGE_IDS.has(filetype)) {
      fileDiff.lang = "text";
    }
    const occurrence = seenIds.get(fileDiff.name) ?? 0;
    seenIds.set(fileDiff.name, occurrence + 1);
    const id = occurrence === 0 ? fileDiff.name : `${fileDiff.name}#${occurrence}`;
    const notice = entryNotices[String(index)];
    if (typeof notice === "string") itemNotices.set(id, notice);
    items.push({ id, type: "diff", fileDiff, version: generation });
  });
  return { items, notices: itemNotices };
}

async function fetchNotices(): Promise<Record<string, string>> {
  const response = await fetch("/notices", { cache: "no-store" });
  if (!response.ok) throw new Error(`notices request failed: ${response.status}`);
  const body: unknown = await response.json();
  if (body == null || typeof body !== "object" || Array.isArray(body)) return {};
  return body as Record<string, string>;
}

async function reload(): Promise<void> {
  const current = ++generation;
  try {
    const [response, entryNotices] = await Promise.all([fetch("/patch", { cache: "no-store" }), fetchNotices()]);
    if (!response.ok) throw new Error(`patch request failed: ${response.status}`);
    const patchText = await response.text();
    if (current !== generation) return;
    const parsed = itemsFromPatch(patchText, entryNotices, `review-${current}`);
    notices = parsed.notices;
    view.setItems(parsed.items);
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
