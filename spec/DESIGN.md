# Saturn v5 — design brief

Work in the Saturn design canvas: https://claude.ai/artifact/2rBPXF4C8fJi8RvWDGB9BD

The reference is the board **App v5 · Chats with the Lead** (`V5.dc.html`) on the page **App v5 · Black**. It is the only v5 screen so far: one dark window with an open chat in which the Lead has written a spec. Everything listed below is missing and has to be designed before it can be built. Keep the v5 board as the source of the look, and add the new boards next to it on the v5 page (or on new v5 pages, grouped by area).

## What v5 is

Saturn is a macOS app that runs AI coding agents. In v5 you only talk to the **Lead**. The Lead writes a spec, you approve it, and the Lead starts **workers** (other agents, each in its own git worktree and branch). Deterministic **checks** run on each worker's work before you see it. When you approve, the work is merged into the base branch locally, and you can push it afterwards.

The window is chat-first:

- **Sidebar.** New chat, Add project, Search chats ⌘K. Tabs: **Chats** (every project's chats in one list, newest activity first) and **Projects** (a card per project, holding Agents, Workflows, Changes, Source and Settings). Footer: Usage, Settings and the weekly budget.
- **Chat.** Breadcrumb (project / chat title), the transcript, and the composer.
- **Chat card**, floating at the top right of the chat: the machine (local or SSH host), the worktree to run, Start/Stop with the port, Changes (+/−) and Checks.

## Removed from the app (don't design these)

- Tasks screen and the issue queue
- Inbox screen. Everything that used to go to the Inbox now appears in its chat
- GitHub: issues, pull requests, sign-in, settings
- Direct chats with agents other than the Lead
- The live log column
- The bottom status bar
- The run bar across the top
- The Workers icon in the sidebar footer (Agents stay on each project card)

## Facts to design with

- **Chat stages**: Needs you, Stuck · needs you, Building, In review, Done. The v5 board's colours are orange `#FF9A5C`, red `#FF8A80`, blue `#7DB6FF`, yellow `#FFD60A` and green `#4BD97B`.
- **Worker roles and avatar colours** (robot faces from the **Agent avatars** page): lead `#8E5BEA`, backend `#26A866`, frontend `#2F97CF`, CLI `#CF6E50`, review `#E0952A`.
- **Things the engine can ask you, each shown as a card in its chat**: a question (free text, or a choice from options), plan or spec approval, a permission (edit files, run a shell command, network, install packages, git push), a gate (for example, a new dependency), checks out of retries, budget reached, loop limit reached, a setup notice.
- **Projects** are local folders or folders on an SSH host.
- **Run the app**: the worktree picker lists `main` and every worktree that belongs to the current chat's workers.
- **Specs name their workers** before approval ("On approval I'll start Django Dev 1, React Dev, then the Reviewer").
- **Dark v5 surfaces**: window `#000`, sidebar `#0B0B0C`, cards and composer `#111113`, chat card `#0F0F11`, user bubble `#1C1C1E`, hairlines white at 7–10%, text `#F5F5F7`, secondary text `rgba(235,235,245,0.62)`, selection white at 8%, primary button a white pill `#F2F2F2` with dark text.

## What to design

Every screen and state needs a **dark and a light** version.

### 1. Theme
1. A light version of every v5 surface, colour and state: the window, sidebar, cards, pills, stage colours, avatars and selection.
2. A token set that names each colour by its role (surface, raised surface, hairline, text, secondary text, accent, stage colours, danger, success), with its dark and light value.

### 2. Sidebar
3. **New chat project picker**: a dropdown with a filter field. Show it open, while filtering, with no match, and with a single project.
4. **Empty states**: the Chats tab with no chats, and first launch with no projects.
5. **Closing a chat**: how you mark a chat done or dropped, where closed chats live, and how you reopen one.
6. **Chat row**: hover, context menu (rename, close, delete), long titles, and a marker for new activity.
7. **Project card**: expanded and collapsed, context menu (remove, reveal in Finder, settings), and an SSH project that is connecting, offline or failing.
8. **Footer budget**: near the limit, over the limit, and what clicking it opens.
9. **⌘K search**: chat results, commands and no results (the current Palette board is the old style).

### 3. Navigation
10. How a secondary screen (Agents, Workflows, Changes, Source, Settings, Usage, Run detail) sits in the v5 window, and how you get back to the chat.

### 4. Chat card
11. The worktree picker open: `main` and each of the chat's worktrees, with its worker and status.
12. Run states: starting, running, failed to start, no run command configured, a remote project.
13. Where the running app's output goes, now that the log column is gone.
14. Checks: not started, running, round N failed, passed. A chat with no workers yet.
15. Narrow windows, where the card would overlap the transcript.

### 5. Chat
16. A new chat before its first message: empty state, which project, which workflow.
17. The Lead thinking, streaming a reply, and working (reading files, writing the spec).
18. **Spec card**: the "Edit first" flow and the spec editor, a new version of a spec, a rejected spec.
19. A card for each thing the engine can ask (see "Facts to design with"), and the answered and expired version of each.
20. **Worker roster**: what clicking a worker opens, stopping or retrying a worker, a stuck worker.
21. **In review**: what the review hand-off looks like and how you approve it.
22. **Done**: the final state after a local merge, with the Push action, and after a push.

### 6. Composer
23. The model picker, the workflow picker, the `@` file picker, the `/` command picker, attachments, and messages queued while the Lead is busy.

### 7. Alerts
24. Where these show, now that the status bar is gone: the Claude CLI missing or unhealthy, a rate limit hit, an SSH host disconnected.
25. "Needs you" outside the window: the dock badge and system notifications.

### 8. Secondary screens, restyled to v5
26. Agents and the Agent session, the New agent sheet.
27. Workflows editor.
28. Changes (review and diffs).
29. Source reader and the ⌘P go-to-file finder.
30. Run detail (graph, timeline, logs).
31. Project Settings: Roles, Checks, Permissions, Docs, Skills, Workspaces, Remote host.
32. The app Settings window (⌘,), including a Dark / Light / System appearance choice.
33. Usage.
34. Welcome and first run, project Onboarding (without the GitHub step), the Clone repository sheet, the SSH Remote folder sheet.

## Ground rules

- Match the v5 board: SF Pro Display for display text, SF Pro for UI text, SF Mono for code, paths, branches and numbers; the same radii, spacing and pill buttons.
- Use realistic content in the same style as the v5 board (shopfront, billing-service, docs-site; Refunds v2, Order export CSV).
- Don't add anything listed under "Removed from the app".
- Window size 1600×1000, as on the v5 board.
