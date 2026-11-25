---
title: "v5 sidebar option A: status groups"
status: done
version: 1
workers:
  - {role: builder, name: Sidebar Dev, reason: "One SwiftUI change across ChatSidebar, SidebarParts and CommandPalette; the pieces depend on each other, so one builder"}
  - {role: checker, name: QA, reason: "Builds, runs the tests and checks the sidebar against the acceptance criteria with fresh eyes"}
owner: ""
linked_runs: [11]
created: 2026-11-25
---

## Summary

Rebuild the left chat sidebar (Ensemble/Views/V5/ChatSidebar.swift and SidebarParts.swift) to match design "v5 · Sidebar options", option A (the "Finished opened" artboard). The Chats/Projects tabs and the project cards go away. Below the header and the ⌘K search button comes a project filter: an "All projects ▾" pill and one chip per open project. Chats are then grouped by status into collapsible groups: Needs you, In progress and Not started. Finished chats get their own section pinned to the bottom of the list, with a "Closed N ›" button that swaps that section for the closed list. Chat rows become a compact two-line layout with a status glyph and the machine, and they keep the worker avatars. The per-project tools leave the sidebar, so ⌘K has to reach them for every open project, not just the current one.

## Interfaces

- ChatSidebar: drop SidebarTab and SidebarTabs and remove the sidebar.tab AppStorage key. The ProjectCards view and its sidebar uses are deleted. FleetHeader and ProjectCard go only if nothing else uses them.
- New ProjectFilterBar view. An "All projects ▾" pill opens a menu: All projects, then each open project (with its machine when it's remote). Next to it, one 28pt chip per open project shows its ProjectTile. Clicking a chip filters to that project, and clicking the active chip clears the filter. The filter is saved as AppStorage "sidebar.projectFilter" (a daemon+project key, empty for all) and falls back to All if that project is gone.
- New ChatGroup enum: needsYou (stages needsYou, stuck), inProgress (inReview, building), notStarted (idle) and finished (finished). Groups sort by stage, then by lastActivity, newest first. A pure, unit-testable function maps [ChatSummary] to groups.
- New StatusGroup view. Its header button has a chevron (rotated when open), the name (Needs you in Tokens.need, the others in text2) and a mono count. Empty groups are hidden. Whether each group is collapsed is saved in AppStorage ("sidebar.group.<id>").
- New FinishedPanel, pinned below the scrolling list. It has a top hairline and a slightly darker background (#08080A in dark). Its header is a collapsible "Finished N" plus a trailing "Closed N ›" button. When open it scrolls within a max height of about 250pt. "Closed N ›" swaps the panel's content for the existing closed list: ClosedChatRow with Reopen on hover, the closedLimit of 24, the hint 'Older closed chats are in ⌘K search' and a back control. The panel is hidden when there are no finished and no closed chats.
- ChatRow is restyled, keeping its hover, selection, unread, rename, context menu and accessibility label. A 14pt status glyph (a new StageGlyph view) replaces the dot and stage text: Needs you is an orange ring with '!', Stuck a filled red circle with '!', Building a blue ring with a half pie, In review a yellow ring with a three-quarter pie, Not started a dashed grey ring, Finished a filled green circle with a check. Line 1 is the title on one line, ellipsised, at 13.5pt (semibold, or medium for finished), with the time at 11pt text3 on the right. Line 2 is the 13pt ProjectTile and project name, then '·', then MachineLabel ('This Mac' or the SSH host), then a spacer and the WorkerStack. Padding is 7pt vertical and 8–10pt horizontal, with a 9pt corner radius.
- Search button label becomes 'Search' (⌘K unchanged).
- CommandPalette: the 'Go to' group lists each tool (Agents, Workflows, Changes, Source, Settings sections) for every open project, not just the current one, with the project (and machine when remote) as meta. 'Actions' gains, per project: New chat in <project>, Reveal in Finder or Copy SSH path, and Remove <project> from Ensemble…. These replace the old project-card context menu.

## Out of scope

- Options B, C and D from the design page
- Any changes to the header buttons, the add-project and new-chat flows, the footer, the budget popover or the system alert cards
- Changes to how ChatStage is computed
- A light theme beyond what the existing Tokens give

## Acceptance criteria

- [x] The Chats/Projects segmented control and the project cards are gone from the sidebar
- [x] The filter row shows 'All projects ▾' and one chip per open project. A chip or menu item filters every group, Finished and Closed included, to that project, and the choice persists across relaunch
- [x] Open chats show under Needs you (needsYou and stuck), In progress (inReview and building) and Not started (idle), each with a correct count. Empty groups are hidden
- [x] Each group collapses and expands from its header, and the state persists
- [x] Finished chats appear only in the bottom panel, which stays pinned while the list scrolls. It collapses and expands, and its count is correct
- [x] 'Closed N ›' shows the closed chats in the bottom panel with Reopen on hover. Going back restores the Finished view
- [x] Chat rows show the stage glyph, a one-line title with the time, the project tile and name, the machine and the worker avatars. Selection, hover, unread, rename and the context menu still work
- [x] The ⌘K palette finds Agents, Workflows, Changes, Source and Settings for any open project, plus New chat in, Reveal or Copy SSH path, and Remove for that project, and each opens on or acts on the right project and daemon
- [x] The empty states (no projects, no chats) still show
- [x] Grouping and filtering have unit tests, and the existing tests pass

## Verification

1. Run `xcodegen generate`, then build the Ensemble scheme with xcodebuild. 2. Run `swift test --package-path Packages/EnsembleCore` and the app's unit tests, including the new grouping and filter tests. 3. Launch the app with at least two projects (one remote if one is available) and chats in every stage. Compare the sidebar against the design's 'A · Finished opened' artboard, then go through each acceptance criterion: filtering, collapsing, persistence after relaunch, Closed and Reopen, and ⌘K for project tools on a project that isn't current.
