# Saturn — Roadmap

Saturn is a macOS app for solo developers that runs AI coding agents inside a verification harness: **agents propose, rails verify, humans approve** (see [mission.md](mission.md)). You define **roles** and **workflows** in the repo. Every coding agent works on a scoped task in its own git worktree and must pass the project's deterministic **checks** before its work reaches you. AI review flags what you must read as **pins**, and nothing reaches `main` without your approval.

This document is the build order for the MVP and what comes after. Each phase ends with something usable and a clear exit check. Phases 0–7 were planned before the mission was written and are kept as a record of what was built. Phases 8–10 bring the product in line with the mission, Phase 11 closes the gaps with the [design canvas](https://claude.ai/artifact/2rBPXF4C8fJi8RvWDGB9BD), Phase 12 moved the app into an IDE-style work-tool shell, and Phase 13 replaces that with the chat-first v5 app (see [app-v5-chat-with-the-lead.md](app-v5-chat-with-the-lead.md)).

---

## MVP scope

| In the MVP                                                           | After the MVP                         |
| -------------------------------------------------------------------- | ------------------------------------- |
| Solo developer, one machine                                          | Teams, shared config, multi-user      |
| Bring your own keys                                                  | —                                     |
| Claude Code as the only engine                                       | Codex, Gemini CLI and other providers |
| Work starts from a chat with the Lead                                | Linear, Jira, Trello                  |
| One worktree per coding agent                                        | —                                     |
| Workflow ends in a local merge you push, a pushed branch, or left in worktree | —                        |
| Pinned agents with memory                                            | —                                     |
| You approve every change                                             | Opt-in auto-merge for low-risk change classes with a proven record |
| Dark and light                                                       | —                                     |
| macOS app                                                            | iOS companion app                     |

---

## Decisions

| Area              | Decision                                                                                                                                   | Why                                                                                                                           |
| ----------------- | ------------------------------------------------------------------------------------------------------------------------------------------ | ----------------------------------------------------------------------------------------------------------------------------- |
| App stack         | Swift 6 + SwiftUI, built in Xcode                                                                                                          | The most native macOS experience; the same language for the future iOS app                                                    |
| Design reference  | The [design canvas](https://claude.ai/artifact/2rBPXF4C8fJi8RvWDGB9BD) defines every screen; new screens are designed there before they are built | One source for layout, copy and behavior; QA compares the app against it |
| App shell         | An IDE-style frame (toolbar, navigator, editor tabs, inspector, bottom panel, status bar) built on registries for panes, tabs and commands | Feels like Xcode or Android Studio; new features slot into existing panes instead of adding screens |
| Minimum OS        | macOS 26 Tahoe                                                                                                                             | Native Liquid Glass for the glassy design and the newest SwiftUI APIs                                                         |
| Distribution      | Direct download: notarized, Developer ID–signed DMG, auto-updates with Sparkle                                                             | The App Store sandbox blocks spawning the `claude` CLI, running `git` and writing worktrees freely                            |
| Agent runner      | Drive the `claude` CLI headlessly from Swift (`Process`), reading its streaming JSON output; one process per agent, cwd = its worktree     | No Node runtime to bundle; uses the user's own Claude Code login or API key; resumable sessions and MCP support come for free |
| Engine boundary   | All logic in a UI-free Swift package, `SaturnCore`; the app only renders state from it                                                   | Testable without the UI; the future iOS app reuses the models and talks to the Mac's engine                                   |
| Local storage     | SQLite through [GRDB](https://github.com/groue/GRDB.swift) for projects, tasks, runs, agents, usage                                        | Explicit migrations, safe concurrent access from the engine, no dependence on the UI layer                                    |
| Secrets           | Provider keys in the macOS Keychain                                                                                                        | Never written to disk or to the repo                                                                                          |
| Config in git     | `.saturn/` is committed; `.saturn/memory/` and `.saturn/local.yaml` are git-ignored                                                  | Roles and workflows are versioned with the code; personal state stays local                                                   |
| Pinned memory     | One Markdown file per pinned agent in `.saturn/memory/<agent>.md`, loaded into its context at start                                      | Readable and editable in any editor as well as in the app's Memory panel                                                      |
| Pins              | Saturn runs a local MCP server that every agent is given; agents call its `create_pin` tool                                              | Structured pins without parsing agent prose                                                                                   |
| Delivery          | No GitHub integration: a finished run merges into the base branch on this Mac, and you push it from the chat | You review and land work locally; pushing stays your call |
| Worktrees         | Under `<repo>/.crew/<agent>/`, branch `crew/<agent>/<slug>`, excluded through `.git/info/exclude`                                          | Isolated per coding agent, invisible to the user's own git status                                                             |
| Verification      | Saturn runs the project's checks itself, in the agent's worktree, outside the agent's session; results go back to the agent as feedback   | The agent can't skip, fake or reinterpret a check it doesn't run; a separate verification runtime is what stopped agents gaming builds elsewhere |
| Agent hooks       | Each worktree gets Claude Code hooks: lint after every edit, block edits to protected paths, block "done" while checks fail                | Enforcement in deterministic tools instead of prompt text                                                                     |
| Instructions      | One lean `AGENTS.md` at the repo root (`CLAUDE.md` points to it); occasional know-how goes in skills                                       | Context files buy consistency and lower cost, not capability; bloat makes agents ignore them                                  |
| AI review         | Reviewer roles comment through pins; they never approve and never block a run on their own                                                | Precision-tuned commenters help; rigid LLM gates block valid changes                                                          |
| Mobile (later)    | iOS app is a remote control for the Mac: chats that need you, approvals, pins, run status. Agents always run on the Mac. Transport decided after the MVP | Keeps the engine in one place; the `SaturnCore` boundary makes a remote client possible                                     |

---

## Core concepts

| Object       | What it is                          | Key fields                                                                                                                     |
| ------------ | ----------------------------------- | ------------------------------------------------------------------------------------------------------------------------------ |
| **Role**     | A reusable agent template           | name, icon, color, provider, model, system prompt, skills, docs, `edits_code`, permission profile, `can_spawn`, budget per run |
| **Agent**    | A running instance of a role        | role, run, step, worktree path, branch, status, tokens, cost, `pinned`, memory                                                 |
| **Chat**     | One conversation with the Lead and its work | title, body, workflow, status, Lead model, close reason                                                                |
| **Workflow** | A graph of steps                    | trigger, steps, edges (with loop limits), end action, run budget                                                               |
| **Run**      | One task going through one workflow | task, workflow version, current step, step history, agents, branches, pins, cost, outcome                                      |
| **Pin**      | A spot in a diff a human must read  | run, agent, file, line range, title, tags, explanation, status (`open` \| `approved` \| `change_requested`)                    |
| **Check**    | A deterministic command that judges work | name, command, kind (format, lint, typecheck, test, scan), protected paths, timeout                                     |

Rules that hold everywhere:

- A **lead** is not special. It is a role with `can_spawn: true`, placed on a workflow step.
- Any role with `edits_code: true` **always** gets its own git worktree and branch. There is no shared-folder mode.
- Read-only roles (reviewers, QA, leads) can read every worktree in their run but never write to them.
- QA runs against a separate, temporary worktree that merges the run's branches.
- Work reaches human review only after its checks pass. Check retries are capped; after the cap the work comes back to you in its chat, not back into the loop.
- Existing tests and other protected paths are read-only to coding agents. Agents may add tests; any change to a protected file is pinned for separate review.
- AI review comments; only you approve.

### Config on disk

Roles and workflows live in the repo so they are versioned and diffable. Runtime state lives in the app's data folder.

```
<repo>/.saturn/
  roles/
    tech-lead.yaml
    django-developer.yaml
    qa-engineer.yaml
  workflows/
    feature-delivery.yaml
    hotfix.yaml
  checks.yaml          # format, lint, typecheck, test and scan commands; protected paths
  docs.yaml            # which docs each role reads
  memory/              # pinned-agent memory, one .md per agent (git-ignored)
  local.yaml           # personal overrides (git-ignored)
<repo>/AGENTS.md       # lean shared instructions; CLAUDE.md points here
<repo>/.claude/skills/ # skills, as Claude Code already expects
<repo>/.crew/<agent>/  # git worktrees (excluded via .git/info/exclude)

~/Library/Application Support/Saturn/
  saturn.sqlite      # projects, tasks, runs, agents, usage
  runs/<run-id>/       # transcripts and logs
```

### Code layout

```
Saturn.xcodeproj
Saturn/              # macOS app target: SwiftUI views, windows, menus
Packages/
  SaturnCore/        # models, config loader, run engine, worktree manager,
                       # agent runner, pin MCP server, GitHub client, storage
  SaturnUI/          # shared SwiftUI components (reused by iOS later)
```

---

## Phase 0 — Foundations

Goal: a native shell that can open a project and manage worktrees safely.

- [x] Xcode project (macOS 26, Swift 6 strict concurrency) with the `SaturnCore` and `SaturnUI` packages
- [x] CI on GitHub Actions: build and test `SaturnCore` on every push
- [ ] Developer ID signing, notarization and a Sparkle update feed for dev builds
- [x] App shell: sidebar (Inbox, Projects, Usage), project tabs (Tasks, Lead, Agents, Changes, Workflows, Settings), ⌘K palette stub
- [x] Welcome screen: Open Folder, Clone Repository, recent projects
- [x] First-run checks: `git` and `claude` installed, provider key entered and stored in the Keychain
- [x] Persistence layer (GRDB) with migrations for projects, tasks, runs, agents, usage
- [x] **Worktree manager**: create, list, remove worktrees under `.crew/`; branch naming `crew/<agent>/<slug>`; add `.crew/` to `.git/info/exclude`; recover orphaned worktrees on launch

**Exit check:** open a repo, create and delete three worktrees from a debug menu, quit and relaunch with state intact.

## Phase 1 — One agent, end to end

Goal: run a single Claude Code agent in its own worktree and watch it work.

- [x] Agent runner: spawn the `claude` CLI headlessly with `Process` inside a worktree, parse its streaming JSON events, persist the transcript, keep the session id for resume
- [x] Track tokens and cost per agent from the stream
- [x] Pause, stop, restart an agent; survive app quit (mark as interrupted, offer resume)
- [x] Agent session screen: transcript, tool calls, inline diffs, message box
- [x] Right panel: worktree path, branch, commits ahead, changed files, Reveal in Finder, Open in Editor, Terminal
- [x] **Take over**: pause the agent and hand the worktree to the user

**Exit check:** type a task, one agent implements it in its worktree, tests run, you see the diff and the cost.

## Phase 2 — Roles and spawning

Goal: agents come from roles, and several run in parallel.

- [x] Role schema and loader for `.saturn/roles/*.yaml`, with validation errors shown in the UI
- [x] Settings › Roles: role editor with a live preview of the context the agent will load (prompt, skills, docs, token sizes)
- [x] Settings › Documentation and Skills: link repo files or write prompts; who reads what; SKILLS.md sync; missing-skill warning
- [x] Spawn sheet: pick a role, a count, optionally Pin; "Will add" preview
- [x] Parallel agents, each in its own worktree, with project caps on concurrent agents
- [x] Agents tab: cards grouped by run, plus Pinned and Idle groups; status, model, cost, current step; Pause / Stop / Restart / Pin

**Exit check:** spawn two Django developers and one React developer from roles; all three work in parallel in separate worktrees.

## Phase 3 — Workflow engine (headless)

Goal: workflows run from YAML before there is a visual editor.

- [x] Workflow schema: trigger, steps, edges, end action, budget
- [x] Step types: **Agent**, **Spawn** (lead's plan → one agent per task, up to a cap), **Condition** (labels, paths, diff size), **Human approval**, **Notify**
- [x] Per-step settings: timeout, max loops, budget cap, on-failure action (retry, ask human, fail run)
- [x] Hand-off protocol: how a step's output (plan, verdict, test report) is passed to the next step
- [x] Loop-backs: "changes requested" and "bug found" route to the author's step; stop at the loop limit and ask the user
- [x] Run state machine with persistence; resume after crash or quit
- [x] Lead chat: talk to a lead role, create a task, pick a workflow; plan card with editable tasks (reorder, change role or count, delete) before Approve
- [x] Ship a default **Feature delivery** workflow: Plan → Spawn → Build → Lead review → QA → You approve → End

**Exit check:** a request in Lead chat runs the full default workflow, including one review loop, without touching the UI except to approve.

## Phase 4 — Review, pins and output

Goal: the human approval step is fast and trustworthy.

- [x] Pin tool: expose a Saturn MCP server to agents so they can create pins (file, lines, title, tags, explanation)
- [x] Changes tab: diffs across the run's branches, unified/split view, plain-language summary per file, generated files collapsed
- [x] Pins: Looks right / Request change / Ask the agent; "Request change" re-enters the author's workflow step
- [x] "Reviewed by" marker per file (lead, reviewer) and viewed state
- [x] Conflict detection: files touched by more than one branch, flagged before merge
- [x] Bottom bar: "N open pins · Approve all & continue run"
- [x] End actions: open GitHub PR, merge locally, push branch, or leave in worktree; post a summary to Lead chat; clean up worktrees

**Exit check:** a two-agent run ends in a PR on GitHub after you approve its pins in Changes.

## Phase 5 — Tasks, GitHub Issues and the Inbox

Goal: work arrives on its own, and nothing waiting on you gets missed.

- [x] Tasks tab: Incoming, Running, Waiting on you, Done, Failed; accept, dismiss, choose workflow
- [x] GitHub integration: device-flow sign-in, pick repo, label filter → workflow mapping (polling first; webhooks need a server)
- [x] Write-back: comment when a run starts and when it ends with the PR link; set `saturn:running` / `saturn:done` labels
- [x] Run detail: workflow graph with the live step highlighted, timeline of steps and hand-offs, loops taken, agents, cost, logs; pause, resume, cancel, retry step
- [x] Global Inbox: agent questions, plan approvals, pin reviews and failures across all projects, actionable inline
- [x] macOS notifications for anything that lands in the Inbox

**Exit check:** label a GitHub issue, a run starts by itself, a question from an agent shows up in the Inbox and gets answered there.

## Phase 6 — Workflow editor

Goal: edit workflows visually; the YAML stays the source of truth.

- [x] Canvas editor reading and writing `.saturn/workflows/*.yaml`
- [x] Palette of roles (not named agents) and step types; drag to add
- [x] Inspector: who does it, instructions, inputs, hand-offs, rules, limits
- [x] Trigger and End steps configurable in the canvas
- [x] Warning when editing a workflow with runs in flight (runs keep the version they started with)
- [x] Test run: dry run on a sample task with agents stubbed, showing the path taken

**Exit check:** build a Hotfix workflow (no lead, one dev, QA, you) in the editor and run it.

## Phase 7 — Pinned memory, usage and hardening

Goal: ready for daily use.

- [x] Pinned agents: memory in `.saturn/memory/<agent>.md`, loaded at start and updated at the end of each run; Memory panel to view, edit and clear; memory badge on cards
- [x] Usage screen: spend by project, run, role and model; budgets per run and per month with alerts
- [x] Settings › Workspaces: setup script per worktree (install deps, migrate DB), port allocation per worktree, cleanup policy
- [x] Dev-server status and port shown in the Agent session panel
- [x] Failure recovery across the board: rate limits, crashed agents, missing worktrees, failed setup scripts
- [x] Templates on the Welcome screen include roles **and** a workflow (Django + React, Solo with review, Led squad)

**Exit check:** a week of real use on one project with no lost runs and no surprise spend.

## Phase 8 — Verification rails

Goal: correctness comes from what the agent must pass, not from what it is told.

- [x] Check schema and loader for `.saturn/checks.yaml`: one command each for format, lint, typecheck and test, with protected-path globs and timeouts; validation errors shown in the UI
- [x] Check detection on project open: suggest commands from the repo (package scripts, Makefile, test runners); warn when a project has no runnable test check
- [x] Harness health: run every check in a fresh worktree after the setup script; flag missing dependencies, network or credentials before any agent starts
- [x] **Check** step type: Saturn runs the checks in the agent's worktree, outside the agent's session, and hands failures back to the author as feedback
- [x] Capped retries per check step (default 2 rounds); after the cap the run goes to the Inbox with the failing output
- [x] Context hygiene: after two failed correction rounds, restart the agent with a fresh session and a summary instead of piling on more context
- [x] Agent hooks written into each worktree: format and lint after every edit, block edits to protected paths, block "done" while checks fail
- [x] Protected tests: existing tests are read-only to coding agents; new tests are allowed; any change to a protected file becomes a pin tagged `test-change`
- [x] Test-first option for bug fixes: the agent first commits a failing test that reproduces the issue; the check step confirms it fails before the fix and passes after

**Exit check:** an agent that tries to edit an existing test is blocked; a branch whose tests fail never reaches Changes; a task that stays red after two rounds lands in the Inbox with the failing output.

## Phase 9 — Scope, gates and review

Goal: you review small, verified changes, and AI review points you to what matters without getting in the way.

- [x] Plan format: a short spec naming files, interfaces, out-of-scope items, acceptance criteria and a verification step; skipped when the task fits in one sentence; you review the plan before building
- [x] Size guard: warn when a task's diff passes a line or file threshold and offer to split it
- [x] Pre-review gates: secret scanning, new-dependency check (the package exists in its registry and you approve it), duplication and complexity thresholds against the base branch
- [x] Evidence for performance and UI changes: benchmarks, screenshots or recorded runs attached to the run and shown in Changes
- [x] AI review as commenter: reviewer roles create pins with a confidence score; low-confidence and suppressed categories are hidden; "no comments" is a valid result
- [x] Reviewer verdicts are advisory: findings go to the author for one fix round at most, then to you; a reviewer can't block a run on its own
- [x] Risk tiers: classify paths and labels (core/security, standard, low-risk); Changes orders review by tier and asks for a line-by-line read on core/security files
- [x] Review capacity cap: no new run starts building while more than N changes are waiting on you (per project setting)
- [x] New default workflows and templates built on the mission pipeline: Scope → Plan (optional) → Build → Checks → Gates → AI review → You approve → End

**Exit check:** a feature request becomes a plan you approve, then a small green branch with AI pins and gate results, and you approve it in Changes without reading files outside its risk tier.

## Phase 10 — Close the loop and measure

Goal: the harness gets better every week, and you can see whether it's working.

- [x] Lean `AGENTS.md`: create or import on setup, point `CLAUDE.md` to it, warn when it grows past about one page
- [x] Encode a correction: from a pin or a "Request change", propose one line for `AGENTS.md`, a hook or a check, and commit it with your approval
- [x] Repeated-mistake detection: when the same correction is made twice, Saturn suggests encoding it
- [x] Quality screen: PR size, time to approve, check failure rate and retries, rework and revert rate, duplication and complexity trend, cost per approved change; no "lines generated" or AI-share metrics
- [x] Weekly summary in the Inbox: what moved, which rules were added, which checks failed most

**Exit check:** a week of real use on one project: no lost runs, no surprise spend, no unverified change reached review, and the quality screen shows PR size and review time holding steady.

## Phase 11 — Design parity

Goal: the app matches the design canvas and works as one complete toolkit.

- [x] Extend the canvas to the mission's new surfaces: check and gate results, `test-change` pins, risk tiers, the quality screen, and plan specs
- [x] Project onboarding in five steps: scan the folder (stack, test runners, database, GitHub remote) to suggest roles, skills and checks; name, base branch and branch prefix; task sources; roles, including custom roles with a forced skill; lead, default workflow, end action and "approve plans first"; spending, concurrency and permissions; docs every agent reads; summary, then open Chat. "Skip and use recommended setup" at any step
- [x] New Project (⌘N) on the Welcome screen, next to Open Folder and Clone Repository
- [x] Permission profiles editor in Settings: per profile, Allow / Ask / Never for editing files, running shell commands, network, installing packages and git push; "Ask" sends a request to the Inbox; agents never push to the base branch
- [x] Command palette: search runs, agents and files; actions (new task, message an agent, approve pins, spawn, test-run a workflow, pause all agents); unmatched text goes to the lead as a new task; `>` filters to commands; ⌘↵ opens in a new window
- [x] Shortcuts: ⌘N new task, ⌘J message an agent, ⇧⌘A spawn, ⇧⌘P pause all agents, ⌘1… for sidebar sections
- [x] Conflict resolution in Changes: ask the lead to combine, keep one branch's version, or open in a merge tool
- [x] Workflow version history: save as a new version, list versions with their change note, run count and average cost
- [x] Workflow step options: reuse pinned agents of the same role in Spawn steps; daily reminder on human approval steps; post a summary back to the task's source at the end
- [x] Agents: pause all agents in a project; idle unpinned agents are removed after a set time
- [x] Weekly budgets alongside monthly ones, matching the canvas's weekly cap and sidebar meter
- [x] Design QA pass: every screen checked against the canvas, mismatches filed as issues

**Exit check:** a new user goes from Welcome through onboarding to an approved change, and every screen on the way matches the canvas.

## Phase 12 — Work-tool shell

Goal: Saturn feels like Xcode or Android Studio: one fixed frame of panes around an editor, where new features arrive as tabs in existing panes instead of new screens. The layout comes from the shell redesign in the design canvas; that redesign is done before this phase starts.

- [x] Extension registries in the app for navigator tabs, inspector tabs per selection type, bottom panel tabs, editor tab types, toolbar items and activity sources, status bar items, and commands; menus, the ⌘K palette and key bindings all read from the command registry
- [x] Frame: toolbar, navigator, editor area, inspector, bottom panel and status bar; every pane can be shown, hidden and resized, with state saved per window
- [x] Toolbar: scheme selector (project ▸ workflow ▸ base branch), start ▶ (⌘R) and stop ■ (⌘.), activity viewer with a popover of background work, pane toggles
- [x] Navigator tabs: Workspace (today's multi-project sidebar), Runs, Agents, Source, Source control, Pins, Checks, Problems, Find; each scoped to one project or all
- [x] Editor area: tabs for chats, runs, files, diffs, workflows and reports; split view; open in a new window; jump bar breadcrumbs with a menu per segment; back and forward history
- [x] Existing screens moved into the frame as editor tabs, with their per-screen chrome removed
- [x] Inspector that follows the selection: agent (details, context, memory, workspace, cost), file (info, history, pins, risk tier), workflow step, run (summary, budget, branches, outcome); the Agent session panel and Workflows inspector move here
- [x] Bottom panel: Log (live, filterable by agent, step and level), Terminal in any worktree, Checks output, Problems table, Servers (dev servers and ports), Activity (clones, syncs, setup scripts, polling)
- [x] Status bar: branch and worktree, agents working, check state, `claude` CLI version and health, rate-limit and offline warnings, weekly spend; each item opens its pane
- [x] Full menu bar (File, Edit, View, Navigate, Agent, Run, Review, Workflow, Window, Help) and context menus on agents, files, pins and runs
- [x] App-wide Settings window (⌘,): accounts, engines, key bindings, notifications, locations, updates, editor font
- [x] Organizer window (⇧⌘1) across projects: runs, usage, quality, the role and workflow template library, failed runs
- [x] Library panel (⇧⌘L): roles, skills, step types and prompt snippets to drag into workflows and chat
- [x] Key bindings editor
- [x] Problems and Checks navigators wired to the Phase 8–10 data (failed checks, gate findings, config errors, missing skills)

**Exit check:** a full Refunds v2 run is started, followed, reviewed and approved without leaving the frame. The Log, Terminal, Checks and Problems panels, the inspector and the menus all work. A new navigator tab can be added by registering it, with no changes to the shell.

## Phase 13 — v5: chat with the Lead

Goal: the app is chat-first. You talk only to the Lead, it starts the workers, and everything that needs you shows up in that chat. The plan, decisions and what is still open are in [app-v5-chat-with-the-lead.md](app-v5-chat-with-the-lead.md).

- [x] Remove GitHub, Tasks and direct agent chats; runs merge locally and you push
- [x] Replace the Inbox with requests inside each chat
- [x] Drop the log column, status bar, run bar, Library panel, Organizer and Quality screen
- [x] Chat stages, worker states, chat checks, and specs that name their workers
- [x] v5 tokens in dark and light, robot avatars, the chat-first sidebar, chat card, transcript and composer
- [x] Alerts, Dock badge, menu bar item, actionable notifications and a Chat menu
- [ ] The screens and states the spec lists as not built or not designed yet

**Exit check:** from the chat list, a request goes from a spec through workers and checks to a local merge and a push without leaving the chat, in dark and in light.

**MVP is done when Phases 0–12 pass their exit checks.** Phase 13 supersedes the Phase 5 Inbox and GitHub work and the Phase 12 frame.

---

## After the MVP

- [ ] Website and docs (the canvas's Website page), with copy updated to the mission's message

- [ ] Opt-in auto-merge for low-risk change classes (docs, for example) once they have a clean track record
- [ ] SAST and mutation testing as gates
- [ ] Linear, Jira and Trello as task sources, with status written back
- [ ] More providers: Codex, Gemini CLI; provider and model per role
- [ ] Secrets access per role
- [ ] Menu-bar extra: running agents and items waiting on you
- [ ] iOS companion app: chats that need you, approvals, pins and run status for the Mac's engine

---

## Risks to watch

| Risk                                                      | Mitigation                                                                                   |
| --------------------------------------------------------- | -------------------------------------------------------------------------------------------- |
| Multi-agent runs cost several times a single agent        | Cost shown everywhere; budget caps per step and run; a "small task" path that skips the lead |
| Parallel branches conflict at merge                       | Lead plans by file ownership; Changes flags overlapping files early                          |
| QA needs a running app per worktree                       | Setup scripts and port allocation per worktree                                               |
| Review and QA loops never converge                        | Loop limits per edge plus a run budget stop; capped check retries hand back to you           |
| Agents game the checks (edit tests, hard-code outputs)    | Checks run outside the agent; protected tests; test changes pinned for separate review       |
| Review becomes the bottleneck                             | Size guard, review capacity cap, risk tiers, pins that point to what matters                 |
| Noisy AI review trains you to ignore it                   | Confidence threshold, suppressed categories, comments only; track how many pins you act on   |
| Code quality drifts (duplication, complexity, warnings)   | Duplication and complexity gates; trends on the quality screen                               |
| Instruction files bloat and get ignored                   | One-page `AGENTS.md` warning; move enforced rules into hooks and checks                      |
| Hallucinated or malicious dependencies                    | New-dependency check against the registry; you approve every new package                     |
| Long runs interrupted by quit or sleep                    | Persisted run state and resume                                                               |
| Agents run shell commands as the user                     | Worktree isolation; permission profiles with Allow / Ask / Never per capability (Phase 11)    |
| The `claude` CLI's output format changes between versions | Parse it in one adapter inside `SaturnCore`, pin a tested CLI version, warn on mismatch    |
