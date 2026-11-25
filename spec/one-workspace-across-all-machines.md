---
title: One workspace across all machines
status: in-progress
version: 1
workers:
  - {role: builder, name: Workspace Refactor Dev, reason: "One builder: moving per-daemon state into DaemonWorkspace touches AppModel and almost every view together, so splitting the work would interfere."}
  - {role: checker, name: QA, reason: Fresh eyes to test multi-machine behavior end to end against the acceptance criteria (qa-engineer skill).}
owner: ""
linked_runs: [7, 8]
created: 2026-11-24
---

## Summary

Today AppModel has one active DaemonConnection. Chats, pages, request feeds, permissions and every per-project dictionary come from it, and opening a project on another machine calls activate(), which wipes tabs and pages. This change removes the idea of an active machine. Each connected daemon gets its own DaemonWorkspace holding its per-machine state: connection, database, live state, ChatRequestFeed, ChatNotificationFeed, PendingPermissionFeed, openProjects, projectStates, configs, and the other dictionaries keyed by project or chat id. Project and chat ids are only unique within one daemon's database, so every page and selection that names a project, chat, run or agent also carries the DaemonID. The page strip becomes one list stored under one key, so chats and tabs from different machines stay open side by side. Each page's view gets its own machine's workspace through the SwiftUI environment. The sidebar's Chats tab merges chats from every machine, with live status and needs-you badges. The Projects tab keeps one group per machine, and every group uses the same full ProjectCard (chat counts, expand/collapse, Crew/Review items) that only the active machine's projects get today.

## Interfaces

- `@MainActor @Observable final class DaemonWorkspace` (new, Ensemble/DaemonWorkspace.swift): owns `connection: DaemonConnection`, `database`, `live`, `requests: ChatRequestFeed`, `chatNotifications`, `pendingPermissions`, `openProjects`, `recentProjects`, `projectStates`, `configs`, and the other project- or chat-keyed dictionaries now on AppModel (runDetailIDs, leadSelections, selectedAgents, changesRunSelections, skillPlugins, settingsSections, workflowEditors, appRunners, remoteStatuses, newChatOptionsByProject, projectFileLists, focusedPinIDs, …). It also owns the daemon-scoped methods that read or write those, such as reloadProjects, chatSummaries, chatLog, leadRequests, agentSessions and send.
- `AppModel.workspaces: [DaemonID: DaemonWorkspace]` replaces `connection`, `connections`, `requests`, `chatNotifications` and `pendingPermissions`. `AppModel.orderedWorkspaces` puts the local machine first, then the rest by name. `AppModel.workspace(for: DaemonID) -> DaemonWorkspace?`.
- `AppModel.activate(_:)` is removed, along with the per-daemon page key `pagesKey(for:)` and the `fleet.activeDaemon` default.
- `MainPageKind` cases that name a project, chat, run or agent also carry `daemon: DaemonID`. On first launch after the change, pages saved under the old per-daemon keys move into the new single key, tagged with their daemon.
- `SidebarItem.project` and the selection, tab and lastProjectID state carry DaemonID together with the project id (for example a `ProjectRef { daemon: DaemonID; id: Int64 }`).
- `@Environment(DaemonWorkspace.self)` is injected by the main page host for each page, and by the sidebar for each project card and chat row, so per-project views read their own machine's state.
- `ChatSummary` gains `daemon: DaemonID`. The aggregate `AppModel.chatSummaries()` merges every workspace's summaries, sorted by last activity. The attention and dock badge counts cover every machine.
- `ChatRow` and `ChatSideBar` show a small machine label (laptop or server icon plus host name) on chats that are not on this Mac.
- The `ProjectCards` sidebar shows one `FleetHeader` per workspace, each followed by full `ProjectCard`s and its own `+ Add project` affordance. The plain link rows for other machines are removed.
- Opening an SSH folder, `moveToServerDaemon` and `openOnServer` open the project in its machine's workspace without switching anything else.
- `NewChatPicker` and the command palette (⌘K) list projects and chats from every machine, with machine labels.

## Out of scope

- Daemon protocol or database schema changes in EnsembleCore. Ids stay per daemon, and the client qualifies them with DaemonID.
- Moving a chat or project from one machine to another, apart from the existing moveToServerDaemon flow.
- Merged Usage or spend across machines beyond what it shows now. The footer budget keeps today's behavior unless it already reads the local daemon.
- Visual redesign of the sidebar beyond the machine labels and full project cards for every group.
- Syncing settings between machines.

## Acceptance criteria

- [ ] With the local daemon and at least one SSH daemon connected, the Chats tab lists open chats from both machines in one list sorted by last activity. Chats from the SSH machine show its machine label.
- [ ] A chat on the SSH machine that is waiting on the user shows the needs-you stage. It counts toward the Chats tab badge and the dock badge while a local chat page is focused.
- [ ] The Projects tab shows a header for each machine, and every project under it is a full ProjectCard with active-chat and needs-you counts. Expanding one opens its Agents, Workflows, Changes, Source and Settings pages on the right machine.
- [ ] Opening a chat from machine A and then a chat from machine B leaves both pages open in the page strip. Switching between them shows each one's correct messages, side bar summary, log and workers, and no page closes.
- [ ] Two projects on different machines with the same database id (for example both id 1) never share state: tabs, selections, configs, chat lists and settings stay separate.
- [ ] Sending a message, approving a permission, starting a run, and resolving or closing a chat from a page always goes to that page's own daemon.
- [ ] When a remote daemon goes offline, its pages stay open and show an offline state. Its sidebar group shows 'offline'. Local pages keep working.
- [ ] Removing a server in Settings → Servers closes only that machine's pages and sidebar entries.
- [ ] After a relaunch, open pages from every machine come back. Pages saved by the previous version under per-daemon keys are migrated once and nothing is lost.
- [ ] `activate(` and `fleet.activeDaemon` no longer appear in Ensemble/. No view reads a global `model.connection`.
- [ ] `swift test --package-path Packages/EnsembleCore` passes, and the app builds with xcodebuild after `xcodegen generate`.

## Verification

Build: `xcodegen generate && xcodebuild -scheme Ensemble build`, then `swift test --package-path Packages/EnsembleCore`. End to end: run the app with the local daemon plus one SSH server, for example `bgomes@macserver.local`, and with projects open on both, including one project name that exists on both machines. Check every acceptance criterion by hand: the merged Chats list, the grouped full Projects cards, pages from both machines open side by side, a needs-you chat on the remote machine badged while working locally, sending and approving routed to the right daemon, the offline behavior when you kill the SSH daemon, and a relaunch that restores all pages. A QA checker runs these steps and reports screenshots.
