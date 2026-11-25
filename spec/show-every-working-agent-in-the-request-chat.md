---
title: Show every working agent in the request chat
status: done
owner: ""
linked_runs: [73]
created: 2026-11-03
---

## Summary

The request chat shows a live row while the Lead is thinking, but agents working inside a workflow run (builders, checkers, the run lead) don't appear in the chat at all. Today only agents the chat lead starts outside a run show up, in the 'working in the background' row, because LeadChat.backgroundSessions drops every agent with a runId. This change widens that row to cover every agent working on the request, both run agents and background agents, using the existing look: avatar or role badge, name, and live activity (tool, thinking, replying). Several agents collapse into a grouped list, clicking an agent opens its session, and the row sits at the bottom of the thread next to the Lead thinking row.

## Interfaces

- SaturnCore `LeadChat.backgroundSessions(for:)` becomes `workingSessions(for: ProjectTask) -> [AgentSession]`: every running or queued session for an agent tied to the request (agents from `database.requestAgents(taskId:)`, which covers the request's runs, plus `database.spawnedAgents(taskId:)`), with the chat lead excluded, no duplicates, ordered by agent id
- `AppModel.backgroundSessions(for:)` is renamed to `workingSessions(for:)` to match, keeping the `agents.usageRevision` dependency
- `RequestChat`'s `BackgroundAgentsRow` / `BackgroundAgentRow` / `BackgroundAgentLine` become working-agent rows. The single-agent subtitle reads '· working on the run' for agents with a runId and keeps '· working in the background' otherwise. The group header reads 'N agents working'

## Out of scope

- Changes to the Lead's own ThinkingRow
- Showing idle, finished or failed agents
- Showing working agents in the sidebar, run detail view or other screens besides the request chat
- Any new controls (stop, message) on the row beyond clicking through to the session

## Acceptance criteria

- [x] While a run's builder is working, the request chat shows a row at the bottom of the thread with the builder's badge, its name and its live activity (current tool and target, Thinking…, or the reply it is writing)
- [x] Run checkers and the run lead show up the same way while they are running or queued
- [x] Agents the chat lead spawned outside a run still show up as before, with the subtitle '· working in the background'
- [x] The chat lead never appears in this row; it keeps its own thinking row
- [x] When two or more agents are working, they collapse into one grouped list headed 'N agents working', with one line per agent
- [x] Clicking an agent's row or line opens that agent's session
- [x] An agent's row disappears once it stops running or queued, and the chat scrolls to keep the row in view as it appears or changes, like it does today
- [x] Each agent appears at most once, even if it matches both the request's runs and the spawned-by-lead query
- [x] LeadAgentControlTests covers the new behavior: a run agent working on the request is included, the chat lead and agents on other requests are excluded, and idle agents are excluded. The existing assertion that run agents are excluded is updated to match
- [x] `swift test` passes in Packages/SaturnCore and the app builds with xcodebuild

## Verification

Run `swift test` in Packages/SaturnCore, including the updated LeadAgentControlTests. Build the Saturn app with xcodebuild. Then start a feature-delivery run from a request chat and check that the run lead, then the builders, then the checker each show up live at the bottom of the chat while they work and disappear when they finish, that two at once collapse into the grouped list, and that clicking one opens its session.
