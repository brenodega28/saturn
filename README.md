# Ensemble

A macOS app that runs a crew of Claude Code agents on a project, each in its own git worktree. See [docs/ROADMAP.md](docs/ROADMAP.md).

## Requirements

- macOS 26, Xcode 26 or later
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`
- `git` and the `claude` CLI on the machine running the app

## Develop

```sh
xcodegen generate
open Ensemble.xcodeproj
```

`project.yml` is the source of truth; `Ensemble.xcodeproj` is generated and git-ignored. Re-run `xcodegen generate` after adding or removing files.

Engine tests run without Xcode:

```sh
swift test --package-path Packages/EnsembleCore
```

## Layout

```
Ensemble/              macOS app target (SwiftUI)
Packages/EnsembleCore  UI-free engine: storage, git, worktrees, environment checks, Keychain
Packages/EnsembleUI    shared SwiftUI components and theme
Configs/               build settings (copy Local.xcconfig.example to Local.xcconfig for Sparkle keys)
scripts/release.sh     Developer ID archive, notarization, DMG and Sparkle appcast
```

The **Debug** menu has a Worktrees window for creating and removing worktrees under `.crew/`.

## Releases

`scripts/release.sh` (run by `.github/workflows/release.yml` on `v*` tags) needs a Developer ID Application certificate and these values:

| Name | Kind | Purpose |
| --- | --- | --- |
| `DEVELOPER_ID_P12_BASE64`, `DEVELOPER_ID_P12_PASSWORD` | secret | Developer ID Application certificate |
| `NOTARY_APPLE_ID`, `NOTARY_TEAM_ID`, `NOTARY_PASSWORD` | secret | `notarytool` credentials (app-specific password) |
| `SPARKLE_PRIVATE_KEY` | secret | EdDSA private key from Sparkle's `generate_keys` |
| `SPARKLE_PUBLIC_ED_KEY`, `SPARKLE_FEED_URL`, `SPARKLE_DOWNLOAD_URL_PREFIX` | variable | Public key, appcast URL, and where DMGs are hosted |

The in-app updater stays off until a build has an `https` feed URL and a public key.
