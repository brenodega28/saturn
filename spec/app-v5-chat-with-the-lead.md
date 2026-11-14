---
title: App v5 — chat with the Lead
status: draft
owner: ""
linked_runs: []
created: 2026-11-14
---

## Summary

Rebuild the main window around the v5 design (canvas page "App v5 · Black", board `V5.dc.html` in the [design canvas](https://claude.ai/artifact/2rBPXF4C8fJi8RvWDGB9BD)). The app becomes chat-first: you only talk to the Lead, and the Lead starts the workers. The sidebar's default tab is one list of chats from every project. Each chat shows its stage (Needs you, Stuck, Building, In review, Done), its project and its workers. A floating card beside the chat holds the machine, the worktree to run, Start/Stop, Changes and Checks.

To get there, several features leave the app: Tasks, the Inbox (screen and record), GitHub, direct chats with agents, the log column, the status bar and the top run bar. Removals come first, so the later phases build on a smaller app. v5 only designs one dark screen, so the phases from the theme onward wait on the designs listed in [DESIGN.md](DESIGN.md).

## Decisions

| Topic | Decision |
| --- | --- |
| Tasks | Removed entirely. The chat record (today's `ProjectTask`, table `task`) stays and is renamed `Chat` |
| GitHub | All GitHub support is dropped: issues, polling, write-back, pull requests, sign-in, settings, onboarding step |
| Inbox | The screen and the `InboxItem` record are removed. Everything the engine waits on you for becomes a request attached to a chat |
| Direct agent chats | Dropped. You only talk to the Lead |
| Log column, status bar | Dropped completely |
| End of a run | Default end action is a local merge into the base branch, with the option to push it afterwards. `EndAction.pullRequest` is removed |
| New chat | A project dropdown with a filter field |
| Footer | Usage, Settings and the weekly budget. No Workers icon; Agents stay on each project card |
| Run the app | The chat card's picker lists `main` and every worktree that belongs to the current chat's runs |
| Planned workers | The spec names the workers the Lead will start, shown before approval |
| Secondary screens | Restyled to v5 |
| Theme | Dark and light |

## What gets removed

| Feature | App | EnsembleCore |
| --- | --- | --- |
| Tasks | `Views/Tasks/`, `AppModel+Tasks`, `ProjectTab.tasks`, the Tasks sidebar section and its run rows, accept/dismiss flows | Queue-only `TaskStatus` cases (`incoming`, `dismissed`), `TaskSource.github` |
| Inbox | `Views/Inbox/`, `AppModel+Inbox`, `SidebarItem.inbox`, the Inbox tool, menu, key-binding and ⌘K entries | `InboxItem`, `InboxKind`, `InboxStatus`, `InboxStore`, `InboxFeed`, and their use in `RunEngine`, `AgentWorkflowDriver`, `PermissionRequests`, `RequestThread`, `RunTimeline`, Quality and budget code |
| GitHub | `GitHubSettingsView`, the GitHub step in onboarding, PR links in Run detail and chat | `GitHub/` (auth, client, poller, remote, write-back, observer), `GitHubStore`, the GitHub token in `SecretStore`, `EndAction.pullRequest`, `Run.pullRequestURL`, PR and issue steps in the bundled workflow YAMLs and templates |
| Direct agent chats | `DirectChatView`, `ChatTarget`, agent routing in `AppModel+Chat` | `Agents/DirectChat.swift` |
| Log column | `LogColumn`, `ChatLogScope` | — (Run detail keeps its own logs) |
| Status bar | `MainStatusBar` | — |
| Top run bar | `RunBar` (its app-runner logic moves into the chat card) | — |
| Per-project chat list | The project's Chat section, `RequestListView`, the "Chats" page | — |

## Phases

Each phase ends with the app building, tests passing and the app usable.

1. **Remove GitHub, Tasks and direct agent chats.**
    - Delete the code listed above for these three features.
    - Default end action becomes `merge`. Workflows and project setup that said `pull_request` are read as `merge`. Add the option to push the base branch after the merge (its form is an open question).
    - Migration drops the GitHub tables and the queue-only task columns. Existing `github` tasks need a decision (see open questions).
2. **Replace the Inbox with chat requests.**
    - New record `ChatRequest` attached to a chat (and its run and agent when there is one): kind (question, plan approval, permission, gate, checks out of retries, budget, loop limit, notice), title, body, options, state (open, answered, dismissed, expired), answer, timestamps.
    - `RunEngine`, `AgentWorkflowDriver`, `PermissionRequests`, `RequestThread`, `RunTimeline`, Quality and budget code use it instead of `InboxItem`.
    - Chat cards read from it. Requests with no chat (an agent spawned by hand, a project setup notice) need a home (see open questions).
    - Migration handles open inbox items (see open questions), then drops the `inboxItem` table. Delete the Inbox UI.
3. **Remove the log column, status bar and top run bar.** Move the app-runner state that `RunBar` reads into a model the chat card can use in phase 6.
4. **Core state for v5 (no UI).**
    - Rename `ProjectTask` to `Chat` across the code.
    - `ChatStage`, worked out from the chat, its runs, its open requests and the current workflow step: Needs you (an open request), Stuck (a run failed or can't proceed), Building, In review (a review step is active), Done (closed or merged).
    - For each chat: its workers with a status line each, lines added and removed across its branches, a checks summary, and its worktrees.
    - Spec front matter gains `workers:` (role and display name per worker, in start order). The parser, the Lead's prompt and spec validation handle it.
5. **Theme and avatars.** Replace `V4Style` with semantic tokens that have a dark and a light value. Remove the forced `.preferredColorScheme(.dark)` and follow the system, with an override in app Settings. Add the robot-face avatars by role from the canvas's Avatars page.
6. **The new shell.**
    - Selection becomes chat-first, replacing `SidebarItem`, the per-project `tabs` and `leadSelections`, and `MainWindowNavigation.baseScreen`.
    - Sidebar: New chat (project dropdown with filter), Add project, Search chats ⌘K, Chats and Projects tabs, the cross-project chat list, project cards, and the footer (Usage, Settings, weekly budget).
    - Main pane: breadcrumb, and the floating chat card (machine, worktree picker, Start/Stop with port, Changes +/−, Checks).
7. **Transcript and composer.** Lead header with its model, plain-text Lead replies, collapsible tool-step rows, the spec card with its planned workers, the workers-started log, the worker roster, a card per request kind, and the composer with model and workflow.
8. **Restyle the secondary screens** in both themes: Agents and Agent session, New agent sheet, Workflows, Changes, Source and the ⌘P finder, Run detail, project Settings, app Settings, Usage, ⌘K, Welcome, Onboarding, Clone and Remote folder sheets.
9. **Clean up and QA.** Delete what's left of `Views/V4`, update `roadmap.md` and `mission.md` where they describe Tasks, the Inbox or GitHub, and run a QA pass against the v5 designs in both themes.

Phases 1–4 can start now. Phases 5–9 wait on the designs in [DESIGN.md](DESIGN.md).

## Acceptance criteria

- [ ] No GitHub, Tasks, Inbox or direct-chat code is left in the app or EnsembleCore, and nothing in the UI mentions them
- [ ] A finished run merges into the base branch locally by default, and you can then push the base branch to its remote
- [ ] Every point where the engine waits on you (question, plan approval, permission, gate, checks out of retries, budget, loop limit) shows as a request in its chat and sets the chat's stage to Needs you
- [ ] A database with existing GitHub tasks and open inbox items migrates without errors, handling them as the open questions settle
- [ ] The Chats tab lists chats from every open project, newest activity first, with stage, project and workers; its badge counts the chats that need you
- [ ] New chat opens a project dropdown that filters as you type
- [ ] The chat card's picker lists `main` and each worktree of the current chat, and Start runs the app from the one picked, on local and SSH projects
- [ ] A spec names its workers, and the spec card shows them before approval
- [ ] Every screen works in dark and light, following the system unless overridden
- [ ] EnsembleCore tests pass and the app builds with xcodebuild after every phase

## Out of scope

- Other task sources (Linear, Jira, Trello)
- Talking to agents other than the Lead
- A replacement for the live log beyond what Run detail already shows

## Open questions

- [ ] Should cloning by URL stay? It only uses plain `git`, not the GitHub API
- [ ] Quality (the Usage/Quality toggle), the Library panel and the Organizer aren't in the v5 nav. Keep, move or remove them?
- [ ] Is the New agent sheet still needed, now that you only talk to the Lead?
- [ ] Where does a request with no chat go (an agent spawned by hand, a project setup notice)? Proposed: the project's most recent open chat, or a new chat titled after the request
- [ ] Migration of open inbox items: copy them into chat requests, or drop them? Proposed: copy
- [ ] Migration of existing GitHub-sourced chats: keep them as ordinary chats, or close them as dropped? Proposed: keep open ones as ordinary chats
- [ ] Pushing after a local merge: a Push action on the done chat only, or also a "Push after merge" project setting? Proposed: both, setting off by default
