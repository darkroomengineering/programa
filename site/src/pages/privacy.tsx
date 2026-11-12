import { defineRoute } from "@visio/router";
import { css } from "@visio/styling";

import { Prose } from "../components/prose";
import { ISSUES, NAME } from "../lib/product";
import { t } from "../styles/tokens";

export const route = defineRoute("/privacy", {
  meta: () => ({
    title: `Privacy policy · ${NAME}`,
    description:
      "Programa has no analytics, no crash reporting and no accounts. It contacts GitHub to check for updates, and runs your own gh CLI to show pull request status.",
  }),
});

const s = css({
  // Links inside a sentence, which the 44px target rule exempts.
  link: {
    textDecorationLine: "underline",
    textUnderlineOffset: "0.2em",
    hover: { color: t.colors.accent },
    ":active": { color: t.colors.accent },
  },
});

export default function Privacy() {
  return (
    <Prose title="Programa privacy policy">
      <p>
        Programa does not collect personal data. It has no accounts, no
        analytics and no crash reporting, and Darkroom Engineering runs no
        server for it. Your terminals, sessions and settings stay on your
        computer.
      </p>
      <p>
        <strong>Updates.</strong> Once a day the Mac app downloads the update
        feed from the Programa releases on GitHub, and downloads a new version
        when there is one. It sends no system profile with the check. GitHub
        sees the request like any other download, under{" "}
        <a
          class={s.link}
          href="https://docs.github.com/en/site-policy/privacy-policies/github-general-privacy-statement"
        >
          GitHub's privacy statement
        </a>
        .
      </p>
      <p>
        <strong>Pull request status.</strong> To show a branch's pull request
        and checks in the sidebar, Programa runs the GitHub CLI (<code>gh</code>
        ) installed on your computer, signed in as you. Those requests go from
        your computer to GitHub, the same as running <code>gh</code> yourself.
      </p>
      <p>
        <strong>What runs in it.</strong> The agents and programs you start in a
        Programa terminal make their own network requests under their own
        policies. Programa does not send their output anywhere.
      </p>
      <p>
        Questions:{" "}
        <a class={s.link} href={ISSUES}>
          open an issue on GitHub
        </a>
        .
      </p>
      <p>Last updated: November 12, 2026.</p>
    </Prose>
  );
}
