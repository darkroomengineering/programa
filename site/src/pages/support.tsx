import { defineRoute } from "@visio/router";
import { css } from "@visio/styling";

import { Prose } from "../components/prose";
import { ISSUES, NAME } from "../lib/product";
import { t } from "../styles/tokens";

export const route = defineRoute("/support", {
  meta: () => ({
    title: `Support · ${NAME}`,
    description:
      "Get help with Programa on GitHub. Include your macOS or Windows version, the Programa version, and what happened.",
  }),
});

const s = css({
  issues: {
    ...t.type.lead,
    display: "inline-flex",
    alignItems: "center",
    justifySelf: "start",
    minBlockSize: "44px",
    color: t.colors.accent,
    textDecorationLine: "underline",
    textUnderlineOffset: "0.2em",
    overflowWrap: "anywhere",
    hover: { color: t.colors.ink },
    ":active": { color: t.colors.ink },
  },
  note: {
    color: t.colors.dim,
  },
});

export default function Support() {
  return (
    <Prose title="Support">
      <p>
        For help with Programa, or to report a bug, open an issue on GitHub.
      </p>
      <a class={s.issues} href={ISSUES}>
        github.com/darkroomengineering/programa/issues
      </a>
      <p class={s.note}>
        It helps to include your macOS or Windows version, the Programa version
        from the About window, and what happened.
      </p>
    </Prose>
  );
}
