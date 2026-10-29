# Security policy

Clipsody sees everything you copy, so security problems matter. Thank you for reporting them responsibly.

## Reporting a vulnerability

Please **do not open a public issue**. Report privately through GitHub instead:
[Security → Report a vulnerability](https://github.com/tillackt/clipsody/security/advisories/new).

Helpful in a report:

- the Clipsody version and build (Settings → Info → Version) and the macOS version,
- what an attacker can do and under which conditions,
- steps or a small proof of concept to reproduce it.

Clipsody is maintained by one person in their spare time. You will usually get a first answer within a week. Once a fix is released, the advisory is published, crediting you if you like.

## Supported versions

Only the latest release receives security fixes.

## Scope

In scope, for example:

- secrets or clipboard contents leaving the Mac, or reaching other users or processes,
- content marked as concealed (password managers) or from ignored apps ending up in the history,
- deleted entries remaining recoverable from the database files,
- the image decoder service escaping its sandbox, or the app trusting data it should not,
- code injection into the app, which holds the Accessibility permission,
- the build and release process (CI, signing, the published checksums).

Out of scope:

- attacks that already require full control of the user account or an unlocked Mac,
- copies made by other apps or by macOS itself (e.g. Universal Clipboard),
- the limits described in the README under "Privacy & security".

## Safeguards in this repository

- Secret scanning with push protection on GitHub, and a pre-commit hook with Betterleaks (see the README).
- CodeQL and SwiftLint on every pull request; actions in the workflows are pinned to commits.
