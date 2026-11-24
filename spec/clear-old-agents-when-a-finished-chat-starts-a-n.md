---
title: Clear old agents when a finished chat starts a new run
status: in-progress
version: 1
workers:
  - {role: builder, name: Builder, reason: "Core clearing logic, proposal result text, card line and tests are one connected change"}
  - {role: checker, name: QA, reason: Runs the test suite and the end-to-end follow-up-chat scenario on the merged work}
owner: ""
linked_runs: [6]
created: 2026-11-24
---

## Summary

When a chat keeps going after its earlier runs ended and the lead proposes a new run, the earlier runs' agents (builders, checkers, spawned agents; never the lead) are cleared so the Workers list only shows the new run. The proposal card tells the user up front which agents will be cleared, and the propose_run result tells the lead to mention it in its reply. Clearing happens when the user clicks Start run, not when the lead proposes, so dismissing a proposal keeps everything. Agents and their worktrees are deleted; their branches are kept so unmerged work is never lost.

## Interfaces

- AppDatabase / LeadChat: `previousRunAgents(taskId:) -> [Agent]` — non-lead agents from this chat's ended runs plus agents spawned by them or the lead, excluding archived ones
- LeadChat.start(_:in:) — before starting the engine run, deletes each previous-run agent's session via `runtime.delete(session, in:, git:, deleteBranch: false)` and inserts a `.note` LeadMessage: "Cleared N agents from earlier runs: Builder, Checker, …"
- AgentWorkflowDriver `.proposal` handling — the tool result adds: "Starting it clears N agents from earlier runs (names). Tell the user in your reply." when that list is non-empty
- ProposalCard (Ensemble/Views/Lead/RequestChat.swift) — while the proposal is open, shows a secondary line "Starting this run clears N agents from earlier runs" with the names in the help tooltip

## Out of scope

- Deleting the old agents' git branches
- Clearing agents when the lead only proposes, or when a proposal is dismissed
- Deleting the lead agent or its history
- Changing what happens on resolve/close (that already deletes everything)

## Acceptance criteria

- [ ] A chat with an ended run whose agents still exist: the lead's propose_run result names those agents and asks the lead to tell the user
- [ ] That proposal card shows "Starting this run clears N agents from earlier runs" while open; a chat with no earlier run agents shows no such line
- [ ] Clicking Start run removes the earlier agents and their worktrees; the Workers list then shows only the lead's new run agents
- [ ] The old agents' branches still exist after clearing
- [ ] A note "Cleared N agents from earlier runs: …" appears in the chat timeline
- [ ] Dismissing the proposal leaves every old agent in place
- [ ] The lead agent and its transcript survive
- [ ] New unit tests in LeadChatTests cover: clearing on start, no clearing on dismiss, lead kept, branches kept, proposal result text; `swift test` in Packages/EnsembleCore passes

## Verification

Run `swift test` in Packages/EnsembleCore. Then in the app: finish a chat with a small-task run, send a follow-up, let the lead propose a run, check the card warning and the lead's reply, click Start run, and confirm the Workers list only shows new agents, a clear note is in the timeline, and `git branch --list 'crew/*'` still lists the old branches.
