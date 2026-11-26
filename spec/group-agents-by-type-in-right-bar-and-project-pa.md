---
title: Group agents by type in right bar and project page
status: done
version: 1
workflow: feature-delivery
workers:
  - {role: lead, name: Lead, reason: Plans the change and reviews the branch, model: opus}
  - {role: builder, name: Builder 1, reason: "One task: the grouping helper plus the three view changes, all in Saturn/Views and DaemonWorkspace", model: opus}
  - {role: checker, name: QA, reason: Builds and tests the app end to end, skills: [qa-engineer], model: opus}
owner: ""
linked_runs: [34]
created: 2026-11-25
---

## Summary

The right bar's Project tab Agents list, the project Overview's Agents strip and the project Agents page list every agent instance the leads have spun up, so the same role (Lead, Builder, Checker…) repeats many times. Group them by agent type (the agent's role id, labelled with the role's name) so each surface shows one entry per type with an instance count and a rolled-up status. Each type entry gets a "Show all N" button that reveals its instances; each instance still opens its session as today.

## Interfaces

- AgentTypeGroup (view-layer value): role id, RoleDefinition?, sessions [LiveAgentSession], rolled-up status (most urgent of: needs you > working > queued > idle > stopped), counts of working instances
- DaemonWorkspace.agentTypes(in: Project) -> [AgentTypeGroup] — groups liveAgents(in:) by agent.role, Lead first, then by role name; shared by all three surfaces
- Saturn/Views/V5/ChatSideBarView.swift ProjectAgents: one row per type (avatar, role name, model if uniform, "N instances · M working", status dot) with a Show all / Hide toggle expanding the existing ProjectAgentRow list for that type
- Saturn/Views/Project/ProjectOverview.swift AgentsStrip: one avatar per type with a count badge; header detail becomes "T types · N agents · M working"; clicking a type opens the Agents section filtered to it
- Saturn/Views/Agents/AgentsView.swift: grid shows one card per type; "Show all N instances" expands that type's existing AgentCards inline; existing All/Working/Needs you/Idle filters apply to instances and hide types with no match

## Out of scope

- The chat tab's Workers section in the right bar (per-chat workers stay per instance)
- Changing how agents are named, spawned, archived or deleted
- Daemon / SaturnCore data model changes — grouping is view-only

## Acceptance criteria

- [x] With 1 lead per chat across 3 chats and 4 builders, the right bar Project tab shows exactly 2 rows (Lead ×3, Builder ×4), not 7
- [x] The section count in the right bar shows the number of types, with total instances visible
- [x] Clicking Show all on a type row lists every instance of that type; clicking an instance opens its session; Hide collapses it
- [x] Overview Agents strip shows one avatar per type with an instance-count badge when count > 1
- [x] Agents page shows one card per type; Show all N instances reveals the existing per-agent cards with their controls (pin, delete, etc.) intact
- [x] A type's status reflects its most urgent instance (any instance needing input shows Needs you)
- [x] Archived agents are excluded from the right bar and overview as today
- [x] Grouping logic is covered by a unit test; xcodebuild build and existing tests pass
- [x] React/SwiftUI style: no superfluous comments, short descriptive names

## Verification

Build the Saturn app, open a project with several chats/runs (multiple leads and builders), and check the right bar Project tab, the Overview strip and the Agents page each show one entry per type with correct counts, that Show all expands to instances that open the right session, and that filters on the Agents page still work. Run the unit tests including the new grouping test.
