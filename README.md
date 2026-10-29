# Clipsody

[![CI](https://github.com/tillackt/clipsody/actions/workflows/ci.yml/badge.svg)](https://github.com/tillackt/clipsody/actions/workflows/ci.yml)

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

- `Sources/ClipsodyCore`: Speicher (SQLite mit versionierten Migrationen), Konfiguration, Bildgrenzen und Hashes, Suche, ohne AppKit
- `Sources/Clipsody`: die Menüleisten-App (AppKit, Hotkey, Zwischenablage, Einfügen)
- `Sources/ClipsodyDecoder`: XPC-Dienst in einer Sandbox, der Bilder aus der Zwischenablage umwandelt und Text in Screenshots erkennt
- `Sources/ClipsodyXPC`: die Schnittstelle zwischen App und Dienst
- `Sources/ClipsodyDecoderKit`: Bildumwandlung (ImageIO), Texterkennung (Vision) und das Dekoder-Objekt des Dienstes. Nur der Dienst und die Tests linken es; die App linkt es nicht und kann Bildformate daher gar nicht selbst dekodieren
- `Sources/ClipsodyServices`: XPC-Client und die Warteschlangen für Bilder und Texterkennung, ohne AppKit
- `Tests/ClipsodyServicesTests`: Tests dafür, inklusive echter XPC-Aufrufe über einen Test-Listener
- `Tests/ClipsodyCoreTests`: Tests für den Kern und die Bildumwandlung (Swift Testing)

Voraussetzung: Xcode mit Swift 6 (die Command Line Tools allein reichen nicht, weil die Übersetzungen mit `xcstringstool` aus Xcode kompiliert werden).

## Bauen & installieren

```bash
./build.sh test
```

```bash
./build.sh install
```

`test` führt die Tests aus. `install` baut `build/Clipsody.app` als Universal Binary (Apple Silicon und Intel), kopiert sie nach `/Applications` (Programme) und startet sie. Beim ersten Start:

1. **Bedienungshilfen** erlauben (Systemeinstellungen → Datenschutz & Sicherheit → Bedienungshilfen → Clipsody). Ohne das wird der Eintrag nur in die Zwischenablage gelegt, nicht eingefügt. Nach jedem Neubau muss die Berechtigung neu gesetzt werden (Ad-hoc-Signatur): Eintrag entfernen und wieder hinzufügen.
2. Menüleisten-Icon → **Einstellungen …** → **Allgemein** → Autostart einschalten.
3. In Alfred den Clipboard-Hotkey abschalten oder Alfred beenden, sonst reagieren beide auf ⌥⌘C.

### Berechtigung über Neubauten hinweg behalten (einmalig)

Ohne eigenes Zertifikat signiert `build.sh` ad hoc, und macOS vergisst die Bedienungshilfen-Berechtigung bei jedem Neubau. Abhilfe:

1. Schlüsselbundverwaltung öffnen → Menü **Schlüsselbundverwaltung → Zertifikatsassistent → Zertifikat erstellen …**
2. Name: `Clippboard Signing`, Identitätstyp: **Selbstsignierter Root**, Zertifikatstyp: **Codesignierung** → Erstellen.
3. `./build.sh install` ausführen und die Berechtigung ein letztes Mal setzen.

`build.sh` nimmt das Zertifikat automatisch, sobald es vorhanden ist.

## CI

GitHub Actions (`.github/workflows/ci.yml`) läuft bei jedem Push auf `main` und bei jedem Pull Request, auf einem macOS-Runner mit dem neuesten stabilen Xcode:

- **Tests:** `./build.sh test`
- **Übersetzungen:** `./build.sh check-strings` schlägt fehl, wenn ein Text im Code nicht im Katalog steht oder der Katalog Texte enthält, die der Code nicht mehr nutzt.
- **App-Build:** `./build.sh` baut das Universal Binary; ohne Zertifikat ad hoc signiert, die Signatur wird trotzdem geprüft.

Neue Funktionen entstehen auf einem eigenen Branch und kommen per Pull Request nach `main`, nachdem die CI grün ist.

## Sprachen

Die App spricht Englisch (Ausgangssprache), Deutsch, Französisch, Spanisch, Italienisch, Niederländisch, Polnisch und Portugiesisch (Brasilien) und folgt der Systemsprache. In den Einstellungen unter **Allgemein → Sprache** lässt sich eine andere wählen; die App bietet dann an, sich neu zu starten. Die Wahl landet dort, wo auch macOS die Sprache pro App speichert (Systemeinstellungen → Allgemein → Sprache & Region → Programme), beide Wege zeigen also dasselbe.

Alle Texte und Übersetzungen stehen in `Resources/Localizable.xcstrings`. Texte im Code werden mit `String(localized:)` geschrieben, auf Englisch. Nach neuen oder geänderten Texten:

```bash
./build.sh strings
```

Das trägt neue Texte in den Katalog ein; danach die Übersetzungen ergänzen (in Xcode oder direkt in der JSON-Datei). Ein Test prüft, dass jede Sprache jeden Text mit denselben Platzhaltern hat.

## Einstellungen

Menüleisten-Icon → **Einstellungen …** (⌘,), aufgeteilt in die Tabs **Allgemein**, **Historie**, **Datenschutz** und **Info**. Jede Option ist dort erklärt, Änderungen gelten sofort. Gespeichert wird in `~/Library/Application Support/Clipsody/config.json`:

| Schlüssel | Standard | Bedeutung |
|---|---|---|
| `hotkey` | `cmd+option+c` | Modifier `cmd`, `option`, `ctrl`, `shift` + Buchstabe/Ziffer/`space` |
| `retentionDays` | `7` | Einträge älter als n Tage werden gelöscht |
| `maxItems` | `1000` | Maximale Anzahl Einträge |
| `keepImages` | `true` | Bilder speichern |
| `ignoredApps` | Passwort-Manager | Bundle-IDs, aus denen nichts gespeichert wird |

## Datenschutz & Sicherheit

- Einträge, die Passwort-Manager als vertraulich markieren (`org.nspasteboard.ConcealedType` und ähnliche), werden nie gespeichert. Ebenso nichts aus den Apps unter **Datenschutz → Ignorierte Apps**.
- **Grenze:** Clipsody sieht nur, welche App gerade vorne ist, nicht, wer kopiert hat. Kopiert eine Browser-Erweiterung (z. B. Bitwarden in Chrome) ein Passwort, ohne es als vertraulich zu markieren, landet es in der Historie. Solche Einträge mit ⌘⌫ löschen.
- Alle Daten bleiben lokal: Ordner nur für dich lesbar (0700), Dateien 0600. Der Ordner ist von Time Machine und anderen Backups ausgeschlossen.
- Gelöschte Einträge werden in der Datenbank mit Nullen überschrieben, und das Änderungsprotokoll (WAL) wird geleert: bei „Historie löschen“ und beim Aufräumen sofort, bei einzelnen Einträgen (⌘⌫) gesammelt beim Schließen des Fensters bzw. beim Beenden, nach einem Absturz beim nächsten Start. Die Grenze: Was das Dateisystem auf SSD-Ebene noch physisch vorhält, liegt außerhalb der Kontrolle einer App.
- Das Fenster ist bei Screenshots und klassischer Bildschirmfreigabe ausgeblendet. Ab macOS 15 können Aufnahme-Apps, die ScreenCaptureKit nutzen, es trotzdem erfassen.
- Texte über 2 MB und Bilder über 50 Megapixel werden nicht aufgezeichnet.
- Die App läuft mit Hardened Runtime, damit kein anderes Programm Code in sie einschleusen und ihre Bedienungshilfen-Berechtigung missbrauchen kann.
- Bilder aus der Zwischenablage sind fremde Daten. Sie werden deshalb nicht in der App dekodiert, sondern im Hilfsprozess `ClipsodyDecoder` (eingebettet in der App). Er läuft in einer App-Sandbox ohne weitere Rechte: kein Zugriff auf Dateien außerhalb seines Containers, kein Netzwerk, keine Historie. Er bekommt nur die Bytes und liefert ein neu kodiertes PNG, den erkannten Text, Vorschaubilder (als rohe Pixel) und beim Einfügen das TIFF zurück. Die App selbst dekodiert keine Bildformate. Eine Schwachstelle in der Bilddekodierung trifft damit diesen abgeschotteten Prozess statt der App.
- Auch den Antworten des Dienstes traut die App nicht: Sie berechnet den Dateinamen (Hash) selbst und prüft die ganze PNG-Struktur, ohne Pixel zu dekodieren: Signatur, Prüfsumme (CRC) jedes Abschnitts, nur bekannte Abschnittstypen, Maße wie gemeldet, nichts hinter dem Ende. Angehängte Fremddaten werden so weder gespeichert noch eingefügt. Außerdem begrenzt sie Text und prüft Länge und Seitenverhältnis von Vorschaubildern.
- Welchen Dienst die App akzeptiert, hängt von der Signatur ab. Mit Zertifikat (siehe oben): nur einen Dienst mit derselben Kennung und demselben Zertifikat. Ad hoc signiert gibt es kein Zertifikat, und die Kennung allein kann jedes ad hoc signierte Programm tragen. Deshalb prüft die App beim Start zusätzlich ihr eigenes Siegel samt eingebettetem Dienst; ein ausgetauschter Dienst fällt dabei auf. Wird er ausgetauscht, während die App läuft, fällt das erst beim nächsten Start auf. Kann die App ihre eigene Signatur nicht lesen oder stimmt das Siegel nicht, spricht sie mit keinem Dienst und verarbeitet keine Bilder. Ist der Dienst nicht erreichbar, werden ebenfalls keine Bilder gespeichert.

## Weitergabe

Wer die App weitergibt, veröffentlicht neben dem Download die SHA-256-Prüfsumme des Release-Archivs (`shasum -a 256 Clipsody.dmg`) und den SHA-256-Fingerabdruck des Signaturzertifikats (`codesign -d --extract-certificates Clipsody.app && shasum -a 256 codesign0`). So erkennen Empfänger eine neu signierte oder veränderte Kopie.

## Daten

Die App hieß bis Ende Oktober 2026 **Clippboard**. Beim ersten Start übernimmt Clipsody den alten Datenordner samt Historie und die gewählte Sprache; die Bedienungshilfen-Berechtigung muss neu erteilt werden, weil sich die Bundle-ID geändert hat.

Alles liegt in `~/Library/Application Support/Clipsody/` (Einstellungen → **Info** → **Im Finder zeigen**):

- `history.sqlite`: Einträge
- `images/`: Bilder als PNG, dazu verkleinerte Vorschauen
- `config.json`: Einstellungen

## Deinstallieren

Einstellungen → **Info** → **Clipsody deinstallieren …**. Das löscht Historie, Bilder, `config.json`, die Einstellungen der App sowie Caches und gespeicherten Fensterzustand, entfernt Autostart und die Berechtigung „Bedienungshilfen“ und legt die App in den Papierkorb. Zieht man die App nur selbst in den Papierkorb, bleiben diese Daten liegen: macOS sagt einer App nicht, dass sie gelöscht wird.

Übrig bleibt nur die leere Hülle des Sandbox-Ordners des Bild-Hilfsprozesses (`~/Library/Containers/io.github.tillackt.clipsody.decoder`, eine Verwaltungsdatei von macOS, keine Nutzerdaten). Seit macOS 14 darf nur das System Container löschen; im Finder lässt sie sich mit Bestätigung in den Papierkorb legen. Bleibt dort mehr zurück, zeigt die App es an.

## Lizenz

GNU General Public License v3.0, siehe [LICENSE](LICENSE). Wer Clipsody verändert und weitergibt, muss den Quellcode seiner Version ebenfalls unter der GPLv3 offenlegen.
