import { beforeAll, expect, test } from "bun:test";
import { resolve } from "node:path";

const root = resolve(import.meta.dir, "..");
const output = `${root}/.vercel/output/static`;

beforeAll(() => {
  const result = Bun.spawnSync(["bun", "run", "build"], {
    cwd: root,
    env: {
      ...process.env,
      PUBLIC_SITE_URL: "https://programa.darkroom.engineering",
      PUBLIC_SITE_INDEXABLE: "true",
    },
  });
  if (result.exitCode !== 0) throw new Error(result.stderr.toString());
});

test("builds landing, privacy and support pages without a client script", async () => {
  for (const page of ["index", "privacy", "support", "404"]) {
    const document = await Bun.file(`${output}/${page}.html`).text();
    expect(document).toMatch(/<main>[\s\S]+<h1/);
    expect(document).not.toMatch(/<script\b(?! type="application\/ld\+json">)/);
    for (const match of document.matchAll(/\b(?:href|src)="(\/(?:assets\/[^"]+|[^"/]+\.[a-z]+))"/g)) {
      expect(await Bun.file(`${output}${match[1]}`).exists()).toBe(true);
    }
  }
});

test("preserves canonical URL, Markdown negotiation and the custom 404 status", async () => {
  const sitemap = await Bun.file(`${output}/sitemap.xml`).text();
  const support = await Bun.file(`${output}/support.md`).text();
  const config = await Bun.file(`${root}/.vercel/output/config.json`).json();
  expect(sitemap).toContain("<loc>https://programa.darkroom.engineering/privacy</loc>");
  expect(support).toContain("[github.com/darkroomengineering/programa/issues](https://github.com/darkroomengineering/programa/issues)");
  expect(config.routes).toContainEqual({
    src: "^/(privacy|support)/?$",
    dest: "/$1.md",
    has: [{ type: "header", key: "accept", value: ".*text/markdown.*" }],
  });
  expect(config.routes).toContainEqual({ src: "^/.*$", dest: "/404.html", status: 404 });
});
