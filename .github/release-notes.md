{{CHANGES}}

## Requirements

macOS 13 Ventura or later, Apple Silicon or Intel.

## Install or update

Clipsody is free and therefore not notarised by Apple; macOS asks once on first launch.

1. Download `Clipsody.dmg`, open it and drag Clipsody into Applications (replace the old version when updating).
2. Launch Clipsody.
   - macOS 15 and later: click **Done** in the warning, then open System Settings → Privacy & Security and choose **Open Anyway**.
   - macOS 13 and 14: right-click Clipsody in Applications → **Open** → **Open**.
3. For ⏎ to paste directly, allow Clipsody under System Settings → Privacy & Security → **Accessibility**.
4. Press ⌥⌘C.

## Verify your download

Only download Clipsody from this page. Check the disk image and the certificate the app is signed with:

```
shasum -a 256 ~/Downloads/Clipsody.dmg
codesign -d --extract-certificates=/tmp/clipsody-cert /Applications/Clipsody.app && shasum -a 256 /tmp/clipsody-cert0
```

| | SHA-256 |
|---|---|
| `Clipsody.dmg` | `{{DMG_SHA}}` |
| Signing certificate | `{{CERT_SHA}}` |

Every release is signed with the same certificate, so granted permissions survive updates. A different certificate fingerprint means the copy is not genuine.

Version {{VERSION}}, build {{BUILD}}, commit {{COMMIT}}. Security issues: please report privately, see [SECURITY.md](https://github.com/tillackt/clipsody/blob/main/SECURITY.md).
