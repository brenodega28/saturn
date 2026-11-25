---
title: SF-only type and Nebula status colours everywhere
status: in-progress
version: 1
workers:
  - {role: builder, name: Builder 1, reason: "One task: Swift tokens, spec page template and Lavish theme stylesheet share the same palette and are tested together"}
  - {role: checker, name: QA 1, reason: "Fresh-eyes check of colours, fonts and contrast in the app and Lavish"}
owner: ""
linked_runs: [18]
created: 2026-11-25
---

## Summary

Finish the Saturn brand pass from the design canvas (Saturn · Colour and type page). The Swift app already uses only SF Pro / SF Mono and Eclipse Blue surfaces; this change swaps every status colour to the chosen Nebula set, and brings the two web surfaces Saturn shows — its own spec page template and the vendored Lavish review chrome — onto SF Pro / SF Mono and the Eclipse Blue + Nebula palette. Lavish is themed through one Saturn-owned stylesheet that overrides chrome.css variables, so re-vendoring Lavish doesn't lose it. The Excalidraw whiteboard's drawing fonts stay untouched, since removing them breaks hand-drawn and CJK text in drawings.

## Interfaces

- Tokens (SaturnUI/Tokens.swift): need/stuck/build/review/done and their *Background/*Line variants move to Nebula; new Tokens.idle (Not started) = dark 0x8C9BB8; light shades derived per token
- Nebula dark values: need 0xFF7EB3, stuck 0xFF5C8A, build 0xA99BFF, review 0xC9A7FF, done 0x4FD1C5, idle 0x8C9BB8. Light values: darker shades of the same hue with ≥4.5:1 contrast on #FFFFFF
- Theme.neutral → Tokens.idle; Theme.info/warning/paused/successText keep pointing at the Nebula tokens
- Resources/Templates/spec-page/page.html: font stacks only -apple-system/BlinkMacSystemFont/'SF Pro Text'/'SF Pro Display' and 'SF Mono'/ui-monospace (no Segoe UI, Menlo, Consolas); palette = Eclipse Blue surfaces (dark #000000/#0A0A0C/#121216, text #F5F5F7, accent #8EC5FF; light from Tokens light values) and status badges from Nebula
- New Saturn-owned stylesheet for Lavish chrome (e.g. Resources/Lavish/saturn-theme.css) overriding --font-sans/--font-serif/--font-mono to SF Pro / SF Mono and the --bg*/--fg*/--border*/--accent*/--danger and status variables to Eclipse Blue + Nebula, applied to the served chrome in a way that survives re-vendoring (documented where Lavish is vendored)

## Out of scope

- Excalidraw whiteboard drawing fonts and their woff2 files (Assistant, Excalifont, Virgil, Comic Shanns, Liberation, Cascadia, Xiaolai)
- Corona, Deep Space and Graphite colour schemes (kept for later)
- RolePalette avatar gradients and Theme.memory
- Changes to the design canvas itself

## Acceptance criteria

- [ ] Every status colour in the app (sidebar groups, chat rows, worker roster, run timeline, cards, badges) shows the Nebula set in dark mode with the exact hexes above
- [ ] Light mode status colours are the derived Nebula shades and each passes 4.5:1 on white
- [ ] Building no longer shares the accent blue: Tokens.build ≠ Tokens.accent
- [ ] No hardcoded old status hexes (0xFF9F5A, 0xFF7B72, 0xF5D76E, 0x5CD68A and their light variants) remain in Swift sources outside the Nebula definitions
- [ ] grep for Segoe|Menlo|Consolas|Geist|Garamond|Georgia|Inter in Saturn-owned sources (Swift, spec-page template, Saturn stylesheet) returns nothing
- [ ] The spec review page in Lavish renders in SF Pro with SF Mono code, black Eclipse Blue surfaces, ice-blue accent, and Nebula status colours
- [ ] Whiteboard drawings in Lavish still render their hand-drawn fonts
- [ ] Existing tests pass (swift test for SaturnCore/SaturnUI, DesignParityTests updated if it pins token values) and the app builds

## Verification

Build the app and run the package tests. Open a chat in each status (needs you, stuck, building, in review, done, not started) in dark and light mode and compare against the Nebula set on the canvas. Open a spec review in Lavish and check fonts (Web Inspector computed font-family) and colours; open a whiteboard and confirm drawing text still uses its fonts. Run the grep from the acceptance criteria.
