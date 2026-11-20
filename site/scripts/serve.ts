import { resolve, sep } from "node:path";

const root = resolve(".vercel/output/static");
const documents = new Map([
  ["/", "index"],
  ["/privacy", "privacy"],
  ["/support", "support"],
]);

const server = Bun.serve({
  hostname: "127.0.0.1",
  port: Number(process.env.PORT ?? 4187),
  async fetch(request) {
    const pathname = new URL(request.url).pathname;
    const document = documents.get(pathname.replace(/\/$/, "") || "/");
    const markdown = document && request.headers.get("accept")?.includes("text/markdown");
    const path = document ? `${document}.${markdown ? "md" : "html"}` : pathname.slice(1);
    const absolute = resolve(root, path);
    if (!absolute.startsWith(`${root}${sep}`)) return new Response("Bad path", { status: 400 });
    const file = Bun.file(absolute);
    if (!(await file.exists())) return new Response(Bun.file(`${root}/404.html`), { status: 404 });

    const headers = new Headers();
    if (document) headers.set("vary", "Accept");
    if (path.endsWith(".md")) headers.set("content-type", "text/markdown; charset=utf-8");
    return new Response(file, { headers });
  },
});

console.log(`Programa preview: http://programa.localhost:${server.port}/`);
