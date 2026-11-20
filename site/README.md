# Programa landing site

Run `bun dev` in this directory and open `http://programa.localhost:4187/`. Run
`bun run build` for the static artifact and `bun test` to check its routes,
metadata and asset references.

Edit the HTML in `pages/` and CSS in `public/styles.css`. The build produces
Markdown from the same page content and preserves content negotiation for
`/`, `/privacy` and `/support`. The site runs without client JavaScript.
The screenshot and icon renditions in `public/assets/` preserve the
production variants and URLs.

The Vercel Build Output API artifact lives in `.vercel/output`. Use the
existing `programa-site` project. The build reads `PUBLIC_SITE_URL` for
absolute metadata and `PUBLIC_SITE_INDEXABLE` for robots and sitemap output.
