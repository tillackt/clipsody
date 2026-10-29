# Website

Static site without a build step, scripts, external fonts or tracking.

- `index.html`: German
- `en/index.html`: English
- `impressum.html`, `datenschutz.html`: legal notice and privacy policy (German, placeholders for now)
- `assets/`: stylesheet and logo

## Before publishing

1. ~~**GitHub account**~~: done, `tillackt` (repository `tillackt/clipsody`).
2. ~~**License**~~: done, GPLv3 (see `LICENSE` in the repository).
3. ~~**Certificate fingerprint**~~: done. `./build.sh release` writes it to `build/release-notes.txt`; it stays the same as long as the same certificate signs.
4. **Legal notice and privacy policy**: fill in and have them checked.
5. **Download link:** the pages link to `…/releases/latest/download/Clipsody.dmg`. That works as soon as every release contains a file with exactly this name.

## Publishing with your own domain

GitHub Pages can serve this folder (repository settings → Pages, e.g. through a GitHub Action that publishes `website/`) and connect a custom domain with HTTPS. Alternatively, upload the folder's contents to any web space.

View locally:

```bash
open website/index.html
```
