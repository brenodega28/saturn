---
title: App v5 — chat with the Lead
status: in-progress
owner: ""
linked_runs: []
created: 2026-11-14
---

## Summary

Rebuild the app around the v5 design in the [design canvas](https://claude.ai/artifact/2rBPXF4C8fJi8RvWDGB9BD). The app becomes chat-first: you only talk to the Lead, and the Lead starts the workers. The sidebar's default tab is one list of chats from every project. Each chat shows its stage (Needs you, Stuck, Building, In review, Done), its project and its workers. A floating card beside the chat holds the machine, the worktree to run, Start/Stop, the app's output, Changes and Checks.

To get there, several features leave the app: Tasks, the Inbox (screen and record), GitHub, direct chats with agents, the log column, the status bar and the top run bar. Removals come first, so the later phases build on a smaller app.

## Designs

Every screen is drawn in dark and light, on these canvas pages. The brief the designer worked from is [DESIGN.md](DESIGN.md).

| Page | What it covers |
| --- | --- |
| App v5 · Black | The base chat window and the shared components (`V5`, `V5Screen`, `V5Welcome`, `V5Notify`) |
| v5 · 1 Theme | Tokens for both themes and the reference screen |
| v5 · 2 Sidebar | New chat picker, empty states, chat rows (hover, menu, rename, long titles), closed chats, project cards, SSH states, budget, ⌘K |
| v5 · 3–4 Navigation & chat card | Secondary screens in the window, worktree picker, run states, app output, checks, the narrow-window pill |
| v5 · 5 Chat | New chat, Lead thinking/streaming/working, spec card and editor, spec versions and rejection, every ask card, workers, In review, Done, Pushed |
| v5 · 6 Composer | Model, workflow, `@` files, `/` commands, attachments, queued messages |
| v5 · 7 Alerts | Claude CLI missing, rate limit, SSH disconnected, Dock badge and notifications |
| v5 · 8 Secondary screens | Agents, New agent, Agent session, Workflows, Changes, Source, ⌘P, Run detail, project Settings, Settings window, Usage, Welcome, Onboarding, Clone, SSH folder |

## Decisions

| Topic | Decision |
| --- | --- |
| Tasks | Removed entirely. The chat record (today's `ProjectTask`, table `task`) stays and is renamed `Chat` |
| GitHub | All GitHub support is dropped: issues, polling, write-back, pull requests, sign-in, settings, onboarding step. Cloning by URL stays (plain `git`) |
| Inbox | The screen and the `InboxItem` record are removed. Everything the engine waits on you for becomes a request attached to a chat |
| Direct agent chats | Dropped. You only talk to the Lead. Agent sessions are read-only: "To change what Django Dev 1 does, tell the Lead in the chat." |
| Log column, status bar | Dropped completely. Logs stay in Run detail; the app's own output moves to the chat card's output panel |
| End of a run | Default end action is a local merge into the base branch. The done chat says "main is N commits ahead of origin" and offers **Push to origin**. There is no auto-push setting. `EndAction.pullRequest` is removed |
| Workflows | Feature delivery (default) and Quick fix end in a merge. **Spike** ("explore and report back; no merge") and **Review only** ("Reviewer reads a branch you name") end with `leave` |
| New chat | ⌘N opens "New chat in…", a project popover with a filter field. With one project it opens a chat in it straight away. App Settings names the default project |
| Footer | Alerts card (when there is one), Usage, Settings, and the weekly budget meter with its popover. No Workers icon |
| Run the app | The chat card's picker lists `main` and every worktree of the current chat. Switching restarts the app. Each worktree gets its own port |
| Run detail | Kept, reached from the chat card's Checks row and from "Open in Changes" links |
| Planned workers | The spec names the workers the Lead will start. You can add or remove workers in the spec editor before approving |
| Agents | Stay per project, with the New agent sheet. The Lead decides who works on a chat; you decide who exists and what they may do |
| First run | The stepped Welcome (Claude CLI → Appearance → Add your first project), then project onboarding (Folder → Run the app → Checks → Roles → Ready) |
| Theme | Dark, Light or System, chosen in Welcome and in Settings › General |
| Outside the window | Dock badge and a menu bar item count the chats that need you. One notification per ask, grouped by chat. Approvals and permissions carry their buttons. No notifications for progress |

## Tokens

From the "Tokens · dark and light" board. Text pairs pass 4.5:1; `text3` is only for placeholders and decoration.

| Token | Dark | Light |
| --- | --- | --- |
| desk | #050506 | #E8E8ED |
| win | #000000 | #FFFFFF |
| side | #0B0B0C | #F5F5F7 |
| raised | #111113 | #FFFFFF |
| card | #0F0F11 | #FFFFFF |
| menu | #1C1C1F | #FFFFFF |
| bubble | #1C1C1E | #EFEFF2 |
| code | #0B0B0C | #F5F5F7 |
| hair | rgba(255,255,255,0.07) | rgba(0,0,0,0.08) |
| hair2 | rgba(255,255,255,0.12) | rgba(0,0,0,0.14) |
| text | #F5F5F7 | #1D1D1F |
| text2 | rgba(235,235,245,0.62) | rgba(60,60,67,0.74) |
| text3 | rgba(235,235,245,0.4) | rgba(60,60,67,0.5) |
| sel | rgba(255,255,255,0.08) | rgba(0,0,0,0.06) |
| hover | rgba(255,255,255,0.05) | rgba(0,0,0,0.035) |
| fill | rgba(255,255,255,0.06) | rgba(0,0,0,0.05) |
| fill2 | rgba(255,255,255,0.12) | rgba(0,0,0,0.1) |
| tabOn | rgba(255,255,255,0.16) | #FFFFFF |
| priBg / priFg | #F2F2F2 / #111111 | #1D1D1F / #FFFFFF |
| link | #9CC6FF | #0066CC |
| accent | #0A84FF | #0A84FF |
| need | #FF9A5C | #C2410C |
| stuck | #FF8A80 | #C7000F |
| build | #7DB6FF | #0058B8 |
| review | #FFD60A | #946200 |
| done | #4BD97B | #17803A |
| needBg / needLine | rgba(255,122,47,0.08) / 0.4 | rgba(234,88,12,0.07) / 0.38 |
| stuckBg / stuckLine | rgba(255,69,58,0.09) / 0.4 | rgba(215,0,21,0.06) / 0.35 |
| buildBg | rgba(10,132,255,0.12) | rgba(0,102,204,0.08) |
| reviewBg | rgba(255,214,10,0.11) | rgba(202,138,4,0.1) |
| doneBg / doneLine | rgba(48,209,88,0.12) / 0.35 | rgba(23,128,58,0.08) / 0.3 |
| danger | #FF6B61 | #C7000F |
| live | #30D158 | #28A745 |
| shadow | 0 20px 50px rgba(0,0,0,0.7) | 0 18px 44px rgba(0,0,0,0.16) |
| scrim | rgba(0,0,0,0.55) | rgba(0,0,0,0.22) |

**Avatars and type**
- Role avatar colours: Lead #8E5BEA (eyes #E7D6FF), backend #26A866, frontend #2F97CF, CLI #CF6E50, review #E0952A. A failing worker's face turns #FF8A80.
- Fonts: SF Pro at 13 px base, JetBrains Mono for code, paths, branches and numbers, and Archivo 800 at 112 % width for display headings.
- The transcript is 14.5 px with 1.6 line height.

**Layout**
- Radii: window 22, composer and ⌘K 18, chat card 16, bubbles and popovers 14, rows 7–10.
- Sidebar 316 px. Chat card 300 px at the top right; the transcript and composer leave it 340 px.
- Transcript 760 px wide at most; composer 780 px at most.
- Worker panel 380 px.
- Below 1180 px the chat card folds into a pill in the chat header.

## What gets removed

| Feature | App | EnsembleCore |
| --- | --- | --- |
| Tasks | `Views/Tasks/`, `AppModel+Tasks`, `ProjectTab.tasks`, the Tasks sidebar section and its run rows, accept/dismiss flows | `TaskSource.github`, and the task fields only GitHub used (`sourceURL`, `externalNumber`, `repository`) |
| Inbox | `Views/Inbox/`, `AppModel+Inbox`, `SidebarItem.inbox`, the Inbox tool, menu, key-binding and ⌘K entries | `InboxItem`, `InboxKind`, `InboxStatus`, `InboxStore`, `InboxFeed`, and their use in `RunEngine`, `AgentWorkflowDriver`, `PermissionRequests`, `RequestThread`, `RunTimeline`, Quality and budget code |
| GitHub | `GitHubSettingsView`, the GitHub step in onboarding, PR links in Run detail and chat | `GitHub/` (auth, client, poller, remote, write-back, observer), `GitHubStore`, the GitHub token in `SecretStore`, `EndAction.pullRequest`, `Run.pullRequestURL`, the end step's "post a summary back to the source", `github` in the bundled workflow triggers |
| Direct agent chats | `DirectChatView`, `ChatTarget`, agent routing in `AppModel+Chat` | `Agents/DirectChat.swift`, the `directMessage` table |
| Log column | `LogColumn`, `ChatLogScope` | — |
| Status bar | `MainStatusBar` | — |
| Top run bar | `RunBar` (its app-runner logic moves into the chat card) | — |
| Per-project chat list | The project's Chat section, `RequestListView`, the "Chats" page | — |
| Not in the designs | Library panel, Organizer, the Quality screen | — |

Safety checks that only mention GitHub stay: the `gh` command risk rules, secret scanning for GitHub tokens, and `.github/workflows/**` as a protected path.

## Phases

Each phase ends with the app building, tests passing and the app usable.

1. **Remove GitHub, Tasks and direct agent chats (done, not yet run against a real database).**
    - Delete the code listed above for these three features.
    - Default end action becomes `merge`. Workflow files and project setup that say `pull_request` are read as `merge`, and a `github` trigger source is ignored.
    - `RunEngine.push(_:)` pushes the base branch after a local merge and records `Run.pushedAt`; it fails clearly when there is no `origin`.
    - Migration `v23-chat-first`: GitHub-sourced chats become ordinary chats; the `githubWriteBack` and `directMessage` tables are dropped; `run.pushedAt` is added.
2. **Replace the Inbox with chat requests (done).**
    - New record `ChatRequest` attached to a chat (and its run and agent when there is one). Fields: kind, title, body, options, state (open, answered, expired), answer, timestamps.
    - Kinds: question, choice, plan approval, permission, gate, checks out of retries, budget, loop limit, setup.
    - Each kind's answers are the buttons on its ask card (see Chat below). Expired requests offer "Ask again".
    - `RunEngine`, `AgentWorkflowDriver`, `PermissionRequests`, `RequestThread`, `RunTimeline`, Quality and budget code use it instead of `InboxItem`.
    - A request with no chat (an agent spawned by hand, a setup notice) goes to the project's most recent open chat, or starts a new chat titled after the request.
    - Migration copies open inbox items into requests, then drops the `inboxItem` table. Delete the Inbox UI.
3. **Remove the log column, status bar and top run bar (done).** Move the app-runner state that `RunBar` reads into a model the chat card can use, with a port per worktree and captured output per process.
4. **Core state for v5 (done).**
    - Rename `ProjectTask` to `Chat` across the code.
    - Chats can be renamed, marked done, dropped, reopened (worktrees come back if they still exist) and deleted.
    - `ChatStage`, worked out from the chat, its runs, its open requests and the current workflow step:
        - Needs you: an open request, including a run waiting on your final approval.
        - Stuck: a run failed or can't proceed.
        - Building.
        - In review: a review step is active.
        - Done: merged or closed.
        - Closed chats also record Done or Dropped.
    - Worker statuses are separate from the stage: working, waiting on you, queued, idle, done, stopped, stuck. A worker with no output for the step's limit (default 10 min, or the step's timeout if shorter) is stuck, and a "stuck" request is posted in its chat, so you are told and the chat shows as Stuck.
    - For each chat: its workers with a status line each, lines added and removed across its branches, a checks summary per check (format, lint, typecheck, tests, build) and round, and its worktrees.
    - An "unread" marker per chat that clears when you open it. The needs-you count clears when you answer, not when you look.
    - Spec front matter gains `workers:` (role and display name per worker, in start order) and a version number. The parser, the Lead's prompt and spec validation handle it. Saving an edited spec makes a new version; the Lead reads your edits before starting anyone. Rejecting a spec records it, and your next message is the reason.
    - The Lead's model and effort (Low, Medium, High) per chat. The model is applied to the Lead's next turn; the effort is stored and applied once the Claude CLI flag for it is confirmed. Messages sent while the Lead works already queue on its session.
    - Chats with no stage of their own (no run, no request, Lead quiet) are Idle.
5. **Theme and avatars (done).**
    - Replace `V4Style` with the tokens above, each with a dark and a light value.
    - Remove the forced `.preferredColorScheme(.dark)`. Appearance (Dark, Light, System) lives in Settings › General. It defaults to Dark until the screens are restyled for light in phase 9, then to System.
    - Add the robot-face avatars by role from the canvas's Agent avatars page.
6. **The new shell (done).**
    - Selection is chat-first in everything you see. Underneath, the per-project `tabs` and `leadSelections` stay as the state behind it; replacing them would not change any screen.
    - The output panel shows one stream for the running command; a tab per process needs the runner to split its output first.
    - **Sidebar:**
        - Top: New chat ⌘N, Add project, Search chats ⌘K.
        - Chats and Projects tabs. The Chats badge counts chats that need you or are stuck.
        - Chat rows show new-activity dots and a More menu: Rename, Mark as done, Drop chat, Copy link to chat, Delete…. Long titles wrap to two lines.
        - A collapsible "Closed" section with Reopen on hover; older closed chats are found through ⌘K.
        - Empty states for no chats and no projects.
        - Project cards (Crew: Agents, Workflows; Review: Changes, Source; Settings). The card's menu has Project settings, Reveal in Finder or Copy SSH path, New chat in this project, and Remove from Ensemble…. SSH cards show connecting, offline and failing states.
        - Footer: Usage, Settings, and the budget meter (near and over the limit), whose popover has spend by project, Change limits or Raise, and Open Usage.
    - **Navigation:** secondary screens replace the chat area. The top bar reads "‹ Back to <chat>" (or esc) with a project breadcrumb. The chat header shows the project, the title and a stage pill.
    - **Chat card:**
        - The machine, with an SSH chip for remote projects.
        - The worktree picker.
        - The run row: stopped, starting, running, failed with Retry, no run command with "Set up…", or tunnelled from the host.
        - The Output row, which opens the app output panel with a tab per process.
        - Changes +/−.
        - Checks: expandable rows with their status, opening Run detail.
        - The card hides for a new chat, on first run, and while the worker panel is open. Below 1180 px it folds into a header pill.
    - **⌘K palette:**
        - Recent chats, chat results with snippets, and commands: New chat, Add project, Run the app ⌘R, Stop the app ⌘., Open Changes ⇧⌘C, Go to file ⌘P, Settings ⌘,, Switch appearance.
        - No results offers "Ask the Lead about …" and "Search closed chats only".
7. **Transcript and composer (done, with gaps).**
    - Not built yet: the inline spec editor (Edit first opens the spec screen), collapsed older spec versions with New/Changed tags, the Lead's collapsible tool steps inside the transcript, the thinking timer, the 380 px worker panel (Open shows the agent's session), "Hand it to the Lead" and "Let the Lead try another way" on stuck cards, and "Always in this project" on permissions (answers stay scoped to the chat).
    - **New chat:** "What should we build?" with project and workflow chips and three starters: Fix a bug, Build a feature, Understand the code.
    - **The Lead:** header "Lead · <model>". States: thinking (with a timer), streaming (with collapsible tool steps), and working (live tool rows and a skeleton spec card).
    - **Spec card:**
        - Files, Interface, Out of scope, Done when and Verify, then "On approval I'll start …" with the workers.
        - Buttons: Approve & start, Edit first, Reject….
        - After approval: "Workers started", with each worker's branch.
        - Edit first opens an inline editor: each field, add or remove workers, then Save as vN and approve, Save as vN, or Cancel.
        - A new version collapses the old one and tags its sections New or Changed. A rejected spec dims.
    - **Ask cards**, each open, answered and expired:

        | Kind | Buttons |
        | --- | --- |
        | Question | Send answer · Let the Lead decide |
        | Choice | Answer (one option can be "Recommended") |
        | Plan approval | Approve plan · Edit first · Reject… |
        | Permission | Allow once · Always in this project · Deny |
        | Gate | Allow dependency · Ask for an alternative · Block |
        | Checks out of retries | Let the Lead try another way · Give it 2 more rounds · Open in Changes |
        | Budget | Raise to $X this week · Resume one worker · Wait until Monday |
        | Loop limit | Stop and summarise · Allow 20 more turns · Hand it to the Lead |
        | Setup | I started it, retry · Use a fake queue in tests · Project settings |

    - **Workers:**
        - A roster with Stop all, and hover actions (Open, Stop, Retry).
        - A stuck worker offers Nudge, Restart and Stop.
        - Clicking a worker opens the 380 px worker panel: role, model, branch, worktree, turns, spent, recent activity, files touched, Open session, Retry from start, Stop.
    - **In review:**
        - "Ready for your review" with the branch, summary, files, checks, cost and Reviewer notes.
        - Buttons: Approve & merge into main, Request changes, Open in Changes.
    - **Done:**
        - The merge summary and commits, "main is N commits ahead of origin", Close chat, Push to origin.
        - After the push: Copy commit and Close chat as done.
        - A closed chat shows a banner with Reopen.
    - **Composer:**
        - Placeholders change for a new chat and while the Lead works.
        - Attach; a workflow picker (Feature delivery, Quick fix, Spike, Review only); a model picker (Opus 5.5, Sonnet 5.5, Haiku 5.5) with effort.
        - Stop the Lead; Send, which becomes "Queue message" while the Lead works.
        - The `@` file picker, and the `/` command picker: /spec, /status, /stop, /retry, /budget, /compact.
        - Attachment chips, and the queued-messages list with Edit and remove.
8. **Alerts and outside the window (done).** Notification actions are Allow in this chat / Deny on permissions and Approve & start on proposals; Lead replies no longer notify by default. Install… and Locate… open Settings rather than separate flows (not designed yet).
    - Claude CLI missing, rate limit reached and SSH host disconnected, each as a sidebar alert card and as a banner in the chats they affect.
    - Their actions: Install…, Locate…, Fix in Settings, Use Sonnet 5.5, Reconnect, Details.
    - Dock badge and a menu bar item with the count of chats that need you.
    - Notifications once per ask, grouped by chat. Approve and Allow work from the notification without opening the app. Only asks, failures and finished work notify; Focus modes apply.
    - A Chat menu in the app's menu bar.
9. **Restyle the secondary screens and first run** in both themes (partly done):
    - Done: every screen's translucent fills, hairlines, panels, diff and code colours now come from tokens with a light value; the stepped Welcome (Claude CLI → Appearance → Add your first project); the read-only Agent session that points you to the chat.
    - Not done: the screen-specific layouts (Agents filters and "You talk to this one", Changes groups, Usage stats, the project settings pages, onboarding steps, Clone and SSH sheets as drawn), and a visual check of light mode. Appearance stays Dark by default until light mode has been looked at.
    - Agents (filters, the Lead tagged "You talk to this one") and the New agent sheet.
    - Read-only Agent session.
    - Workflows editor.
    - Changes, grouped: Needs your review, Waiting on workers, Merged · not pushed.
    - Source, and the ⌘P finder.
    - Run detail.
    - Project settings: Roles, Checks, Permissions, Docs, Skills, Workspaces, Remote host.
    - The Settings window (⌘,): General with Appearance, Open at login, notifications and the default project for ⌘N.
    - Usage.
    - The stepped Welcome, project onboarding, and the Clone and SSH folder sheets.
10. **Clean up and QA (cleanup done; QA against the canvas not run).** The QA pass needs the app driven on screen in both themes, which has not been done. Delete what's left of `Views/V4`, the Library panel, the Organizer and the Quality screen. Update `roadmap.md` and `mission.md` where they describe Tasks, the Inbox or GitHub. Run a QA pass against the v5 designs in both themes.

## Acceptance criteria

- [ ] No GitHub, Tasks, Inbox or direct-chat code is left in the app or EnsembleCore, and nothing in the UI mentions them
- [ ] A finished run merges into the base branch locally by default; Push to origin then pushes it and the chat shows the pushed commit
- [ ] Spike and Review only runs end without merging
- [ ] Every point where the engine waits on you shows as an ask card in its chat with the buttons above, and sets the chat's stage to Needs you
- [ ] A database with GitHub-sourced chats, direct messages and open inbox items migrates without errors; open inbox items become chat requests
- [ ] The Chats tab lists chats from every open project, newest activity first, with stage, project and workers; its badge counts the chats that need you or are stuck
- [ ] Chats can be renamed, marked done, dropped, reopened and deleted
- [ ] ⌘N opens the project popover, which filters as you type, and opens a chat straight away when there is only one project
- [ ] The chat card's picker lists `main` and each worktree of the current chat, and Start runs the app from the one picked, on local and SSH projects, with its output in the output panel
- [ ] A spec names its workers; the spec card shows them before approval and the editor can change them
- [ ] The Dock badge and menu bar item count chats that need you, and notifications let you approve or allow without opening the app
- [ ] Every screen works in dark and light, following the Appearance setting
- [ ] Every screen matches its v5 board in both themes
- [ ] EnsembleCore tests pass and the app builds with xcodebuild after every phase

## Out of scope

- Other task sources (Linear, Jira, Trello)
- Talking to agents other than the Lead
- Opening a chat beside another (⌘⏎ in ⌘K) until split view is designed

## Not designed yet

These states are still missing from the canvas. Each is built with the nearest designed pattern until the designer covers it.

- Dialogs behind Reject…, Request changes, Delete… and Remove from Ensemble…
- A merge conflict or failed local merge; a failed push; no `origin`
- Settings tabs other than General: Claude CLI, Models, Budget, Notifications, Advanced
- The flows behind Install…, Locate…, Details, and the run command's "Set up…"
- The menu bar item's menu, and the contents of the Chat menu
- Onboarding steps Folder, Run the app and Roles; the role editor and editing an agent
- What "Copy link to chat" links to; the results of "Search closed chats only" and "Ask the Lead about …"
- Empty Changes, Agents and monthly Usage; a Lead error inside the transcript

## Open questions

- [ ] Notification Approve acts on a spec without opening the app. Is that acceptable for specs, or only for permissions?
