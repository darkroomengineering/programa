import { Image } from "@visio/image-optimizer";
import type { Meta } from "@visio/router";
import { absoluteUrl, defineRoute } from "@visio/router";
import { columns, css, dp, GRID, sizes } from "@visio/styling";

import appIcon from "../assets/app-icon.png?responsive";
import workspace from "../assets/workspace.png?responsive";
import { MAC_DMG, NAME, REPO, WINDOWS_EXE } from "../lib/product";
import { t } from "../styles/tokens";

// The first line of the README.
const PITCH =
  "The open source terminal for running many coding agents at once and always knowing which one needs you. Native macOS on Ghostty, native Windows on WinUI.";

const DESCRIPTION =
  "Programa is an open source terminal for running many coding agents in parallel. Every workspace shows whether its agent is working, blocked or idle, and a waiting agent's pane lights up. Native macOS on Ghostty.";

const ICON_SIZES = sizes({ mobile: 88, desktop: 112 });
const SHOT_SIZES = sizes({ mobile: columns(4), desktop: columns(12) });

export const route = defineRoute("/", {
  meta: (): Meta => ({
    title: "Programa: a terminal for running many coding agents at once",
    description: DESCRIPTION,
    social: {
      title: NAME,
      description:
        "Run many coding agents in parallel and always know which one needs you.",
    },
    jsonLd: [
      {
        "@context": "https://schema.org",
        "@type": "SoftwareApplication",
        name: NAME,
        url: absoluteUrl("/"),
        description: DESCRIPTION,
        applicationCategory: "DeveloperApplication",
        operatingSystem: "macOS 14 or later",
        downloadUrl: MAC_DMG,
        image: absoluteUrl("/og.png"),
        license: "https://www.gnu.org/licenses/gpl-3.0.html",
        offers: { "@type": "Offer", price: "0", priceCurrency: "USD" },
        featureList: [
          "Working, blocked or idle status for every agent workspace",
          "Notifications that point at the agent waiting for you",
          "Vertical workspace sidebar with branch, PR status and ports",
          "Diff review panel that sends comments to the agent",
          "Git worktrees as workspaces",
          "Native Swift and AppKit with libghostty rendering",
        ],
        publisher: {
          "@type": "Organization",
          name: "Darkroom Engineering",
          url: "https://darkroom.engineering",
        },
      },
      {
        "@context": "https://schema.org",
        "@type": "WebSite",
        name: NAME,
        url: absoluteUrl("/"),
      },
    ],
  }),
});

const s = css({
  wrap: {
    maxInlineSize: t.layout.frame,
    marginInline: "auto",
    paddingInline: t.layout.safe,
  },
  hero: {
    display: "grid",
    justifyItems: "start",
    rowGap: dp(20),
    paddingBlockStart: dp(48),
    paddingBlockEnd: dp(40),
    desktop: {
      rowGap: dp(28),
      paddingBlockStart: dp(96),
      paddingBlockEnd: dp(56),
    },
  },
  icon: {
    inlineSize: t.sizes.icon,
    blockSize: t.sizes.icon,
  },
  name: {
    ...t.type.display,
  },
  pitch: {
    ...t.type.lead,
    maxInlineSize: t.sizes.measure,
    color: t.colors.dim,
  },
  downloads: {
    display: "flex",
    flexWrap: "wrap",
    columnGap: dp(12),
    rowGap: dp(12),
    paddingInlineStart: 0,
    listStyleType: "none",
  },
  primary: {
    ...t.type.button,
    display: "inline-flex",
    alignItems: "center",
    minBlockSize: "48px",
    paddingInline: dp(24),
    color: t.colors.page,
    backgroundColor: t.colors.ink,
    borderRadius: "8px",
    hover: { backgroundColor: t.colors.accent },
    ":active": { backgroundColor: t.colors.accent },
    ":focus-visible": {
      outlineColor: t.colors.accent,
      outlineOffset: "3px",
    },
  },
  secondary: {
    ...t.type.button,
    display: "inline-flex",
    alignItems: "center",
    minBlockSize: "48px",
    paddingInline: dp(24),
    borderWidth: "1px",
    borderStyle: "solid",
    borderColor: t.colors.dim,
    borderRadius: "8px",
    hover: { color: t.colors.accent, borderColor: t.colors.accent },
    ":active": { color: t.colors.accent, borderColor: t.colors.accent },
  },
  requirements: {
    ...t.type.note,
    maxInlineSize: t.sizes.measure,
    color: t.colors.dim,
  },
  shot: {
    maxInlineSize: t.layout.frame,
    marginInline: "auto",
    paddingInline: t.layout.safe,
  },
  feature: {
    display: "grid",
    rowGap: dp(16),
    paddingBlock: dp(32),
    borderBlockStartWidth: "1px",
    borderBlockStartStyle: "solid",
    borderBlockStartColor: t.colors.rule,
    desktop: {
      ...GRID,
      paddingBlock: dp(48),
    },
  },
  features: {
    marginBlockStart: dp(56),
    paddingBlockEnd: dp(40),
    desktop: { marginBlockStart: dp(96) },
  },
  featureTitle: {
    ...t.type.title,
    desktop: { gridColumn: "span 5" },
  },
  featureList: {
    display: "grid",
    rowGap: dp(8),
    paddingInlineStart: dp(20),
    color: t.colors.dim,
    desktop: { gridColumn: "span 7" },
  },
  code: {
    ...t.type.code,
    color: t.colors.ink,
  },
});

export default function Home() {
  return (
    <>
      <header class={s.wrap}>
        <div class={s.hero}>
          <Image
            class={s.icon}
            src={appIcon}
            alt="Programa app icon: a grid of red and orange squares on a dark tile"
            sizes={ICON_SIZES}
            loading="eager"
          />
          <h1 class={s.name}>{NAME}</h1>
          <p class={s.pitch}>{PITCH}</p>
          <ul class={s.downloads}>
            <li>
              <a class={s.primary} href={MAC_DMG}>
                Download for Mac
              </a>
            </li>
            <li>
              <a class={s.secondary} href={WINDOWS_EXE}>
                Windows preview
              </a>
            </li>
            <li>
              <a class={s.secondary} href={REPO}>
                Source on GitHub
              </a>
            </li>
          </ul>
          <p class={s.requirements}>
            macOS 14 or later. The Mac app updates itself. The Windows app is in
            development: desktop interaction testing and macOS feature parity
            are incomplete. Free and open source under GPL-3.0.
          </p>
        </div>
      </header>

      <div class={s.shot}>
        <Image
          src={workspace}
          alt="Programa: workspace sidebar with agent status, a Claude Code session waiting for input"
          sizes={SHOT_SIZES}
          preload
        />
      </div>

      <div class={s.wrap}>
        <div class={s.features}>
          <section class={s.feature}>
            <h2 class={s.featureTitle}>Know which agent needs you</h2>
            <ul class={s.featureList}>
              <li>
                Every workspace shows working, blocked or idle. Claude Code,
                Codex and OpenCode report it directly; Gemini CLI, Copilot CLI,
                Cursor Agent and Aider get it from reading the terminal screen.
              </li>
              <li>
                A waiting agent's pane gets a ring, its tab lights up, and ⌘⇧U
                jumps to the latest unread.
              </li>
              <li>
                A vertical sidebar shows the git branch, PR status, working
                directory, listening ports and latest notification for every
                workspace.
              </li>
            </ul>
          </section>

          <section class={s.feature}>
            <h2 class={s.featureTitle}>Review and branch</h2>
            <ul class={s.featureList}>
              <li>
                A diff review panel beside an agent's terminal: comment on the
                diff and send the comments straight into the agent's input.
              </li>
              <li>
                <code class={s.code}>programa worktree create</code> checks out
                a git worktree and opens it as its own workspace.
              </li>
              <li>
                <code class={s.code}>programa race</code> fans one prompt across
                several agents, each in its own worktree, so you can compare
                approaches.
              </li>
            </ul>
          </section>

          <section class={s.feature}>
            <h2 class={s.featureTitle}>Native and scriptable</h2>
            <ul class={s.featureList}>
              <li>
                Swift and AppKit with libghostty rendering, no Electron. It
                reads your existing Ghostty config for themes, fonts and colors.
              </li>
              <li>
                Relaunch restores layout, directories and scrollback, and
                terminal processes survive Programa quitting or crashing.
              </li>
              <li>
                A CLI, a Unix-socket JSON-RPC API and an MCP server, so agents
                can split panes and read a sibling pane's output.
              </li>
            </ul>
          </section>
        </div>
      </div>
    </>
  );
}
