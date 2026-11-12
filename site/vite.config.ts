import { vercel } from "@visio/vercel";
import { visio } from "visio";
import { defineConfig } from "vite";

export default defineConfig({
  plugins: [
    // What visio() wires and in which order: vendor/visio/visio/DESIGN.md.
    // The origin and whether search engines may index the deployment come
    // from PUBLIC_SITE_URL and PUBLIC_SITE_INDEXABLE in the env.
    visio({
      site: {
        name: "Programa",
        locale: "en_US",
        image: {
          url: "/og.png",
          width: 1200,
          height: 630,
          alt: "The Programa app icon next to the name and the line Run many coding agents at once and always know which one needs you",
        },
      },
      deploy: vercel(),
    }),
  ],
  server: {
    port: 3000,
  },
});
