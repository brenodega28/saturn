---
title: "Right bar v6: Task, Project and Log"
status: in-progress
version: 1
workers:
  - {role: builder, name: SwiftUI Dev, reason: "Builds the whole right bar in ChatSideBarView.swift and the files around it. It's one task because all three tabs share one header and one model."}
  - {role: checker, name: QA, reason: "Runs the app, checks it against the design and the acceptance criteria, and runs the tests."}
owner: ""
linked_runs: [27]
created: 2026-11-25
---

## Summary

Replace the current chat side bar (`ChatSideBar` in Saturn/Views/V5/ChatSideBarView.swift, with its Summary/Log folder tabs) with the Right bar v6 from the Saturn design canvas (page "Right bar v6": Task, Project and Log). It should match the Left bar v6 look: the same Tokens.side background, hairlines, 12px semibold grey section headers, 9–10pt rounded rows with a hover fill, and the same spacing as `ChatSidebar`, so the window has matching bars on both sides. The header has a segmented icon switcher (Task, Project, Log), with a dot on a tab that has news, then the page name and a Hide side bar button. The Task page shows the chat's status pill and time, its title and goal, a stage bar (Plan, Build, Review, Merge), a card with the branch/worktree picker, the app run row and collapsible output, Changes (+/− and a file list), collapsible Checks, Workers, and a footer with Review changes. The Project page shows the project tile, its name and machine/path, stat tiles, an Agents list with Manage, and a Repository facts card. The Log page keeps today's log data, with the v6 filters (All, Lead, Workers, Tools), a Live indicator, a timeline with avatars and tag chips, optional detail blocks and a footer meter. Anything the app has no data for (the stack chips, the Lead-written project summary, the Open PR button, per-chat tokens) is left out rather than faked.

## Interfaces

- `enum SideBarTab { case task, project, log }` replaces `summary/log`; saved state decodes an old `summary` as `.task` so existing users don't lose their pages
- `struct ChatSideBar(project:chat:)` keeps its name and call site in ToolScreen.swift `PageHost`; it gets new private views `SideBarHeader`, `TaskPane`, `ProjectPane`, `LogPane`
- `ChatLogFilter` becomes `all / lead / workers / tools`; `ChatLogEntry` gets `kind` (lead, worker, tool) and optional `detail: String?`
- Reuses `ChatCardRows` parts (worktree picker, run row, output, changes, checks) by moving them to `internal` where the Task page needs them; the floating `ChatCard` and pill keep working
- Hide side bar button sets `model.pages.isSideBarOpen = false` (the same flag the existing toggle uses)

## Out of scope

- Redesigning the left bar or the centre chat column
- New data sources: the Lead-written project summary, the tech-stack chips, per-chat token and spend tracking, Open PR / GitHub integration
- The light theme beyond what Tokens already adapts
- Narrow-window behaviour (the side bar still hides below the current width)

## Acceptance criteria

- [ ] Opening a chat shows the new right bar with Task, Project and Log icon tabs; the old Summary/Log folder tabs and the 'This chat only' label are gone
- [ ] The bar's background, borders, header heights, section header style, row height, corner radius and hover look match ChatSidebar (the left bar), side by side
- [ ] The selected tab survives an app restart; a saved `summary` value opens on Task
- [ ] Task: shows the chat's status pill, title, the stage bar marking the current stage, the branch picker (switching the worktree works as before), the Run/Stop row with Open in browser, the output that expands, Changes with the file list linking to the Changes screen, the Checks list that folds, and Workers with their state; Review changes opens the Changes screen
- [ ] Project: shows the project tile, name, machine and path, stat tiles computed from real data (active chats, workers running, needs you, finished), the project's agents with their model, role and state, and Repository facts (default branch, remote, run command, instructions file); Manage opens the Agents screen
- [ ] Log: the filters All, Lead, Workers and Tools narrow the entries correctly; entries show an avatar, name, tag chip, time and text, plus a mono detail block when one is present; an empty filter shows 'Nothing logged for this filter yet.'
- [ ] Hide side bar hides the bar and the existing toggle shows it again
- [ ] Every control has an accessibility label; the code builds with no new warnings; the existing unit tests pass, and new tests cover the SideBarTab migration and the log filter matching

## Verification

Build and run Saturn (xcodegen + xcodebuild as in the README), open a chat that has a run with workers, changes and checks, then compare each tab with the matching artboards on the 'Right bar v6' canvas page and with the left bar on screen. Switch tabs, restart the app and check the tab is remembered; use the branch picker, Run/Stop, output, checks fold, log filters and Hide. Run `swift test` in Packages/SaturnCore and Packages/SaturnUI, plus the app's unit tests.
