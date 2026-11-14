---
title: v5 page tabs and chat side bar
status: done
version: 1
workers:
  - {role: builder, name: SwiftUI Dev}
  - {role: qa-engineer, name: QA}
owner: ""
linked_runs: [2]
created: 2026-11-14
---

## Summary

Replace the v5 main window's single-screen middle column with page tabs, following the "v5 · Pages and side bar" boards of the v5 design (V5_pages_* artboards and the V5 component). The main area gets a tab strip. A tab can be a chat, a terminal, a code file or one of the tool screens: Changes, Agents, Workflows, Code, Usage, Settings, Run detail, Agent session and Spec. Tabs can be reordered, closed and switched from the keyboard, and they are restored after a relaunch. On chat tabs, a right-hand side bar with Summary and Log tabs replaces the floating chat card. Terminal tabs are real shells: a PTY driven by a terminal emulator view such as SwiftTerm, opened in the chat's worktree and run over SSH for remote projects.

## Interfaces

- `MainPage` (Codable, Identifiable): `id: UUID` plus `kind`, one of `.chat(chatID: Int64?, projectID: Int64)` (nil means a new chat), `.terminal(projectID: Int64, directory: String)`, `.code(projectID: Int64, path: String)`, `.tool(MainTool, projectID: Int64?)`, `.run(Int64)`, `.agent(Int64)` and `.spec(path: String, projectID: Int64)`
- `MainPages` (@Observable, owned by `AppModel`): `pages: [MainPage]` and `activeID: UUID?`, with `open(_:)`, `focus(_:)`, `close(_:)`, `closeOthers(_:)`, `move(fromOffsets:toOffset:)`, `selectNext()`, `selectPrevious()` and `select(index:)`. Persisted as JSON in `AppDefaults.store`; on restore, pages whose chat, run, agent or project no longer exists are dropped
- `AppModel.mainScreen`, `open(_ tool:)`, `showChat(_:)`, `openSpecScreen`, `goBack` and run/agent navigation are rerouted to open or focus a page instead of swapping the whole middle column
- `PageTabStrip` view: the tabs, the + menu (New chat ⌘N, New terminal ⌃`, Open file… ⌘P) and the side bar toggle
- `TerminalPage` view: a PTY-backed shell in the page's directory, with a header showing the cwd, the branch and `zsh · cols×rows`. Remote projects run `ssh -t <host> 'cd <dir> && exec $SHELL -l'`. The process is killed when the tab closes or the app quits
- `CodePage` view: the existing `CodeReader` for one file, read-only, with a header showing the path, the branch and a 'New in this chat' badge when it applies
- `ChatSideBar` view: Summary and Log tabs with 'This chat only'. Summary is the chat's title, project and status followed by the existing ChatCard rows and the workers. Log is this chat's events, newest first, filterable by All, Needs you and Checks, with a live indicator
- New package dependency in `project.yml`: SwiftTerm, pinned to an exact version
- Menu commands and shortcuts: Close Tab ⌘W, Next Tab ⌘⇧], Previous Tab ⌘⇧[, Select Tab 1–9 ⌘1–⌘9, New Terminal ⌃`, Open File ⌘P (existing finder, now opens a code tab), New Chat ⌘N, and Toggle Side Bar

## Out of scope

- Dragging tabs into a new window, or tearing them off
- Split panes or showing two pages side by side
- Running terminals through the Ensemble daemon (they run in the app process)
- Editing files in code tabs (they stay read-only)
- Restoring a terminal's output or running processes after a relaunch
- Redesigning the left chat sidebar

## Acceptance criteria

- [ ] The middle area shows a tab strip styled like the design: active tab on the window color with a hairline border, inactive tabs on the fill color, max width 250pt, truncated titles, and a close × on every tab (dimmed on inactive tabs)
- [ ] Chat tabs show the project tile and the chat title. An inactive chat tab whose chat needs you or is stuck shows a colored status dot with an accessibility label. Terminal, code and tool tabs show an icon and a title
- [x] Clicking a chat in the sidebar focuses its tab if one is open. Otherwise it replaces the active tab when that tab is a chat, or opens a new tab when it isn't
- [ ] The + menu opens New chat, New terminal and Open file…. Open file uses the existing ⌘P finder and opens the chosen file as a code tab
- [x] Changes, Agents, Workflows, Code, Usage, Settings, Run detail, Agent session and Spec each open as a tab. Opening one that is already open focuses its tab instead of making a duplicate
- [x] Closing the active tab focuses the tab to its right, or the last tab. Closing the last tab shows 'No pages open' with New chat, Terminal and Open file… buttons
- [ ] Tabs can be reordered by dragging. The context menu has Close and Close Others. ⌘W, ⌘⇧[, ⌘⇧] and ⌘1–⌘9 work
- [ ] A terminal tab runs an interactive login shell in the chat's worktree (or the project root), handles input, resize, colors and scrollback, and its process exits when the tab closes. Remote projects open the shell on the SSH host
- [ ] On chat tabs, the right side bar (320pt) replaces the floating ChatCard. Its Summary tab keeps every ChatCard row working (machine, worktree picker, run, output, changes, checks) and lists the workers. Its Log tab lists this chat's events with working filters
- [x] The side bar toggle in the tab strip shows and hides the side bar, and the chat column then uses the full width. The narrow-window pill behaviour still works
- [x] Open tabs, their order, the active tab and the side bar's open state and tab survive a relaunch. Tabs pointing at deleted chats, runs or projects are dropped silently, and terminals restart fresh in their directory
- [x] The colors come from the existing `Tokens` in both dark and light themes. No hard-coded hex values
- [x] `swift test --package-path Packages/EnsembleCore` passes, and the app builds with `xcodegen generate && xcodebuild` for the Ensemble scheme

## Verification

Build the app (`xcodegen generate`, then `xcodebuild -scheme Ensemble build`) and run the EnsembleCore tests. Unit-test `MainPages`: open, focus, close and neighbour selection, reorder, dedupe of tool tabs, and JSON round-trip with stale pages dropped. In the running app, check each state against the V5_pages_* boards in dark and light. That covers a chat tab with the side bar on Summary, Log with each filter, the side bar hidden, a terminal tab (run `git status`, resize, close it and confirm the shell process is gone with `ps`), a code tab opened from ⌘P, the + menu, every tab closed, and tool screens opening as tabs and deduping. Drag-reorder the tabs, use ⌘W, ⌘⇧[ ], ⌘1–9, quit and relaunch, and confirm the tabs come back. Delete a chat that has an open tab and confirm the tab disappears.
