import { cp, mkdir, mkdtemp, rename, rm } from "node:fs/promises";
import { join } from "node:path";

const productionOrigin = "https://programa.darkroom.engineering";
const { PUBLIC_SITE_URL, PUBLIC_SITE_INDEXABLE } = process.env;
const origin = new URL(PUBLIC_SITE_URL ?? productionOrigin);
if (!["http:", "https:"].includes(origin.protocol) || origin.href !== `${origin.origin}/`) {
  throw new Error("PUBLIC_SITE_URL must be an HTTP or HTTPS origin");
}
if (PUBLIC_SITE_INDEXABLE !== undefined && !["true", "false"].includes(PUBLIC_SITE_INDEXABLE)) {
  throw new Error("PUBLIC_SITE_INDEXABLE must be true or false");
}
const indexable = PUBLIC_SITE_INDEXABLE === "true" && PUBLIC_SITE_URL !== undefined;
const routes = [
  { page: "index", pathname: "/" },
  { page: "privacy", pathname: "/privacy" },
  { page: "support", pathname: "/support" },
];
const securityHeaders = {
  "x-content-type-options": "nosniff",
  "referrer-policy": "strict-origin-when-cross-origin",
  "x-frame-options": "SAMEORIGIN",
};
const markdownAccept = [{ type: "header", key: "accept", value: ".*text/markdown.*" }];

function markdown(page: string, pathname: string) {
  const title = page.match(/<title>([^<]+)<\/title>/)?.[1];
  const description = page.match(/<meta name="description" content="([^"]+)">/)?.[1];
  const main = page.match(/<main>([\s\S]*?)<\/main>/)?.[1];
  if (!title || !description || !main) throw new Error(`Missing content for ${pathname}`);

  const absolute = (path: string) => new URL(path, origin).href;
  const decode = (value: string) => value
    .replaceAll("&#x27;", "'")
    .replaceAll("&quot;", '"')
    .replaceAll("&amp;", "&");
  const body = main
    .replace(/^\s+|\s+$/gm, "")
    .replace(/<source\b[^>]*>/g, "")
    .replace(/\s*<\/?picture\b[^>]*>\s*/g, "")
    .replace(/<img\b([^>]*)>/g, (_tag: string, attrs: string) => {
      const src = attrs.match(/\bsrc="([^"]+)"/)?.[1];
      const alt = attrs.match(/\balt="([^"]*)"/)?.[1];
      if (!src || alt === undefined) throw new Error(`Missing image source or alt in ${pathname}`);
      return `![${decode(alt)}](${absolute(src)})\n\n`;
    })
    .replace(/(^\s*<a\b[^>]*>[^<]+<\/a>\s*)$/gm, "$1\n")
    .replace(/<a\b[^>]*href="([^"]+)"[^>]*>([^<]+)<\/a>/g, (_tag: string, href: string, text: string) =>
      `[${decode(text)}](${absolute(decode(href))})`)
    .replace(/<strong>([^<]+)<\/strong>/g, "**$1**")
    .replace(/<code\b[^>]*>([^<]+)<\/code>/g, "`$1`")
    .replace(/<h1\b[^>]*>([^<]+)<\/h1>/g, "# $1\n\n")
    .replace(/<h2\b[^>]*>([^<]+)<\/h2>/g, "## $1\n\n")
    .replace(/<li\b[^>]*>\s*/g, "- ")
    .replace(/<\/li>\s*/g, "\n")
    .replace(/<\/(?:p|ul)>/g, "\n\n")
    .replace(/<[^>]+>/g, "")
    .replace(/(- !\[[^\n]+\))\n{2,}(?=- !\[)/g, "$1\n")
    .replace(/\n{3,}/g, "\n\n")
    .trim();

  return `---\ntitle: ${JSON.stringify(decode(title))}\ndescription: ${JSON.stringify(decode(description))}\nurl: ${JSON.stringify(absolute(pathname))}\n---\n\n${decode(body)}\n`;
}

await mkdir(".vercel", { recursive: true });
const staging = await mkdtemp(".vercel/output-");
const staticRoot = join(staging, "static");
try {
  await cp("public", staticRoot, { recursive: true });
  for (const { page, pathname } of routes) {
    const source = await Bun.file(`pages/${page}.html`).text();
    const document = source.replaceAll(productionOrigin, origin.origin);
    await Bun.write(join(staticRoot, `${page}.html`), indexable
      ? document
      : document.replace("</head>", '  <meta name="robots" content="noindex, nofollow">\n  </head>'));
    await Bun.write(join(staticRoot, `${page}.md`), markdown(source, pathname));
  }

  await cp("pages/404.html", join(staticRoot, "404.html"));
  const robots = indexable
    ? `User-agent: *\nAllow: /\nContent-Signal: search=yes, ai-input=yes\n\nSitemap: ${origin.origin}/sitemap.xml\n`
    : "User-agent: *\nDisallow: /\n";
  await Bun.write(join(staticRoot, "robots.txt"), robots);
  const llms = await Bun.file("public/llms.txt").text();
  await Bun.write(join(staticRoot, "llms.txt"), llms.replaceAll(productionOrigin, origin.origin));
  if (indexable) {
    const sitemap = await Bun.file("public/sitemap.xml").text();
    await Bun.write(join(staticRoot, "sitemap.xml"), sitemap.replaceAll(productionOrigin, origin.origin));
  } else {
    await rm(join(staticRoot, "sitemap.xml"));
  }

  const config = {
    version: 3,
    overrides: Object.fromEntries(routes.map(({ page }) => [
      `${page}.md`, { contentType: "text/markdown; charset=utf-8" },
    ])),
    routes: [
      { src: "^/.*$", headers: securityHeaders, continue: true },
      { src: "^/(?:privacy/?|support/?)?$", headers: { vary: "Accept" }, continue: true },
      { src: "^/$", dest: "/index.md", has: markdownAccept },
      { src: "^/(privacy|support)/?$", dest: "/$1.md", has: markdownAccept },
      { src: "^/$", dest: "/index.html" },
      { src: "^/(privacy|support)/?$", dest: "/$1.html" },
      { handle: "filesystem" },
      { src: "^/.*$", dest: "/404.html", status: 404 },
      { handle: "hit" },
      {
        src: "^/assets/[^/]*-[A-Za-z0-9_-]{8}\\.[^/]+$",
        headers: { "cache-control": "public, max-age=31536000, immutable" },
        continue: true,
      },
    ],
  };
  await Bun.write(join(staging, "config.json"), `${JSON.stringify(config, null, 2)}\n`);
  await rm(".vercel/output", { recursive: true, force: true });
  await rename(staging, ".vercel/output");
} catch (error) {
  await rm(staging, { recursive: true, force: true });
  throw error;
}

console.log("Built Programa to .vercel/output/static");
