# Website

Statische Seite ohne Build-Schritt, ohne Skripte, ohne externe Schriftarten und ohne Tracking.

- `index.html`: Deutsch
- `en/index.html`: Englisch
- `impressum.html`, `datenschutz.html`: Platzhalter
- `assets/`: Stylesheet und Logo

## Vor der Veröffentlichung

1. ~~**GitHub-Name**~~: erledigt, `tillackt` (Repo `tillackt/clippboard`).
2. ~~**Lizenz**~~: erledigt, GPLv3 (siehe `LICENSE` im Repo).
3. ~~**Zertifikat-Fingerabdruck**~~: erledigt. `./build.sh release` gibt ihn in `build/release-notes.txt` aus; er bleibt gleich, solange dasselbe Zertifikat signiert.

4. **Impressum und Datenschutz** ausfüllen und prüfen lassen.
5. **Download-Link:** Die Seite verlinkt auf `…/releases/latest/download/Clippboard.dmg`. Das funktioniert, sobald jedes Release eine Datei mit genau diesem Namen enthält.

## Veröffentlichen mit eigener Domain

GitHub Pages kann diesen Ordner ausliefern (Repository-Einstellungen → Pages, z. B. über eine GitHub Action, die `website/` veröffentlicht) und eine eigene Domain mit HTTPS verbinden. Alternativ den Ordnerinhalt auf beliebigen Webspace hochladen.

Lokal ansehen:

```bash
open website/index.html
```
