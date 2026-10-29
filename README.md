# Clippboard

Schlanke Clipboard-Historie für macOS als Ersatz für Alfreds Clipboard-Feature. Native Swift/AppKit-App ohne Abhängigkeiten.

## Bedienung

| Taste | Aktion |
|---|---|
| ⌥⌘C | Historie öffnen/schließen |
| Tippen | Filtern (mehrere Wörter = alle müssen vorkommen; sucht auch im App-Namen und im Text auf Bildern) |
| ↑ / ↓, Bild ↑/↓ | Eintrag wählen |
| ⏎ oder Doppelklick | In die aktive App einfügen, mit Formatierung (fett, Links, Tabellen aus Word, Outlook, Browser …) |
| ⌥⏎ | Nur den reinen Text einfügen, ohne Formatierung |
| ⌘1 … ⌘9 | n-ten Eintrag direkt einfügen |
| ⌘P | Eintrag anpinnen/lösen: bleibt oben und wird nie automatisch gelöscht |
| ⌘⌫ | Eintrag löschen |
| Esc | Schließen |

Rechts steht eine Vorschau (voller Text oder Bild), darunter App, Alter und Größe. Suchbegriffe werden in Liste und Vorschau markiert.

- **Bilder** werden verlustfrei als PNG gespeichert. Der Text darauf wird lokal per macOS-Texterkennung (Vision) gelesen, damit Screenshots über ihren Inhalt auffindbar sind.
- **Dateien** aus dem Finder werden als Dateien wieder eingefügt, nicht als Pfad. Wurde eine Datei inzwischen verschoben oder gelöscht, piept es.

## Projekt

Swift-Paket mit drei Zielen:

- `Sources/ClippboardCore`: Speicher (SQLite mit versionierten Migrationen), Konfiguration, Bildumwandlung, Suche und Alfred-Import, ohne AppKit
- `Sources/Clippboard`: die Menüleisten-App (AppKit, Hotkey, Zwischenablage, Texterkennung)
- `Tests/ClippboardCoreTests`: Tests für den Kern (Swift Testing)

Voraussetzung: Xcode oder die Command Line Tools mit Swift 6.

## Bauen & installieren

```bash
./build.sh test
```

```bash
./build.sh install
```

`test` führt die Tests aus. `install` baut `build/Clippboard.app` als Universal Binary (Apple Silicon und Intel), kopiert sie nach `~/Applications` und startet sie. Beim ersten Start:

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

## Datenschutz & Sicherheit

- Einträge, die Passwort-Manager als vertraulich markieren (`org.nspasteboard.ConcealedType` und ähnliche), werden nie gespeichert. Ebenso nichts aus den Apps unter „Ignorierte Apps“.
- **Grenze:** Clippboard sieht nur, welche App gerade vorne ist, nicht, wer kopiert hat. Kopiert eine Browser-Erweiterung (z. B. Bitwarden in Chrome) ein Passwort, ohne es als vertraulich zu markieren, landet es in der Historie. Solche Einträge mit ⌘⌫ löschen.
- Alle Daten bleiben lokal: Ordner nur für dich lesbar (0700), Dateien 0600. Gelöschte Einträge werden in der Datenbank überschrieben, „Historie löschen“ baut die Datei neu auf.
- Das Fenster ist bei Bildschirmfreigabe, Aufnahmen und Screenshots nicht zu sehen.
- Texte über 2 MB und Bilder über 50 Megapixel werden nicht aufgezeichnet.
- Die App läuft mit Hardened Runtime, damit kein anderes Programm Code in sie einschleusen und ihre Bedienungshilfen-Berechtigung missbrauchen kann.

## Daten

- `history.sqlite`: Einträge
- `images/`: Bilder als PNG
