// Adapted from cmux (manaflow-ai/cmux), GPL-3.0
import {
  CodeView,
  getFiletypeFromFileName,
  parseDiffFromFile,
  processFile,
  type CodeViewDiffItem,
  type CodeViewItem,
  type CodeViewOptions,
  type FileContents,
  type SelectedLineRange,
} from "@pierre/diffs";
import { Editor } from "@pierre/diffs/edit";
import { getOrCreateWorkerPoolSingleton } from "@pierre/diffs/worker";
import { HIGHLIGHTED_LANGUAGE_IDS } from "./languages.ts";

type DiffStyle = "split" | "unified";
type Options = CodeViewOptions<undefined, undefined>;

interface NativeBridge {
  // Resolves with the native reply (`WKScriptMessageHandlerWithReply`).
  postMessage(message: unknown): Promise<unknown>;
}

declare global {
  interface Window {
    webkit?: { messageHandlers?: { programaReview?: NativeBridge } };
    programaReview: { reload(): Promise<void>; setDiffStyle(style: DiffStyle): void };
  }
}

function postToNative(message: Record<string, unknown>): void {
  window.webkit?.messageHandlers?.programaReview?.postMessage(message).catch(() => undefined);
}

async function requestNative(message: Record<string, unknown>): Promise<unknown> {
  const bridge = window.webkit?.messageHandlers?.programaReview;
  if (bridge == null) throw new Error("native bridge unavailable");
  return bridge.postMessage(message);
}

const root = document.getElementById("root");
if (!root) throw new Error("Missing #root");

const query = new URLSearchParams(location.search);
const initialStyle: DiffStyle = query.get("style") === "unified" ? "unified" : "split";
// Localized by the native side; the page has no strings of its own.
const labels = {
  edit: query.get("editLabel") ?? "Edit",
  editHelp: query.get("editHelp") ?? "Edit",
  save: query.get("saveLabel") ?? "Save",
  saveHelp: query.get("saveHelp") ?? "Save",
  cancel: query.get("cancelLabel") ?? "Cancel",
  cancelHelp: query.get("cancelHelp") ?? "Cancel",
  editFailed: query.get("editFailed") ?? "Could not edit this file.",
};

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
    renderHeaderMetadata: renderHeaderMetadata as Options["renderHeaderMetadata"],
    createEditor: (editorType, options, editStateKey) => new Editor(editorType, options, editStateKey),
    onItemEditChange: handleItemEditChange,
    onItemEditComplete: handleItemEditComplete as Options["onItemEditComplete"],
  };
}

// Item id -> label for files the native side reduced to a bare header (too
// large, binary, untracked). The text comes localized from Swift.
let notices = new Map<string, string>();
// Item id -> repo-relative path, for the files native lets the user edit here.
let editablePaths = new Map<string, string>();

// SHORTCUT: one file in edit mode at a time. ceiling: editing a second file means saving or
// cancelling the first. upgrade: key the session by item id once users ask for parallel edits.
type EditSession =
  | { kind: "idle" }
  | { kind: "loading"; itemId: string }
  | { kind: "editing"; itemId: string; path: string; token: string; original: CodeViewDiffItem; dirty: boolean }
  | { kind: "saving"; itemId: string; path: string; token: string; original: CodeViewDiffItem };

let session: EditSession = { kind: "idle" };
// Shown in the header of the file it belongs to until the next edit action.
let headerError: { itemId: string; message: string } | null = null;
// Read by `onItemEditComplete`, which CodeView calls when an item leaves edit mode. Anything
// that ends a session without an entry here (a removed item) is rejected.
const closingDecisions = new Map<string, "accept" | "reject">();
// A refresh replaces every item, which would end the edit session and drop the draft, so
// reloads wait until the session ends.
let reloadPending = false;

// CodeView keeps an item's record when an incoming version equals the current one, so every
// version comes from this one counter.
let itemVersion = 0;
function nextVersion(): number {
  itemVersion += 1;
  return itemVersion;
}

function handleItemEditChange(_event: unknown, item: CodeViewItem<undefined>): void {
  if (session.kind !== "editing" || session.itemId !== item.id || session.dirty) return;
  session = { ...session, dirty: true };
}

function handleItemEditComplete(
  _event: unknown,
  item: CodeViewItem<undefined>,
  nextItem: CodeViewItem<undefined>,
): "accept" | "reject" {
  const decision = closingDecisions.get(item.id) ?? "reject";
  closingDecisions.delete(item.id);
  if (decision === "accept") itemVersion = Math.max(itemVersion, nextItem.version ?? 0);
  return decision;
}

// Header slots sit in the light DOM, out of reach of `unsafeCSS`, so style inline. Pierre only
// calls this when it renders the header, so each item keeps one element that edit-state
// changes rebuild in place.
const headerElements = new Map<string, HTMLSpanElement>();

function renderHeaderMetadata(_file: unknown, context: { item: CodeViewItem<undefined> }): Element | undefined {
  const { id } = context.item;
  if (!notices.has(id) && !editablePaths.has(id)) return undefined;
  let container = headerElements.get(id);
  if (container == null) {
    container = document.createElement("span");
    container.style.display = "inline-flex";
    container.style.alignItems = "center";
    container.style.gap = "8px";
    headerElements.set(id, container);
  }
  fillHeader(container, id);
  return container;
}

// Every header reflects the session (other files' Edit buttons disable while one is edited).
function refreshHeaders(): void {
  for (const [id, element] of headerElements) fillHeader(element, id);
}

function fillHeader(container: HTMLSpanElement, itemId: string): void {
  const children: HTMLElement[] = [];
  const label = notices.get(itemId);
  if (label != null) {
    const notice = document.createElement("span");
    notice.style.opacity = "0.6";
    notice.style.fontStyle = "italic";
    notice.textContent = label;
    children.push(notice);
  }
  if (headerError?.itemId === itemId) {
    const error = document.createElement("span");
    error.setAttribute("role", "alert");
    error.style.color = "color-mix(in srgb, #e5484d 80%, currentColor)";
    error.textContent = headerError.message;
    children.push(error);
  }
  const path = editablePaths.get(itemId);
  if (path != null) {
    if ((session.kind === "editing" || session.kind === "saving") && session.itemId === itemId) {
      const busy = session.kind === "saving";
      children.push(
        headerButton(labels.save, labels.saveHelp, busy, () => void saveEdit()),
        headerButton(labels.cancel, labels.cancelHelp, busy, cancelEdit),
      );
    } else {
      children.push(headerButton(labels.edit, labels.editHelp, session.kind !== "idle", () => void beginEdit(itemId, path)));
    }
  }
  container.replaceChildren(...children);
}

function headerButton(text: string, help: string, disabled: boolean, action: () => void): HTMLButtonElement {
  const button = document.createElement("button");
  button.type = "button";
  button.textContent = text;
  button.title = help;
  button.disabled = disabled;
  button.style.font = "inherit";
  button.style.fontSize = "11px";
  button.style.color = "inherit";
  button.style.background = "transparent";
  button.style.border = "1px solid color-mix(in srgb, currentColor 30%, transparent)";
  button.style.borderRadius = "4px";
  button.style.padding = "1px 8px";
  button.style.cursor = disabled ? "default" : "pointer";
  button.style.opacity = disabled ? "0.5" : "1";
  button.addEventListener("click", (event) => {
    event.preventDefault();
    event.stopPropagation();
    if (!button.disabled) action();
  });
  return button;
}

function setHeaderError(itemId: string, message: string): void {
  headerError = { itemId, message };
  refreshHeaders();
}

function clearHeaderError(): void {
  headerError = null;
  refreshHeaders();
}

type LoadReply =
  | { ok: true; oldContents: string | null; newContents: string; token: string }
  | { ok: false; message: string };
type SaveReply = { ok: true } | { ok: false; message: string };

function isRecord(value: unknown): value is Record<string, unknown> {
  return value != null && typeof value === "object" && !Array.isArray(value);
}

// WebKit may hand a native boolean over as a number.
function isOk(value: Record<string, unknown>): boolean {
  return value.ok === true || value.ok === 1;
}

function failureReply(value: unknown): { ok: false; message: string } {
  const message = isRecord(value) && typeof value.message === "string" ? value.message : labels.editFailed;
  return { ok: false, message };
}

function parseLoadReply(value: unknown): LoadReply {
  if (
    isRecord(value) &&
    isOk(value) &&
    typeof value.newContents === "string" &&
    typeof value.token === "string" &&
    (value.oldContents === null || typeof value.oldContents === "string")
  ) {
    return { ok: true, oldContents: value.oldContents, newContents: value.newContents, token: value.token };
  }
  return failureReply(value);
}

function parseSaveReply(value: unknown): SaveReply {
  return isRecord(value) && isOk(value) ? { ok: true } : failureReply(value);
}

// The patch-parsed diff only holds its hunks; the editor needs both whole files, and Pierre
// cannot hydrate an added file from a patch, so the item gets a diff built from the contents.
async function beginEdit(itemId: string, path: string): Promise<void> {
  const item = view.getItem(itemId);
  if (session.kind !== "idle" || item?.type !== "diff") return;
  session = { kind: "loading", itemId };
  clearHeaderError();
  let reply: LoadReply;
  try {
    reply = parseLoadReply(await requestNative({ type: "loadFile", filePath: path }));
  } catch {
    reply = failureReply(undefined);
  }
  if (session.kind !== "loading" || session.itemId !== itemId) return;
  const current = view.getItem(itemId);
  if (!reply.ok || current?.type !== "diff") {
    endSession();
    setHeaderError(itemId, reply.ok ? labels.editFailed : reply.message);
    return;
  }
  const { fileDiff } = current;
  const lang = fileDiff.lang;
  const oldFile: FileContents | null =
    reply.oldContents == null ? null : { name: fileDiff.prevName ?? fileDiff.name, contents: reply.oldContents, lang };
  const newFile: FileContents = { name: fileDiff.name, contents: reply.newContents, lang };
  try {
    const fullDiff = parseDiffFromFile(oldFile, newFile);
    if (lang != null) fullDiff.lang = lang;
    session = { kind: "editing", itemId, path, token: reply.token, original: current, dirty: false };
    view.updateItem({ ...current, fileDiff: fullDiff, edit: true, collapsed: false, version: nextVersion() });
    refreshHeaders();
  } catch (error) {
    endSession();
    setHeaderError(itemId, labels.editFailed);
    postToNative({ type: "error", message: String((error as Error)?.stack ?? error) });
  }
}

async function saveEdit(): Promise<void> {
  if (session.kind !== "editing") return;
  const editing = session;
  if (!editing.dirty) {
    finishEdit(editing.itemId, editing.original, "reject");
    return;
  }
  // `getText()` reads "" when no session is attached; never write that over the file.
  const contents = view.getEditor(editing.itemId)?.getFile()?.contents;
  if (contents == null) return;
  session = { kind: "saving", itemId: editing.itemId, path: editing.path, token: editing.token, original: editing.original };
  clearHeaderError();
  let reply: SaveReply;
  try {
    reply = parseSaveReply(
      await requestNative({ type: "saveFile", filePath: editing.path, contents, token: editing.token }),
    );
  } catch {
    reply = failureReply(undefined);
  }
  if (session.kind !== "saving" || session.itemId !== editing.itemId) return;
  if (!reply.ok) {
    session = editing;
    setHeaderError(editing.itemId, reply.message);
    return;
  }
  // Native refreshes the review after a save; until then the item shows the saved edit.
  finishEdit(editing.itemId, editing.original, "accept");
}

function cancelEdit(): void {
  if (session.kind !== "editing") return;
  finishEdit(session.itemId, session.original, "reject");
}

function finishEdit(itemId: string, original: CodeViewDiffItem, decision: "accept" | "reject"): void {
  headerError = null;
  const current = view.getItem(itemId);
  if (current?.type === "diff") {
    closingDecisions.set(itemId, decision);
    // The session ends on the complete diff it was opened with: handing a live session the
    // partial patch diff makes Pierre try to hydrate it, which it cannot do without a loader.
    view.updateItem({ ...current, edit: false, version: nextVersion() });
    if (decision === "reject") view.updateItem({ ...original, edit: false, version: nextVersion() });
  }
  endSession();
  refreshHeaders();
}

function endSession(): void {
  session = { kind: "idle" };
  if (reloadPending) {
    reloadPending = false;
    void reload();
  }
}

// Capture phase, so the shortcut wins over the editor's own key handling.
window.addEventListener(
  "keydown",
  (event) => {
    if (session.kind !== "editing" && session.kind !== "saving") return;
    if (!event.metaKey || event.ctrlKey || event.altKey || event.shiftKey || event.key.toLowerCase() !== "s") return;
    event.preventDefault();
    event.stopPropagation();
    void saveEdit();
  },
  { capture: true },
);

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

interface ParsedReview {
  items: CodeViewDiffItem[];
  notices: Map<string, string>;
  editablePaths: Map<string, string>;
}

function itemsFromPatch(
  patchText: string,
  entryNotices: Record<string, string>,
  entryEditablePaths: Record<string, string>,
  cacheKey: string,
): ParsedReview {
  const items: CodeViewDiffItem[] = [];
  const itemNotices = new Map<string, string>();
  const itemEditablePaths = new Map<string, string>();
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
    const editablePath = entryEditablePaths[String(index)];
    if (typeof editablePath === "string") itemEditablePaths.set(id, editablePath);
    items.push({ id, type: "diff", fileDiff, version: nextVersion() });
  });
  return { items, notices: itemNotices, editablePaths: itemEditablePaths };
}

async function fetchEntryMap(path: string): Promise<Record<string, string>> {
  const response = await fetch(path, { cache: "no-store" });
  if (!response.ok) throw new Error(`${path} request failed: ${response.status}`);
  const body: unknown = await response.json();
  if (!isRecord(body)) return {};
  const entries: Record<string, string> = {};
  for (const [key, value] of Object.entries(body)) {
    if (typeof value === "string") entries[key] = value;
  }
  return entries;
}

async function reload(): Promise<void> {
  const current = ++generation;
  if (session.kind !== "idle") {
    reloadPending = true;
    return;
  }
  try {
    const [response, entryNotices, entryEditablePaths] = await Promise.all([
      fetch("/patch", { cache: "no-store" }),
      fetchEntryMap("/notices"),
      fetchEntryMap("/editable"),
    ]);
    if (!response.ok) throw new Error(`patch request failed: ${response.status}`);
    const patchText = await response.text();
    if (current !== generation) return;
    if (session.kind !== "idle") {
      reloadPending = true;
      return;
    }
    const parsed = itemsFromPatch(patchText, entryNotices, entryEditablePaths, `review-${current}`);
    notices = parsed.notices;
    editablePaths = parsed.editablePaths;
    if (headerError != null && !editablePaths.has(headerError.itemId)) headerError = null;
    for (const [id, element] of headerElements) {
      if (notices.has(id) || editablePaths.has(id)) fillHeader(element, id);
      else headerElements.delete(id);
    }
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
