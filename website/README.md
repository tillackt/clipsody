# Website

Static site without a build step, scripts, external fonts or tracking. It will be served from GitHub Pages at `https://tillackt.github.io/clipsody/`; canonical URLs, hreflang links, Open Graph tags and the sitemap use that address.

- `index.html`: German home page
- `en/index.html`: English home page
- `zwischenablage-verlauf-mac.html`, `en/clipboard-history-mac.html`: guides "how to see the clipboard history on a Mac" (DE/EN), aimed at people who search for the problem rather than for an app
- `impressum.html`, `datenschutz.html`: legal notice and privacy policy (German, placeholders for now, `noindex`)
- `404.html`: shown by GitHub Pages for unknown paths (`noindex`, root paths under `/clipsody/`)
- `sitemap.xml`: all indexable pages with their language versions
- `assets/`: stylesheet, logo, social preview images (`og-de.png`, `og-en.png`, 1200×630) and the Apple touch icon (`icon-180.png`)

## Search engines

The pages target what people type when they lose a copied item: "Zwischenablage Verlauf Mac", "Mac mehrere Einträge kopieren", "Multi-Zwischenablage", "Clipboard Manager Mac kostenlos", "clipboard history mac", "copy multiple items mac". Each page has one H1, a title of about 60 characters and a description of about 155.

Structured data (JSON-LD) is generated from the pages: `SoftwareApplication` and `FAQPage` on the home pages, `Article`, `BreadcrumbList` and `FAQPage` on the guides. The FAQ answers are taken from the visible `<details>` blocks, so they never differ from the page. After changing a page or an FAQ entry:

```bash
python3 .github/scripts/structured-data.py
```

CI (`website.yml`) fails if the structured data is out of date. The preview images and the touch icon are rendered from the logo:

```bash
swift .github/scripts/website-images.swift
```

When content changes, update `dateModified` in the script and `lastmod` in `sitemap.xml`.

## Before publishing

1. ~~**GitHub account**~~: done, `tillackt` (repository `tillackt/clipsody`).
2. ~~**License**~~: done, GPLv3 (see `LICENSE` in the repository).
3. ~~**Certificate fingerprint**~~: done. `./build.sh release` writes it to the release notes; it stays the same as long as the same certificate signs.
4. **Legal notice and privacy policy**: fill in and have them checked.
5. ~~**Download link**~~: done; the pages link to `…/releases/latest/download/Clipsody.dmg`, which `./build.sh release` uploads under exactly this name.

## After publishing

1. Register the site in [Google Search Console](https://search.google.com/search-console) (URL prefix `https://tillackt.github.io/clipsody/`) and in [Bing Webmaster Tools](https://www.bing.com/webmasters), and submit `sitemap.xml` there. A project site cannot have its own `robots.txt` (crawlers only read the one at `tillackt.github.io/robots.txt`), so the sitemap has to be submitted by hand.
2. Check the structured data with Google's [Rich Results Test](https://search.google.com/test/rich-results).
3. Links from other sites decide most of the ranking. Free options: GitHub topics on the repository (e.g. `clipboard-manager`, `clipboard-history`, `macos`), AlternativeTo, MacUpdate, a Homebrew cask, Product Hunt, r/macapps, and tips to German Mac sites that cover free apps.

## Publishing with your own domain

GitHub Pages can serve this folder (repository settings → Pages, e.g. through a GitHub Action that publishes `website/`). A custom domain would need the absolute URLs above changed (pages, `sitemap.xml`, `.github/scripts/structured-data.py`) and redirects from the old address.

View locally:

```bash
python3 -m http.server 8765 --directory website
```
