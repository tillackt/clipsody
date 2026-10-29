# Clippboard

Schlanke Clipboard-Historie für macOS als Ersatz für Alfreds Clipboard-Feature. Native Swift/AppKit-App ohne Abhängigkeiten.

## Bedienung

| Taste | Aktion |
|---|---|
| ⌥⌘C | Historie öffnen/schließen |
| Tippen | Filtern (mehrere Wörter = alle müssen vorkommen; sucht auch im App-Namen und im Text auf Bildern) |
| ↑ / ↓, Bild ↑/↓ | Eintrag wählen |
| ⏎ oder Doppelklick | In die aktive App einfügen (Text ohne Formatierung) |
| ⌥⏎ | Mit Formatierung einfügen (fett, Links, Tabellen aus Word, Outlook, Browser …) |
| ⌘1 … ⌘9 | n-ten Eintrag direkt einfügen |
| ⌘P | Eintrag anpinnen/lösen: bleibt oben und wird nie automatisch gelöscht |
| ⌘⌫ | Eintrag löschen |
| Esc | Schließen |

Rechts steht eine Vorschau (voller Text oder Bild), darunter App, Alter und Größe. Suchbegriffe werden in Liste und Vorschau markiert.

- **Bilder** werden verlustfrei als PNG gespeichert. Der Text darauf wird lokal per macOS-Texterkennung (Vision) gelesen, damit Screenshots über ihren Inhalt auffindbar sind.
- **Dateien** aus dem Finder werden als Dateien wieder eingefügt, nicht als Pfad. Wurde eine Datei inzwischen verschoben oder gelöscht, piept es.

## Bauen & installieren

```bash
./build.sh install
```

Baut `build/Clippboard.app`, kopiert sie nach `~/Applications` und startet sie. Beim ersten Start:

1. **Bedienungshilfen** erlauben (Systemeinstellungen → Datenschutz & Sicherheit → Bedienungshilfen → Clippboard). Ohne das wird der Eintrag nur in die Zwischenablage gelegt, nicht eingefügt. Nach jedem Neubau muss die Berechtigung neu gesetzt werden (Ad-hoc-Signatur): Eintrag entfernen und wieder hinzufügen.
2. Menüleisten-Icon → **Einstellungen …** → Autostart einschalten.
3. In Alfred den Clipboard-Hotkey abschalten oder Alfred beenden, sonst reagieren beide auf ⌥⌘C.

### Berechtigung über Neubauten hinweg behalten (einmalig)

Ohne eigenes Zertifikat signiert `build.sh` ad hoc, und macOS vergisst die Bedienungshilfen-Berechtigung bei jedem Neubau. Abhilfe:

1. Schlüsselbundverwaltung öffnen → Menü **Schlüsselbundverwaltung → Zertifikatsassistent → Zertifikat erstellen …**
2. Name: `Clippboard Signing`, Identitätstyp: **Selbstsignierter Root**, Zertifikatstyp: **Codesignierung** → Erstellen.
3. `./build.sh install` ausführen und die Berechtigung ein letztes Mal setzen.

`build.sh` nimmt das Zertifikat automatisch, sobald es vorhanden ist.

Die Alfred-Historie wird beim ersten Start einmalig importiert. Ein erneuter Import ist mit `~/Applications/Clippboard.app/Contents/MacOS/Clippboard --import-alfred` möglich.

## Einstellungen

Menüleisten-Icon → **Einstellungen …** (⌘,). Jede Option ist dort erklärt, Änderungen gelten sofort. Gespeichert wird in `~/Library/Application Support/Clippboard/config.json`:

| Schlüssel | Standard | Bedeutung |
|---|---|---|
| `hotkey` | `cmd+option+c` | Modifier `cmd`, `option`, `ctrl`, `shift` + Buchstabe/Ziffer/`space` |
| `retentionDays` | `7` | Einträge älter als n Tage werden gelöscht |
| `maxItems` | `1000` | Maximale Anzahl Einträge |
| `keepImages` | `true` | Bilder speichern |
| `ignoredApps` | Passwort-Manager | Bundle-IDs, aus denen nichts gespeichert wird |

Einträge, die Passwort-Manager als vertraulich markieren (`org.nspasteboard.ConcealedType`), werden nie gespeichert.

## Daten

- `history.sqlite`: Einträge
- `images/`: Bilder als PNG
