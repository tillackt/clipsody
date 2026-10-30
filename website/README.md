# Website

Static site without scripts, external fonts or tracking, in the same 8 languages as the app. It will be served from GitHub Pages at `https://tillackt.github.io/clipsody/`; canonical URLs, hreflang links, Open Graph tags and the sitemap use that address.

## How the pages are made

The home page, the guide and the support page exist in every language and are generated:

- `site/content/<lang>.json`: all texts of one language (`de`, `en`, `fr`, `es`, `it`, `nl`, `pl`, `pt-BR`). Every file has the same keys as `en.json`.
- `site/build.py`: the HTML structure, the animated hero, the JSON-LD structured data (FAQ entries are the visible ones) and `sitemap.xml`.
- `website/`: the generated output, committed, so the server needs no build step.

After changing a text or the structure:

```bash
python3 site/build.py
```

CI (`website.yml`) runs `python3 site/build.py --check` and fails if `website/` is out of date. To add a language: add `site/content/<lang>.json` (copy `en.json`), add it to `LANGUAGES` in `site/build.py`, and build.

German is at the root (`/`), the other languages in folders (`/en/`, `/fr/`, …, `/pt-br/`); English is `x-default`. Guides: `zwischenablage-verlauf-mac.html`, `en/clipboard-history-mac.html` and one per language (file name in each JSON's `guideFile`).

The support page (`support.html`) has a form without script or server: it sends a GET request to GitHub's issue form (`.github/ISSUE_TEMPLATE/`), with the entries as query parameters named after the form fields' `id`s (`title`, `description`, `clipsody-version`, `macos-version`); the visitor submits the issue on GitHub. Keep the field ids in the templates and the form in `site/build.py` in step.

Hand-written pages: `impressum.html`, `datenschutz.html` (German, placeholders for now, `noindex`) and `404.html` (`noindex`, root paths under `/clipsody/`). `assets/` holds the stylesheet, the logo, the social preview images (`og-de.png`, `og-en.png`, 1200×630), the Apple touch icon (`icon-180.png`) and `sample-photo.jpg`, the photo shown in the hero (generated with Codex's image model, no third-party rights).

## Search engines

The pages target what people type when they lose a copied item, in each language: "Zwischenablage Verlauf Mac", "Multi-Zwischenablage", "clipboard history mac", "copy multiple items mac", "historique presse-papiers mac", "historial portapapeles mac" and so on. Each page has one H1, a title of about 60 characters and a description of about 155.

The preview images and the touch icon are rendered from the logo:

```bash
swift .github/scripts/website-images.swift
```

When content changes, update `MODIFIED` in `site/build.py` (used for `dateModified` and `lastmod`).

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

GitHub Pages can serve this folder (repository settings → Pages, e.g. through a GitHub Action that publishes `website/`). A custom domain would need `SITE` in `site/build.py` changed (then rebuild) and redirects from the old address.

View locally:

```bash
python3 -m http.server 8765 --bind 127.0.0.1 --directory website
```
