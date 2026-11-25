---
title: Implement the v4 left sidebar tree
status: done
owner: ""
linked_runs: [82]
created: 2026-11-04
---

## Summary

Rebuild `ProjectSidebar` (Saturn/Views/V4/ProjectSidebar.swift) to match the left bar in the v4 design artifact (https://claude.ai/artifact/2rBPXF4C8fJi8RvWDGB9BD, artboard `project/V4.dc.html`). Each open project becomes a tree. A *Work* group holds Chat, with the open chats nested under it, and Tasks, with the active runs nested under it. A *Crew* group holds Agents and Workflows. A *Review* group holds Changes and Source. An unnamed group holds Settings. Each section row has an icon and an optional count. The bottom tool row shrinks to four icons: Inbox, Search ⌘K, Usage and App settings ⌘,. The project-scoped tools move up into the tree, so the bar matches the design and project navigation lives under each project.

## Interfaces

- `ProjectSidebar` (Saturn/Views/V4/ProjectSidebar.swift): project header, then for the open project the groups Work [Chat, Tasks] · Crew [Agents, Workflows] · Review [Changes, Source] · (unnamed) [Settings]. Group labels are 10.5pt semibold secondary text. Section rows are 30pt tall with a 15pt V4Icon, the name and an optional mono 11pt bold badge.
- Section row actions: Chat → `model.startNewChat(in: project)`; Tasks/Agents/Workflows/Changes/Source/Settings → `model.open(.tasks/.agents/.workflows/.changes/.code/.settings)`. Source maps to `MainTool.code`. A section row is highlighted (white text and icon, semibold) when the main screen is that tool. Chat is highlighted when the screen is `.chat`. Agents is also highlighted on an `.agent` screen.
- Nested chat rows, under Chat: the open requests from `LeadRequest.partition(...).open`. Each is 26pt tall, indented 34pt, with a 6pt status dot (`statusColor`), the title truncated with a tail ellipsis, and a right-aligned 11pt status. The status reads "Needs you" in orange when the badge count is above 0 and the row isn't current; otherwise it's the first segment of `requestStatusLabel` in secondary text. The current chat gets the `V4.selected` background. The row keeps its click (`showChat`), context menu (`RequestCloseMenu`), help text and the existing accessibility label (including the pending-approvals count).
- Nested run rows, under Tasks: only the active (not finished) runs of the project. Each row has a status dot, the run or request title and a short status (current step name or state). Clicking it opens the run detail screen (`.run(id)`).
- Section badges: Tasks = number of needs-you tasks in the project (orange). Agents = total agents in the project (secondary grey). Changes = branches waiting for review, using the existing `ProjectOutline.changesBadge` (orange). No badge when the count is 0.
- Project header: unchanged behavior (expand, context menu, attention dot when collapsed). It always shows the local/laptop icon with a `Local · <path>` tooltip and accessibility label.
- `ToolRow`: exactly four equal-width buttons — Inbox (orange badge = `model.inboxCount`), Search ⌘K (`openPalette`), Usage (`open(.usage)`), App settings ⌘, (opens the app Settings window via `@Environment(\.openSettings)`). The top 1pt divider stays.

## Out of scope

- Remote/cloud projects and the cloud icon
- The "+ New chat" row, which is removed; the Chat section row replaces it
- Changes to the toolbar, chat column, log column or status bar
- New model-level navigation concepts beyond what the sidebar needs

## Acceptance criteria

- [x] With a project open, the sidebar shows the groups Work, Crew and Review, then Settings, in the order from the design, each section with its icon
- [x] Clicking Chat starts a new chat in that project; each other section opens its tool screen; Source opens the Code screen
- [x] The section matching the current main screen is highlighted; Chat is highlighted on the chat screen and Agents on an agent detail screen
- [x] The open chats of the project appear indented under Chat with a status dot, title and status; a chat that needs you shows an orange "Needs you" unless it is the current chat
- [x] Only active runs appear under Tasks; clicking one opens its run detail; finished runs don't appear
- [x] The Tasks badge shows the project's needs-you task count, the Agents badge its total agent count and the Changes badge the branches waiting for review; badges are hidden at 0
- [x] The bottom row has exactly four buttons: Inbox (with its badge), Search, Usage and App settings; App settings opens the app Settings window
- [x] There is no "+ New chat" row
- [x] Collapsed projects still show only the header with its attention dot; clicking a header expands that project
- [x] Chat row context menus, tooltips and accessibility labels (including the pending command approvals count) still work
- [x] VoiceOver reads the section rows and the four tool buttons with their names and badge counts
- [x] No code comments are added (per CLAUDE.md)
- [x] The app builds, and `swift test` in Packages/SaturnCore passes

## Verification

Build the app with xcodebuild and run `swift test` in Packages/SaturnCore. Launch the app with a project that has open chats, an active run, agents and a branch waiting for review. Check every section row's navigation and highlight, the nested chat and run rows, the badges, the four bottom buttons (App settings opens the Settings window), and collapse/expand of a second project. Compare it side by side with the V4 artboard of the design artifact.
