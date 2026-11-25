---
title: "Saturn rebrand: name, icon, Eclipse Blue colours, SF type"
status: in-progress
version: 1
workers:
  - {role: builder, name: Rebrand Dev, reason: "One builder: the rename moves almost every file, so splitting the theme/icon work from it would only create merge conflicts"}
  - {role: qa-engineer, name: QA, reason: "Checker with a fresh pair of eyes: builds, runs tests, exercises the upgrade migration and checks visuals against the token table"}
owner: ""
linked_runs: [17]
created: 2026-11-25
---

## Summary

Rebrand the app from Ensemble to Saturn using the Saturn design canvas (pages "Saturn · App icon" and "Saturn · Colour and type"). Everything gets the new name: what users see, code identifiers, and saved/wire identifiers. Existing installs migrate automatically on first launch. The app icon becomes the chosen "C · Eclipse" mark: a black planet with an ice-blue rim light and a thin blue ring, on a near-black rounded square. The colour tokens move to the Eclipse Blue scheme; only that scheme is built, since Corona, Deep Space and Graphite are marked "for later". The only fonts are SF Pro (system) and SF Mono (system .monospaced). The JetBrains Mono lookup and the one .rounded use are removed.

## Interfaces

- Names: Xcode target/scheme Ensemble → Saturn; folder Ensemble/ → Saturn/; Packages/EnsembleCore → Packages/SaturnCore; Packages/EnsembleUI → Packages/SaturnUI; product ensembled → saturnd; EnsembleApp/EnsembleHost/EnsembleMCPServer/EnsembleProtocol/EnsembleNotice etc. → Saturn*; Ensemble.entitlements/Info.plist paths updated in project.yml; CFBundleDisplayName Saturn
- Bundle IDs: dev.monoliti.Ensemble → dev.monoliti.Saturn; dev.monoliti.ensembled → dev.monoliti.saturnd (LaunchAgent plist renamed to dev.monoliti.saturnd.plist; old LaunchAgent unloaded/removed on migration)
- On-disk: per-project .ensemble/ → .saturn/ (this repo's own .ensemble/ moved to .saturn/ too); .ensemble-tmp → .saturn-tmp; ensemble.sqlite → saturn.sqlite; app-support/data dirs renamed; UserDefaults suite dev.monoliti.Ensemble.data-dir.* → dev.monoliti.Saturn.data-dir.*
- Wire: URL scheme ensemble:// → saturn:// (ensemble:// still registered and accepted as an alias so old links open); env vars ENSEMBLE_* → SATURN_* (ENSEMBLE_DATA_DIR still read as a fallback); MCP server name ensemble → saturn, so agent tools become mcp__saturn__*; every prompt/role/workflow text that names mcp__ensemble__* or Ensemble updated
- Migration (runs once at app launch, before the daemon starts, idempotent): copy old UserDefaults domain → new; copy Keychain items from old service/access group → new; move the data dir and ensemble.sqlite → saturn.sqlite; unload and delete the old ensembled LaunchAgent; for each known project, rename <repo>/.ensemble → <repo>/.saturn when .saturn does not exist yet, and update .gitignore entries; record completion with a flag. Never deletes old Keychain items or defaults (copy only)
- Tokens.swift: every token set to the Eclipse Blue dark/light values from the canvas (see verification table); Theme.accent → Tokens.accent (#8EC5FF dark / #0A84FF light)
- Tokens.mono(_:weight:) → always .system(size:weight:design: .monospaced); monoFamily removed; no Font.custom anywhere
- App icon: AppIcon.appiconset PNGs (16–1024) regenerated from the Eclipse SVG, plus a reusable SwiftUI SaturnMark view in SaturnUI for in-app logo spots (welcome/first run, About)

## Out of scope

- Colour schemes B Corona, C Deep Space, D Graphite (marked 'for later' on the canvas)
- Re-laying out screens to match the v5 artboards; only colours, fonts, name and icon change
- Renaming the GitHub repo, the local checkout folder, or release hosting URLs/Sparkle feed
- Changing the dev.monoliti bundle ID prefix

## Acceptance criteria

- [ ] `git grep -i ensemble` returns only the intentional legacy-compat hits: the migration code, the ensemble:// alias, the ENSEMBLE_DATA_DIR fallback, and the old LaunchAgent label used for cleanup
- [ ] `xcodegen generate` produces Saturn.xcodeproj; the Saturn scheme builds; the built app is Saturn.app with display name Saturn and embeds Helpers/saturnd
- [ ] `swift test --package-path Packages/SaturnCore` and the SaturnUI tests pass (TokensTests updated to the new values)
- [ ] Menus, About, window titles, notifications, Dock, alerts and onboarding copy all say Saturn
- [ ] Dock/Finder icon is the Eclipse mark at every size in the appiconset (16, 32, 128, 256, 512 @1x/@2x)
- [ ] Tokens.swift values match the Eclipse Blue table exactly for both dark and light
- [ ] No Font.custom / NSFont(name:) / JetBrains Mono / design: .rounded left; mono text uses SF Mono via design .monospaced
- [ ] Upgrade: with an existing Ensemble install, first launch of Saturn keeps projects, chats, settings and Keychain secrets. Projects' .ensemble/ folders become .saturn/. The old ensembled LaunchAgent is gone and saturnd runs. A second launch does nothing further
- [ ] Agents spawned by the app get the MCP server named saturn and their prompts reference mcp__saturn__* tools
- [ ] Old ensemble://chat/<id> links still open the chat

## Verification

Build: xcodegen generate, then build the Saturn scheme. Run both package test suites. Grep for leftover ensemble/JetBrains/.rounded/Font.custom. Migration: seed a temp data dir (via SATURN_DATA_DIR / legacy ENSEMBLE_DATA_DIR) with a fake ensemble.sqlite, an old defaults suite and a project with a .ensemble/ folder. Launch and check that everything moved, then relaunch and check nothing changed. Visual: open the app in dark and light and check the colours against the Eclipse Blue table (dark/light): desk #050506/#E8E8ED, win #000/#FFF, side #0A0A0C/#F5F5F7, raised #121216/#FFF, card #0E0E11/#FFF, menu #1A1B20/#FFF, bubble #1B1C21/#EFEFF2, code #0A0A0C/#F5F5F7, hair w.08/b.08, hair2 w.12/b.14, text #F5F5F7/#1D1D1F, text2 (EBEBF5,.62)/(3C3C43,.74), text3 (EBEBF5,.4)/(3C3C43,.5), sel (8EC5FF,.12)/b.06, hover w.05/b.035, fill w.06/b.05, fill2 w.12/b.10, tabOn (8EC5FF,.16)/#FFF, priBg #F5F5F7/#1D1D1F, priFg #0A0A0C/#FFF, link #8EC5FF/#0066CC, accent #8EC5FF/#0A84FF, need #FF9F5A/#C2410C, stuck #FF7B72/#C7000F, build #8EC5FF/#0058B8, review #F5D76E/#946200, done #5CD68A/#17803A, needBg (FF7A2F,.08)/(EA580C,.07), needLine (FF7A2F,.4)/(EA580C,.38), stuckBg (FF453A,.09)/(D70015,.06), stuckLine (FF453A,.4)/(D70015,.35), buildBg (8EC5FF,.12)/(0066CC,.08), reviewBg (F5D76E,.11)/(CA8A04,.10), doneBg (5CD68A,.12)/(17803A,.08), doneLine (5CD68A,.35)/(17803A,.30), danger #FF7B72/#C7000F, live #30D158/#28A745, scrim b.55/b.22, shadow b.70/b.16.
