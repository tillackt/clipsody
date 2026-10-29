# Website

Statische Seite ohne Build-Schritt, ohne Skripte, ohne externe Schriftarten und ohne Tracking.

- `index.html`: Deutsch
- `en/index.html`: Englisch
- `impressum.html`, `datenschutz.html`: Platzhalter
- `assets/`: Stylesheet und Logo

## Vor der Veröffentlichung

1. **GitHub-Name:** `DEIN-GITHUB-NAME` in `index.html` und `en/index.html` durch den GitHub-Account ersetzen.
2. **Lizenz:** `LIZENZ-EINTRAGEN` im Fußbereich beider Seiten ersetzen, sobald sie feststeht.
3. **Zertifikat-Fingerabdruck:** `WIRD-MIT-DEM-ERSTEN-RELEASE-EINGETRAGEN` bzw. `ADDED-WITH-THE-FIRST-RELEASE` mit dem SHA-256 des Signaturzertifikats füllen:

   ```bash
   codesign -d --extract-certificates /Applications/Clippboard.app && shasum -a 256 codesign0
   ```

4. **Impressum und Datenschutz** ausfüllen und prüfen lassen.
5. **Download-Link:** Die Seite verlinkt auf `…/releases/latest/download/Clippboard.dmg`. Das funktioniert, sobald jedes Release eine Datei mit genau diesem Namen enthält.

## Veröffentlichen mit eigener Domain

GitHub Pages kann diesen Ordner ausliefern (Repository-Einstellungen → Pages, z. B. über eine GitHub Action, die `website/` veröffentlicht) und eine eigene Domain mit HTTPS verbinden. Alternativ den Ordnerinhalt auf beliebigen Webspace hochladen.

Lokal ansehen:

```bash
open website/index.html
```
