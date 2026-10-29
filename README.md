# Clipsody

[![CI](https://github.com/tillackt/clipsody/actions/workflows/ci.yml/badge.svg)](https://github.com/tillackt/clipsody/actions/workflows/ci.yml)

Lean clipboard history for macOS. A native Swift/AppKit app without dependencies, built as a replacement for Alfred's clipboard feature.

## Usage

| Key | Action |
|---|---|
| ⌥⌘C | Open/close the history |
| Type | Filter (several words must all match; also searches app names and text in images) |
| ↑ / ↓, Page ↑/↓ | Select an entry |
| ⏎ or double-click | Paste into the active app, with formatting (bold, links, tables from Word, Outlook, the browser …) |
| ⌥⏎ | Paste plain text only, without formatting |
| ⌘1 … ⌘9 | Paste the n-th entry directly |
| ⌘P | Pin/unpin an entry: it stays on top and is never deleted automatically |
| ⌘⌫ | Delete an entry |
| Esc | Close |

On the right is a preview (full text or image), below it the app, age and size. Search terms are highlighted in the list and the preview.

- **Images** are stored losslessly as PNG. Their text is read locally with macOS text recognition (Vision), so screenshots can be found by their content.
- **Files** from the Finder are pasted back as files, not as paths. If a file has been moved or deleted since, the app beeps.

## Project

A Swift package with these targets:

- `Sources/ClipsodyCore`: storage (SQLite with versioned migrations), configuration, image limits and hashes, search; no AppKit
- `Sources/Clipsody`: the menu bar app (AppKit, hotkey, pasteboard, pasting)
- `Sources/ClipsodyDecoder`: a sandboxed XPC service that converts clipboard images and recognises text in screenshots
- `Sources/ClipsodyXPC`: the interface between app and service
- `Sources/ClipsodyDecoderKit`: image conversion (ImageIO), text recognition (Vision) and the service's decoder object. Only the service and the tests link it; the app does not, so it cannot decode image formats itself
- `Sources/ClipsodyServices`: the XPC client and the queues for images and text recognition; no AppKit
- `Tests/ClipsodyServicesTests`: tests for those, including real XPC calls through a test listener
- `Tests/ClipsodyCoreTests`: tests for the core and the image conversion (Swift Testing)

Requires Xcode with Swift 6. The Command Line Tools alone are not enough, because the translations are compiled with Xcode's `xcstringstool`.

## Build & install

```bash
./build.sh test
```

```bash
./build.sh install
```

`test` runs the tests. `install` builds `build/Clipsody.app` as a universal binary (Apple Silicon and Intel), copies it to `/Applications` and starts it. On first launch:

1. Allow **Accessibility** (System Settings → Privacy & Security → Accessibility → Clipsody). Without it, the entry is only put on the clipboard, not pasted. With an ad-hoc signature the permission must be granted again after every rebuild: remove the entry and add it again.
2. Menu bar icon → **Settings…** → **General** → turn on launch at login.
3. In Alfred, turn off the clipboard hotkey or quit Alfred; otherwise both react to ⌥⌘C.

### Keep the permission across rebuilds (once)

Without a certificate of its own, `build.sh` signs ad hoc, and macOS forgets the Accessibility permission with every rebuild. To avoid that:

1. Open Keychain Access → menu **Keychain Access → Certificate Assistant → Create a Certificate…**
2. Name: `Clippboard Signing`, Identity Type: **Self-Signed Root**, Certificate Type: **Code Signing** → Create. (The name predates the rename to Clipsody and is kept, so the certificate's fingerprint stays the same.)
3. Run `./build.sh install` and grant the permission one last time.

`build.sh` uses the certificate automatically once it exists.

### Release

```bash
./build.sh release
```

Needs the certificate and a clean working tree. Runs the tests and builds `build/Clipsody.dmg`, plus `build/release-notes.txt` with the SHA-256 of the DMG and the fingerprint of the signing certificate.

## CI

GitHub Actions (`.github/workflows/ci.yml`) runs on every push to `main` and on every pull request:

- **Secret scan:** [Betterleaks](https://github.com/betterleaks/betterleaks) (the successor of gitleaks) scans the whole git history. Known false positives are listed in `.betterleaksignore`.
- **Lint:** [SwiftLint](https://github.com/realm/SwiftLint) with `--strict` (configuration in `.swiftlint.yml`), [ShellCheck](https://www.shellcheck.net) for the shell scripts and [actionlint](https://github.com/rhysd/actionlint) for the workflows.
- **Tests:** `./build.sh test`
- **Translations:** `./build.sh check-strings` fails if the code uses a text the catalog lacks, or the catalog keeps texts the code no longer uses.
- **App build:** `./build.sh` builds the universal binary; without the certificate it is signed ad hoc, and the signature is still verified.

Lint and secret scan run on Linux; tests and build on macOS with the newest stable Xcode.

**Website:** `.github/workflows/website.yml` validates the HTML (html-validate) and checks links and anchors (lychee) whenever `website/` changes, and weekly for external links.

The workflows pin their actions to commit SHAs, and Dependabot (`.github/dependabot.yml`) proposes updates weekly. `main` is protected: changes arrive only through pull requests with green CI, and force pushes are blocked. GitHub's own secret scanning with push protection rejects pushes that contain known credential formats, as a second line of defence behind the pre-commit hook.

### Pre-commit hook

A secret should never reach a commit, so a hook checks the staged changes before every commit (and runs SwiftLint when Swift files changed). Enable it once per clone:

```bash
brew install betterleaks swiftlint
git config core.hooksPath .githooks
```

If the scanner reports a false positive, mark the line with a `betterleaks:allow` comment and say why next to it.

New features are developed on a branch of their own and reach `main` through a pull request once CI is green. Everything in this repository (code, comments, docs, commits, pull requests) is in English.

## Languages

The app speaks English (the source language), German, French, Spanish, Italian, Dutch, Polish and Brazilian Portuguese, and follows the system language. Another one can be chosen under **General → Language** in the settings; the app then offers to restart. The choice is stored where macOS keeps the per-app language (System Settings → General → Language & Region → Applications), so both show the same.

All texts and translations live in `Resources/Localizable.xcstrings`. Texts in the code are written in English with `String(localized:)`. After adding or changing texts:

```bash
./build.sh strings
```

This adds new texts to the catalog; then add the translations (in Xcode or directly in the JSON file). A test checks that every language has every text with the same placeholders.

## Settings

Menu bar icon → **Settings…** (⌘,), split into the tabs **General**, **History**, **Privacy** and **Info**. Every option is explained there, and changes apply immediately. They are stored in `~/Library/Application Support/Clipsody/config.json`:

| Key | Default | Meaning |
|---|---|---|
| `hotkey` | `cmd+option+c` | Modifiers `cmd`, `option`, `ctrl`, `shift` + letter/digit/`space` |
| `retentionDays` | `7` | Entries older than n days are deleted |
| `maxItems` | `1000` | Maximum number of entries |
| `keepImages` | `true` | Save images |
| `ignoredApps` | password managers | Bundle IDs from which nothing is saved |

## Privacy & security

- Entries that password managers mark as concealed (`org.nspasteboard.ConcealedType` and similar) are never saved. Neither is anything from the apps under **Privacy → Ignored apps**.
- **Limit:** Clipsody only sees which app is in front, not who copied. If a browser extension (e.g. Bitwarden in Chrome) copies a password without marking it as concealed, it ends up in the history. Delete such entries with ⌘⌫.
- All data stays local: the folder is readable only by you (0700), files are 0600. The folder is excluded from Time Machine and other backups.
- Deleted entries are overwritten with zeros in the database, and its change log (WAL) is emptied: immediately for "Clear History" and the automatic clean-up, for single entries (⌘⌫) in one go when the window closes or the app quits, and after a crash at the next launch. The limit: what the file system still keeps physically on the SSD is outside an app's control.
- The window is hidden from screenshots and classic screen sharing. Since macOS 15, recording apps that use ScreenCaptureKit can still capture it.
- Texts over 2 MB and images over 50 megapixels are not recorded.
- The app runs with the hardened runtime, so no other program can inject code into it and abuse its Accessibility permission.
- Clipboard images are untrusted data. They are therefore not decoded in the app but in the helper process `ClipsodyDecoder` (embedded in the app). It runs in an app sandbox without further entitlements: no access to files outside its container, no network, no history. It only gets the bytes and returns a re-encoded PNG, the recognised text, preview images (as raw pixels) and, when pasting, the TIFF. The app itself decodes no image formats, so a vulnerability in image decoding hits this isolated process instead of the app.
- The app does not trust the service's replies either: it computes the file name (hash) itself and checks the whole PNG structure without decoding pixels: signature, checksum (CRC) of every chunk, only known chunk types, dimensions as reported, nothing after the end. Appended foreign data is thus neither stored nor pasted. It also limits text and checks the size and aspect ratio of preview images.
- Which service the app accepts depends on the signature. With a certificate (see above): only a service with the same identifier and the same certificate. Signed ad hoc there is no certificate, and any ad-hoc signed program can carry the identifier. The app therefore also checks its own seal including the embedded service at launch; a replaced service shows up there. If it is replaced while the app is running, that shows at the next launch. If the app cannot read its own signature or the seal does not verify, it talks to no service and processes no images. If the service cannot be reached, no images are stored either.

## Distribution

Whoever passes the app on publishes, next to the download, the SHA-256 checksum of the release file (`shasum -a 256 Clipsody.dmg`) and the SHA-256 fingerprint of the signing certificate (`codesign -d --extract-certificates Clipsody.app && shasum -a 256 codesign0`). That way recipients can recognise a re-signed or modified copy.

## Data

Until the end of October 2026 the app was called **Clippboard**. At first launch Clipsody takes over the old data folder with the history and the chosen language; the Accessibility permission must be granted again, because the bundle ID changed.

Everything is in `~/Library/Application Support/Clipsody/` (Settings → **Info** → **Show in Finder**):

- `history.sqlite`: the entries
- `images/`: images as PNG, plus scaled-down previews
- `config.json`: the settings

## Uninstall

Settings → **Info** → **Uninstall Clipsody…**. This deletes the history, images, `config.json`, the app's preferences, caches and saved window state, removes launch at login and the Accessibility permission, and moves the app to the Trash. If you only drag the app to the Trash yourself, this data stays behind: macOS does not tell an app that it is being deleted.

Only the empty shell of the image helper's sandbox folder remains (`~/Library/Containers/io.github.tillackt.clipsody.decoder`, a macOS management file, no user data). Since macOS 14 only the system may delete containers; in the Finder it can be moved to the Trash after confirming. If more than that remains there, the app reports it.

## License

GNU General Public License v3.0, see [LICENSE](LICENSE). Anyone who modifies and distributes Clipsody must publish the source code of their version under the GPLv3 as well.
