---
title: "Top bar v6: status-dot page tabs"
status: in-progress
version: 1
workers:
  - {role: builder, name: SwiftUI Dev 1, reason: "One file, one coherent visual change in PageTabStrip.swift"}
owner: ""
linked_runs: [31]
created: 2026-11-25
---

## Summary

Bring the page tab strip above the chat (Saturn/Views/V5/PageTabStrip.swift) in line with the Chat v6 design. The strip's size, colours, tab shape, + menu, drag to reorder, close buttons and context menu already match the design, so only three things change. (1) A chat tab's icon becomes a status dot instead of the project tile: an 8 pt dot in the chat's stage colour on a 14 pt halo in the stage's background colour. The halo pulses while the chat is Building or In review. A new chat with no stage yet shows the idle colour. (2) Because the dot now shows the stage on every chat tab, the separate 7 pt attention dot after the title goes away. (3) The active tab gets a 2 pt accent line along its top edge. Terminal, code and other page tabs keep their SF Symbol icons.

## Interfaces

- PageTab (private, PageTabStrip.swift): for .chat/.newChat pages, the icon becomes a new StageDot(stage: ChatStage?) view, and the trailing attention Circle is removed
- StageDot: a 14×14 frame holding a halo circle filled with stage.background and an 8×8 dot filled with stage.color; nil means Tokens.idle on Tokens.fill. It pulses (scale 0.6↔1.15, opacity 0.9↔0.25, 1.8 s ease-in-out, repeating) when stage is .building or .inReview. accessibilityLabel = stage.title, or "New chat" when nil
- Active tab: a 2 pt Tokens.accent line inset along the top edge, inside the rounded top corners

## Out of scope

- Moving or removing the side-bar toggle and the narrow-window chat card pill. The v6 artboard leaves the strip's right side empty, but that is unresolved (see the open question) and they stay where they are for now
- Renaming the stage labels (the design says Waiting/Done; the app keeps Open/Finished/Resolved)
- The left bar, the right bar and the chat body from v6
- Tab sizes, colours, the + menu, drag to reorder and the context menu, which already match

## Acceptance criteria

- [ ] Every chat tab shows a status dot in its stage colour, never a project tile
- [ ] The halo pulses only for Building and In review, and pulsing stops when Reduce Motion is on
- [ ] No separate attention dot appears after a tab title
- [ ] The active tab has a 2 pt accent line at the top that follows the rounded corners; inactive tabs have none
- [ ] Terminal, code, run, agent, spec and tool tabs still show their SF Symbol icon
- [ ] VoiceOver reads the dot's stage (e.g. "Needs you") before the tab title
- [ ] The app builds and the existing SaturnTests pass

## Verification

Build and run Saturn. Open chats in different stages (needs you, stuck, building, in review, finished, idle) plus a terminal and a code page. Check each tab's dot colour and pulse, the accent line on the active tab as focus moves, and Reduce Motion. Compare in dark and light themes against Chat v6 on the canvas, then run the SaturnTests scheme.
