# Changelog

All notable changes, newest first. Versions follow [Semantic Versioning](https://semver.org) (see the README, "Versioning"). `./build.sh release` takes the section of the version it builds into the release notes, so every release needs one.

## 1.0.0 – 2026-10-29

The first release of Clipsody: a lean, private clipboard history for the Mac.

- **⌥⌘C from any app:** type to filter, ↑↓ to choose, ⏎ to paste where you were typing. ⌘1–⌘9 paste directly.
- **Text, images and files.** Images are kept lossless; screenshots are searchable by the text in them (on-device text recognition).
- **With or without formatting:** ⏎ keeps bold, links and tables; ⌥⏎ pastes plain text.
- **Pin** what you use often (⌘P); it stays on top and is never deleted automatically.
- **Private by design:** no network, no account, no tracking. Concealed content from password managers is never saved, and known password managers are ignored. Deleted entries are overwritten on disk. Untrusted image data is decoded in a sandboxed helper process.
- **8 languages:** English, German, French, Spanish, Italian, Dutch, Polish and Brazilian Portuguese, switchable in the settings.
- **Clean uninstall** from Settings → Info.
