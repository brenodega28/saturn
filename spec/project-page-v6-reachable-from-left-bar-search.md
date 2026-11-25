---
title: Project page (v6) reachable from left-bar Search
status: in-progress
version: 1
workers:
  - {role: builder, name: Project Page Dev, reason: "Owns the page model, ProjectPage shell, Overview, Chats, palette Projects group and routing (V5/, MainPages, MainWindowNavigation, CommandPalette, ProjectView, new Views/Project/)"}
  - {role: builder, name: "Agents & Workflows Restyle Dev", reason: "Restyles Views/Agents and Views/Workflows to the v6 artboards; works in the old tool tab as well, so it is independent of the shell"}
  - {role: builder, name: "Changes, Source & Settings Restyle Dev", reason: "Restyles Views/Changes, Views/Code and Views/Settings to the v6 artboards; separate folders, testable on their own"}
  - {role: checker, name: QA, reason: Tests the merged work end to end against the acceptance criteria}
owner: ""
linked_runs: [28]
created: 2026-11-25
---

## Summary

Add one Project page per project, built to the Project v6 design on the canvas. A dark header shows the project tile, name, location, path and branch, with Finder, Terminal, More and New chat actions. Below it, a section nav holds Overview, Chats, Agents, Workflows, Changes, Source and Settings, with counts. The existing Agents, Changes, Workflows, Code and Settings tool tabs become sections of this page and are restyled to match the design. Overview and Chats are new and show only data that already exists. The Lead-maintained summary, the stack chips and the health line are left out. In the left-bar Search (⌘K palette), every open project, the current one included, becomes a result that opens its Project page.

## Interfaces

- `enum ProjectSection: Codable, Hashable { overview, chats, agents, workflows, changes, source, settings(SettingsSection) }` replaces `MainTool`'s project cases as what a project page shows
- `MainPageKind.project(ProjectRef, section: ProjectSection)`: one page per project (unique per ProjectRef). Switching sections updates the page in place and never opens a new tab. Saved `.tool(changes|agents|workflows|code|settings, project:)` pages migrate to `.project` with the matching section on load. `.tool(.usage, nil)` stays as it is
- `DaemonWorkspace.openProject(_ project: Project, section: ProjectSection = .overview)`. Existing `open(_ tool:in:)`, `openSettings(_:in:)`, `setTab(_:for:)` and `openAgent` route to it with the matching section
- Page tab: a project page's tab shows the project's letter tile and name (design `pageTabs` isProj)
- CommandPalette: a 'Projects' group lists every open project (current included) as `title: project.name`, meta location (This Mac or host) and path. Selecting it calls `openProject(project)`. It replaces the old 'Switch project' rows
- New folder `Saturn/Views/Project/`: `ProjectPage` (header + section nav + section host), `ProjectOverview`, `ProjectChats`

## Out of scope

- Lead-maintained project Summary and stack chips; the 'All checks green on main' health line
- Right bar v6 · Project panel
- Changing the left bar's own layout (the project card, filter chips); only the Search/⌘K results change
- Light-mode artboards beyond what the existing Tokens already provide
- New backend data: every number shown must come from data the app already has

## Acceptance criteria

- [ ] Clicking Search in the left bar and typing part of a project's name lists that project under 'Projects', the current project included. Pressing ↵ or clicking it opens (or focuses) that project's Project page on Overview
- [ ] Each project has at most one Project page tab. Its tab shows the letter tile and the project name
- [ ] The header matches the design: tile, name, location (This Mac / host name), path, branch, and Finder, Terminal, More and New chat buttons that work. Remote projects show the host and no Finder button
- [ ] Section nav switches sections in place, marks the current one, and shows counts for Chats and Agents, plus a 'needs you' count on Changes when reviews are pending
- [ ] Overview shows: Needs-you banners for chats waiting on the user, with Approve spec and Open chat; Active chats (link to the chat; All chats goes to the Chats section); Recent activity from the existing Log events; stats (active chats, workers running, needs you, merged this week); spend this week vs budget, by day; agents strip with Manage → Agents section; Repository facts (default branch, remote, run command, worktrees folder, instructions file). Any part without data is hidden, never faked
- [ ] Chats section: status filter chips with counts, a text filter, and a table grouped Needs you / In progress / Not started / Finished with status, title, subtitle, worker avatars, branch, +/− lines and updated time. Clicking a row opens the chat
- [ ] Agents, Workflows, Changes, Source and Settings (Roles, Checks, Permissions, Docs, Skills, Workspaces, Remote host, plus any other existing SettingsSection) are restyled to the v6 artboards and keep all their current behaviour
- [ ] Old menu, ⌘K and keyboard entry points to Agents, Changes, Workflows, Code and Settings open the matching section of the Project page. Saved tool pages from before the update restore as Project pages
- [ ] Build passes and existing tests pass; new unit tests cover the page-kind migration, the palette project matching and `openProject` uniqueness

## Verification

Build and run the app with two projects. Open the left-bar Search, type part of each name and select it: one Project page tab opens per project, on Overview. Walk every section and settings tab and compare each against its artboard on the canvas (Project v6 page). Use one action in each section: open a chat, select an agent, edit a workflow step, approve a change, open a file, toggle a check. Then quit and relaunch with old tool tabs saved, and confirm they come back as Project pages. Run the test suite.
