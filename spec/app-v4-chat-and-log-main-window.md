---
title: "App v4: chat and log main window"
status: in-progress
owner: ""
linked_runs: [65]
created: 2026-11-02
---

## Summary

Replace the v3 Workbench (navigator, editor tabs, inspector, bottom panel, status bar) with the "App v4 · Chat and log" design from the Ensemble design canvas (artboard project/V4.dc.html, page "App v4 · Simple", https://claude.ai/artifact/0ef6fc43-aaf9-46f5-97f8-239118e3d430). The main window has three columns inside one rounded glass container on the existing Backdrop: (1) a 236px project sidebar where each open project is a collapsible group listing its lead chats (requests), plus "+ New chat", with a row of tool icons pinned at the bottom; (2) the lead chat in the middle (760px max reading width, floating composer) with spec, permission and question cards inline in the conversation; (3) a 470px live Log column showing ActivityLog entries with All / This chat / Needs you filters. Clicking a tool icon temporarily replaces the chat column with that screen (with a back button), keeping sidebar and log visible. The design is matched pixel-for-pixel: sizes, paddings, radii, colors, fonts and copy as in the artboard.

## Interfaces

- Ensemble/Views/V4/ (new folder, name at builder's discretion): MainWindowView (3 columns), ProjectSidebar, ChatColumn, LogColumn, ToolScreen container with back button
- RootView.content: WorkbenchView() replaced by the new main window view
- Sidebar project group: name (11pt bold), Local icon (laptop glyph, tooltip 'Local · <path>'), attention dot when collapsed; expanded group lists that project's open lead requests (title, one-line status meta, status dot on the avatar, orange count badge when it needs the user), '+ New chat' calls startNewLeadRequest
- Sidebar tool row (bottom, above a hairline): Inbox (with badge count), Changes (with badge), Search ⌘K (opens CommandPalette), Agents, Tasks, Workflows, Code, Usage (Quality stays a sub-view of Usage), Settings; icon-only 32px tall buttons with aria/help labels; wraps to a second row if it doesn't fit 236px
- Tool screen mode: selecting a tool shows that existing screen (InboxView, ChangesView, AgentsView, TasksView, WorkflowsView, CodeView, UsageView, ProjectSettingsView) in the middle column under a header with a back button that returns to the last selected chat
- Run detail and Agent session stay reachable: from links/cards in the chat, from Log rows (clicking a row with a runId/agentId opens it in the middle column with the same back button), and from the Agents screen
- Inline chat cards: spec card (title, path, status badge, Files/Interface/Out of scope/Done when/Verify rows, Edit spec + Approve & start → 'Approved · run starting'), permission card (orange, Allow once / Always for this project / Deny → result line), lead question card (answer buttons), 'No plan needed' pill; all wired to the existing model actions the Chat inspector uses today
- LogColumn: header 'Log' (Archivo-like display, bold) + green 'live' dot + segmented filter All / This chat / Needs you; rows in a 62px time / 14px level / 62px source (colored square) / message grid, monospaced 11.5pt, warning and error row tints per the artboard. 'This chat' = entries whose runId belongs to a run of the selected request (Run.taskId) or whose agentId is on such a run; 'Needs you' = warning-level entries
- Composer: floating rounded glass form at the bottom of the chat column, 2-line textarea with placeholder 'Describe a change, or reply to Tech Lead…', round blue send button; existing LeadComposer behavior (send, held sends, attachments if present) preserved

## Out of scope

- Remote projects: only the Local icon is shown
- The composer's attach '+' button, the workflow picker chip ('Feature delivery v5') and the 'shopfront · main' branch label
- Keeping v3 behind a toggle: the Workbench is removed outright
- Direct chats with individual agents in the sidebar (agents remain reachable via the Agents tool screen)
- Changes to Welcome, First run, Onboarding, Settings window (⌘,), Organizer and Library windows beyond removing references to deleted Workbench types
- Light mode

## Acceptance criteria

- [ ] Launching the app with an open, onboarded project shows the v4 three-column window; no navigator, editor tabs, inspector, bottom panel, status bar or workbench toolbar appear anywhere
- [ ] WorkbenchView, the Workbench navigators/inspectors/bottom panels, ChatInspector and ChatPeoplePanel are deleted and the app builds with xcodebuild with no warnings introduced
- [ ] Every open project appears in the sidebar; clicking a project header expands it and collapses the others; its open lead requests are listed and clicking one shows that chat in the middle column
- [ ] '+ New chat' starts a new lead request in that project and focuses the composer
- [ ] Spec, permission and question requests from the lead appear as inline cards in the chat and their buttons perform the same actions the Chat inspector did (verified by approving a spec, answering a permission, answering a question)
- [ ] The Log column shows live ActivityLog entries for the open projects, newest first; the three filters work as defined in Interfaces
- [ ] Each tool icon replaces the middle column with its screen and a back button returns to the previously selected chat; sidebar and log stay visible throughout
- [ ] Run detail and Agent session can still be opened (from chat run links, Log rows, and the Agents screen)
- [ ] ⌘K palette and menu-bar commands that pointed to Workbench panes either open the matching v4 screen or are removed; no command references deleted types
- [ ] Side-by-side screenshot of the running app next to the V4 artboard at 1600×1000 matches layout, sizes, radii, colors and copy (allowing for real data)
- [ ] Existing EnsembleCore tests pass (swift test in Packages/EnsembleCore)

## Verification

Build with xcodebuild and run swift test in Packages/EnsembleCore. Launch the app on a project with at least two lead requests and an active run: check the sidebar, switch chats, start a new chat, trigger a spec / permission / question from the lead and act on each inline card, watch the Log fill live and exercise All / This chat / Needs you, click every tool icon and return with Back, open a Run detail from a Log row. Screenshot the window at 1600×1000 and compare it with project/V4.dc.html on the design canvas (qa-review skill).
