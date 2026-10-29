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

Swift-Paket mit diesen Zielen:

- `Sources/ClippboardCore`: Speicher (SQLite mit versionierten Migrationen), Konfiguration, Bildumwandlung, Suche, ohne AppKit
- `Sources/Clippboard`: die Menüleisten-App (AppKit, Hotkey, Zwischenablage, Einfügen)
- `Sources/ClippboardDecoder`: XPC-Dienst in einer Sandbox, der Bilder aus der Zwischenablage umwandelt und Text in Screenshots erkennt
- `Sources/ClippboardXPC`: die Schnittstelle zwischen App und Dienst
- `Sources/ClippboardServices`: Dekoder, XPC-Client und die Warteschlangen für Bilder und Texterkennung, ohne AppKit
- `Tests/ClippboardServicesTests`: Tests dafür, inklusive echter XPC-Aufrufe über einen Test-Listener
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
- Alle Daten bleiben lokal: Ordner nur für dich lesbar (0700), Dateien 0600. Der Ordner ist von Time Machine und anderen Backups ausgeschlossen.
- Gelöschte Einträge (⌘⌫, Aufräumen, „Historie löschen“) werden in der Datenbank mit Nullen überschrieben, und das Änderungsprotokoll (WAL) wird danach geleert. Die Grenze: Was das Dateisystem auf SSD-Ebene noch physisch vorhält, liegt außerhalb der Kontrolle einer App.
- Das Fenster ist bei Screenshots und klassischer Bildschirmfreigabe ausgeblendet. Ab macOS 15 können Aufnahme-Apps, die ScreenCaptureKit nutzen, es trotzdem erfassen.
- Texte über 2 MB und Bilder über 50 Megapixel werden nicht aufgezeichnet.
- Die App läuft mit Hardened Runtime, damit kein anderes Programm Code in sie einschleusen und ihre Bedienungshilfen-Berechtigung missbrauchen kann.
- Bilder aus der Zwischenablage sind fremde Daten. Sie werden deshalb nicht in der App dekodiert, sondern im Hilfsprozess `ClippboardDecoder` (eingebettet in der App). Er läuft in einer App-Sandbox ohne weitere Rechte: kein Zugriff auf Dateien außerhalb seines Containers, kein Netzwerk, keine Historie. Er bekommt nur die Bytes und liefert ein neu kodiertes PNG bzw. den erkannten Text zurück. Eine Schwachstelle in der Bilddekodierung trifft damit diesen abgeschotteten Prozess statt der App. Ist der Dienst nicht erreichbar, werden keine Bilder gespeichert.

## Daten

- `history.sqlite`: Einträge
- `images/`: Bilder als PNG
