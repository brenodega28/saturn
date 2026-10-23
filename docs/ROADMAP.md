# Ensemble — Roadmap

Ensemble is a macOS app for solo developers that runs a crew of AI coding agents on a project. You define **roles** (Tech Lead, Django Developer, QA…) and **workflows** (Task → Tech Lead plans → devs build in parallel → review → QA → you approve). Every coding agent works in its own git worktree, flags what a human must read as **pins**, and nothing reaches `main` without your approval.

This document is the build order for the MVP and what comes after. Each phase ends with something usable and a clear exit check.

---

## MVP scope

| In the MVP                                                           | After the MVP                         |
| -------------------------------------------------------------------- | ------------------------------------- |
| Solo developer, one machine                                          | Teams, shared config, multi-user      |
| Bring your own keys                                                  | —                                     |
| Claude Code as the only engine                                       | Codex, Gemini CLI and other providers |
| Task sources: Lead chat, GitHub Issues                               | Linear, Jira, Trello                  |
| One worktree per coding agent                                        | —                                     |
| Workflow ends in PR, local merge, pushed branch, or left in worktree | —                                     |
| Pinned agents with memory                                            | —                                     |
| Dark mode only                                                       | Light mode                            |
| macOS app                                                            | iOS companion app                     |

---

## Decisions

| Area              | Decision                                                                                                                                   | Why                                                                                                                           |
| ----------------- | ------------------------------------------------------------------------------------------------------------------------------------------ | ----------------------------------------------------------------------------------------------------------------------------- |
| App stack         | Swift 6 + SwiftUI, built in Xcode                                                                                                          | The most native macOS experience; the same language for the future iOS app                                                    |
| Minimum OS        | macOS 26 Tahoe                                                                                                                             | Native Liquid Glass for the glassy design and the newest SwiftUI APIs                                                         |
| Distribution      | Direct download: notarized, Developer ID–signed DMG, auto-updates with Sparkle                                                             | The App Store sandbox blocks spawning the `claude` CLI, running `git` and writing worktrees freely                            |
| Agent runner      | Drive the `claude` CLI headlessly from Swift (`Process`), reading its streaming JSON output; one process per agent, cwd = its worktree     | No Node runtime to bundle; uses the user's own Claude Code login or API key; resumable sessions and MCP support come for free |
| Engine boundary   | All logic in a UI-free Swift package, `EnsembleCore`; the app only renders state from it                                                   | Testable without the UI; the future iOS app reuses the models and talks to the Mac's engine                                   |
| Local storage     | SQLite through [GRDB](https://github.com/groue/GRDB.swift) for projects, tasks, runs, agents, usage                                        | Explicit migrations, safe concurrent access from the engine, no dependence on the UI layer                                    |
| Secrets           | Provider keys and GitHub tokens in the macOS Keychain                                                                                      | Never written to disk or to the repo                                                                                          |
| Config in git     | `.ensemble/` is committed; `.ensemble/memory/` and `.ensemble/local.yaml` are git-ignored                                                  | Roles and workflows are versioned with the code; personal state stays local                                                   |
| Pinned memory     | One Markdown file per pinned agent in `.ensemble/memory/<agent>.md`, loaded into its context at start                                      | Readable and editable in any editor as well as in the app's Memory panel                                                      |
| Pins              | Ensemble runs a local MCP server that every agent is given; agents call its `create_pin` tool                                              | Structured pins without parsing agent prose                                                                                   |
| GitHub            | Sign in with GitHub's OAuth device flow; open PRs and comment through the REST API                                                         | No local `gh` dependency                                                                                                      |
| GitHub write-back | Comment on the issue when a run starts and when it ends (with the PR link); set `ensemble:running` / `ensemble:done` labels                | Visible progress without noisy live edits                                                                                     |
| Worktrees         | Under `<repo>/.crew/<agent>/`, branch `crew/<agent>/<slug>`, excluded through `.git/info/exclude`                                          | Isolated per coding agent, invisible to the user's own git status                                                             |
| Mobile (later)    | iOS app is a remote control for the Mac: inbox, approvals, pins, run status. Agents always run on the Mac. Transport decided after the MVP | Keeps the engine in one place; the `EnsembleCore` boundary makes a remote client possible                                     |

---

## Core concepts

| Object       | What it is                          | Key fields                                                                                                                     |
| ------------ | ----------------------------------- | ------------------------------------------------------------------------------------------------------------------------------ |
| **Role**     | A reusable agent template           | name, icon, color, provider, model, system prompt, skills, docs, `edits_code`, permission profile, `can_spawn`, budget per run |
| **Agent**    | A running instance of a role        | role, run, step, worktree path, branch, status, tokens, cost, `pinned`, memory                                                 |
| **Task**     | One unit of work                    | title, body, source (`chat` \| `github`), source URL, workflow, status                                                         |
| **Workflow** | A graph of steps                    | trigger, steps, edges (with loop limits), end action, run budget                                                               |
| **Run**      | One task going through one workflow | task, workflow version, current step, step history, agents, branches, pins, cost, outcome                                      |
| **Pin**      | A spot in a diff a human must read  | run, agent, file, line range, title, tags, explanation, status (`open` \| `approved` \| `change_requested`)                    |

Rules that hold everywhere:

- A **lead** is not special. It is a role with `can_spawn: true`, placed on a workflow step.
- Any role with `edits_code: true` **always** gets its own git worktree and branch. There is no shared-folder mode.
- Read-only roles (reviewers, QA, leads) can read every worktree in their run but never write to them.
- QA runs against a separate, temporary worktree that merges the run's branches.

### Config on disk

Roles and workflows live in the repo so they are versioned and diffable. Runtime state lives in the app's data folder.

```
<repo>/.ensemble/
  roles/
    tech-lead.yaml
    django-developer.yaml
    qa-engineer.yaml
  workflows/
    feature-delivery.yaml
    hotfix.yaml
  docs.yaml            # which docs each role reads
  memory/              # pinned-agent memory, one .md per agent (git-ignored)
  local.yaml           # personal overrides (git-ignored)
<repo>/.claude/skills/ # skills, as Claude Code already expects
<repo>/.crew/<agent>/  # git worktrees (excluded via .git/info/exclude)

~/Library/Application Support/Ensemble/
  ensemble.sqlite      # projects, tasks, runs, agents, usage
  runs/<run-id>/       # transcripts and logs
```

### Code layout

```
Ensemble.xcodeproj
Ensemble/              # macOS app target: SwiftUI views, windows, menus
Packages/
  EnsembleCore/        # models, config loader, run engine, worktree manager,
                       # agent runner, pin MCP server, GitHub client, storage
  EnsembleUI/          # shared SwiftUI components (reused by iOS later)
```

---

## Phase 0 — Foundations

Goal: a native shell that can open a project and manage worktrees safely.

- [x] Xcode project (macOS 26, Swift 6 strict concurrency) with the `EnsembleCore` and `EnsembleUI` packages
- [x] CI on GitHub Actions: build and test `EnsembleCore` on every push
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

- [x] Role schema and loader for `.ensemble/roles/*.yaml`, with validation errors shown in the UI
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

- [x] Pin tool: expose an Ensemble MCP server to agents so they can create pins (file, lines, title, tags, explanation)
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
- [x] Write-back: comment when a run starts and when it ends with the PR link; set `ensemble:running` / `ensemble:done` labels
- [x] Run detail: workflow graph with the live step highlighted, timeline of steps and hand-offs, loops taken, agents, cost, logs; pause, resume, cancel, retry step
- [x] Global Inbox: agent questions, plan approvals, pin reviews and failures across all projects, actionable inline
- [x] macOS notifications for anything that lands in the Inbox

**Exit check:** label a GitHub issue, a run starts by itself, a question from an agent shows up in the Inbox and gets answered there.

## Phase 6 — Workflow editor

Goal: edit workflows visually; the YAML stays the source of truth.

- [x] Canvas editor reading and writing `.ensemble/workflows/*.yaml`
- [x] Palette of roles (not named agents) and step types; drag to add
- [x] Inspector: who does it, instructions, inputs, hand-offs, rules, limits
- [x] Trigger and End steps configurable in the canvas
- [x] Warning when editing a workflow with runs in flight (runs keep the version they started with)
- [x] Test run: dry run on a sample task with agents stubbed, showing the path taken

**Exit check:** build a Hotfix workflow (no lead, one dev, QA, you) in the editor and run it.

## Phase 7 — Pinned memory, usage and hardening

Goal: ready for daily use.

- [ ] Pinned agents: memory in `.ensemble/memory/<agent>.md`, loaded at start and updated at the end of each run; Memory panel to view, edit and clear; memory badge on cards
- [ ] Usage screen: spend by project, run, role and model; budgets per run and per month with alerts
- [ ] Settings › Workspaces: setup script per worktree (install deps, migrate DB), port allocation per worktree, cleanup policy
- [ ] Dev-server status and port shown in the Agent session panel
- [ ] Failure recovery across the board: rate limits, crashed agents, missing worktrees, failed setup scripts
- [ ] Templates on the Welcome screen include roles **and** a workflow (Django + React, Solo with review, Led squad)

**Exit check:** a week of real use on one project with no lost runs and no surprise spend.

**MVP is done when Phases 0–7 pass their exit checks.**

---

## After the MVP

- [ ] Linear, Jira and Trello as task sources, with status written back
- [ ] More providers: Codex, Gemini CLI; provider and model per role
- [ ] Permission profiles (read-only, edit with approval, auto-edit, full shell), network and secrets access per role
- [ ] Workflow version history
- [ ] Menu-bar extra: running agents and items waiting on you
- [ ] Light mode
- [ ] iOS companion app: inbox, approvals, pins and run status for the Mac's engine

---

## Risks to watch

| Risk                                                      | Mitigation                                                                                   |
| --------------------------------------------------------- | -------------------------------------------------------------------------------------------- |
| Multi-agent runs cost several times a single agent        | Cost shown everywhere; budget caps per step and run; a "small task" path that skips the lead |
| Parallel branches conflict at merge                       | Lead plans by file ownership; Changes flags overlapping files early                          |
| QA needs a running app per worktree                       | Setup scripts and port allocation per worktree                                               |
| Review and QA loops never converge                        | Loop limits per edge plus a run budget stop                                                  |
| Long runs interrupted by quit or sleep                    | Persisted run state and resume                                                               |
| Agents run shell commands as the user                     | Worktree isolation now; permission profiles after MVP                                        |
| The `claude` CLI's output format changes between versions | Parse it in one adapter inside `EnsembleCore`, pin a tested CLI version, warn on mismatch    |
