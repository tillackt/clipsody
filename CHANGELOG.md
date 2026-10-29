# Changelog

All notable changes, newest first. Versions follow [Semantic Versioning](https://semver.org) (see the README, "Versioning"). `./build.sh release` takes the section of the version it builds into the release notes, so every release needs one.

## 1.1.0 – 2026-10-30

- **Ready for clipboard privacy in macOS 27.** Newer versions of macOS ask before an app reads what you copy in other apps. Settings → General now shows whether Clipsody may (Allowed, Asks when needed, Denied) and explains how to allow it. While access is denied, the menu bar menu says so instead of the history silently standing still.
- **Check your copy more thoroughly:** the website and the release notes now show how to check the signing certificate's fingerprint, the check a re-signed copy cannot fake.
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
