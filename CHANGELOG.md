# Changelog

All notable changes, newest first. Versions follow [Semantic Versioning](https://semver.org) (see the README, "Versioning"). `./build.sh release` takes the section of the version it builds into the release notes, so every release needs one.

## 1.4.0 – 2026-11-01

- **Clipsody updates itself.** When a new version is available, "Install and Restart" downloads it from GitHub, checks that it carries the Clipsody signature (the same certificate as every release) and is exactly the announced, newer version, replaces the app and restarts. Your history, settings and permissions stay. If any check fails, nothing changes; if Clipsody cannot write its folder, it points to the release page. Nothing is downloaded unless you click Install.
- **This update is the last one by hand:** quit Clipsody first (menu bar icon → Quit), then drag the new version to Applications and replace the old one.
- **A real app icon,** and a disk image that shows where to drag Clipsody.

## 1.3.0 – 2026-11-01

- **Pinned entries get their own list.** Text snippets, addresses or commands you pin with ⌘P no longer crowd the history. Two tabs under the search field, History and Pinned, switch with → at the end of the search text and ← at its start, or with ⇥. ⌘1–⌘9 paste from the list shown, and the latest pin comes first.
- **Pinned entries you use show up in the history too.** Copy or paste a pinned entry and it also appears in the history at that moment, marked with a pin; in the history, ⌘⌫ only takes it out of the history.
- **The search tells you where the hits are:** with nothing found in the list shown but matches in the other one, the panel says how many and which arrow leads there.
- Entries pinned before keep their pin and stay out of the history.

## 1.2.0 – 2026-10-30

- **Find out about new versions – only if you want to.** At the first launch Clipsody asks whether it may check for updates automatically; the default is no. If you agree, it asks GitHub once a day for the latest version number. Nothing from your clipboard is sent; GitHub sees your IP address and the Clipsody version. A new version puts a dot on the menu bar icon and adds a menu item that opens the release page; Clipsody downloads and installs nothing itself.
- **Check for Updates… at any time,** in the menu bar menu or under Settings → General, also with automatic checks turned off.
- Without your consent, Clipsody still uses no network at all.

## 1.1.0 – 2026-10-30

- **Ready for clipboard privacy in macOS 27.** Newer versions of macOS ask before an app reads what you copy in other apps. Settings → General now shows whether Clipsody may (Allowed, Asks when needed, Denied) and explains how to allow it. While access is denied, the menu bar menu says so instead of the history silently standing still.
- **Check your copy more thoroughly:** the website and the release notes now show how to check the signing certificate's fingerprint, the check a re-signed copy cannot fake.
- **Text in screenshots is found again on macOS 27.** macOS 27 broke the text recognition Clipsody used; it now uses Apple's newer interface and, where the precise model is unavailable, a faster one.
- Tested on macOS 27 with Xcode 27 in addition to macOS 26.
- Behind the scenes: stricter release checks (pinned signing certificate, version and changelog checks, verified upload), sturdier tests, tidier code.

## 1.0.0 – 2026-10-29

The first release of Clipsody: a lean, private clipboard history for the Mac.

- **⌥⌘C from any app:** type to filter, ↑↓ to choose, ⏎ to paste where you were typing. ⌘1–⌘9 paste directly.
- **Text, images and files.** Images are kept lossless; screenshots are searchable by the text in them (on-device text recognition).
- **With or without formatting:** ⏎ keeps bold, links and tables; ⌥⏎ pastes plain text.
- **Pin** what you use often (⌘P); it stays on top and is never deleted automatically.
- **Private by design:** no network, no account, no tracking. Concealed content from password managers is never saved, and known password managers are ignored. Deleted entries are overwritten on disk. Untrusted image data is decoded in a sandboxed helper process.
- **8 languages:** English, German, French, Spanish, Italian, Dutch, Polish and Brazilian Portuguese, switchable in the settings.
- **Clean uninstall** from Settings → Info.
