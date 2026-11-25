---
title: Lead set_chat_status tool
status: done
version: 2
workers:
  - {role: builder, name: Builder}
owner: ""
linked_runs: [3]
created: 2026-11-19
---

## Summary

Give chat cards four statuses: Open, Finished, Resolved and Closed. Add a `set_chat_status` MCP tool so a request's lead can set them itself. Finished is new: the lead says the work is done, but the user hasn't closed the chat yet. The chat stays in the open list and keeps all its agents, worktrees and branches so the user can still review and continue. Resolved (today's "Done") and Closed (today's "Dropped") are the existing closed states. They still clean up the request's agents. When the lead triggers that cleanup, it runs after the lead's turn ends so the lead doesn't delete itself mid-call. Open clears any of the other three.

## Interfaces

- Chat.finishedAt: Date? — new nullable column on task (AppDatabase migration). Finished = finishedAt != nil && closedAt == nil
- AppDatabase.setFinished(taskId:, at:) / clearing it: setting Open clears finishedAt, closedAt and closeReason; closing (resolved/closed) also clears finishedAt
- ChatStage gains .finished; ChatStage.Facts gains isFinished. Precedence: closed (resolved/closed) > stuck/needsYou/inReview/building > finished > a succeeded latest run, which also maps to .finished instead of .done > idle (Open)
- ChatStage titles: .idle "Open", .finished "Finished", .done "Resolved", .dropped "Closed"; RequestCloseReason titles .done "Resolved", .dropped "Closed" (enum raw values unchanged, so stored data stays valid)
- HandoffTool.setChatStatus = "set_chat_status": input { status: "open" | "finished" | "resolved" | "closed" (required), reason: string (optional, one line shown to the user) }; HandoffMessage.setChatStatus decoded in HandoffTool.decode; an unknown status throws notAllowed listing the four values
- Tool offered only to a request's lead (added to chatTools in AgentWorkflowDriver.swift:94)
- Handler: finished -> setFinished, agents kept; resolved/closed -> setClosed(.done/.dropped) now, request agent/worktree/branch cleanup deferred until the lead's turn ends; open -> clears all. Finished/resolved/closed are refused while a run for the request is active
- ChatRowMenu (ChatSidebar.swift) and Chat menu (MenuCommands.swift): "Mark as finished", "Resolve", "Close", "Reopen"; a daemon ChatCommands entry for setting Finished from the UI
- LeadChat.send: a user message to a Finished or closed chat sets it back to Open
- Lead role prompt (RoleDefinition.swift and the lead text in RoleMigration.swift): one line on using set_chat_status — finished when the work is done and waiting on the user, resolved when the user confirms the goal is met, closed when the user abandons it, open when work resumes
- Chat transcript note when the lead changes status: "Lead marked this chat <Status> — <reason>"

## Out of scope

- Letting non-lead agents (run builders, checkers, spawned agents) change chat status
- A lead changing the status of any chat other than its own request
- Automatically setting Finished without the lead or user (except the existing succeeded-run case relabelled from Done to Finished)
- Changing what cleanup Resolved/Closed perform

## Acceptance criteria

- [x] set_chat_status {status: finished} sets finishedAt; the card shows "Finished", stays in the open list, and every request agent, worktree and branch still exists
- [x] set_chat_status {status: resolved} closes with reason done; the card shows "Resolved" in the closed list; after the lead's turn ends the request's agents, worktrees and branches are deleted
- [x] set_chat_status {status: closed} closes with reason dropped; the card shows "Closed"; cleanup runs as for resolved
- [x] set_chat_status {status: open} on a Finished, Resolved or Closed chat clears finishedAt, closedAt and closeReason; the card shows "Open"
- [x] The lead's session is never deleted during the tool call; the tool returns a result and the turn ends normally
- [x] finished/resolved/closed are refused with a clear message while a run for the request is active
- [x] An unknown status returns an error naming open, finished, resolved, closed
- [x] The tool isn't listed for agents without a taskId
- [x] A user message to a Finished or closed chat returns it to Open
- [x] An open chat whose latest run succeeded shows "Finished", not "Done"; the sidebar and menu show the labels Open, Finished, Resolved, Closed; no "Done" or "Dropped" chat labels remain
- [x] The user can mark a chat Finished, Resolve it, Close it and Reopen it from the chat row menu
- [x] Existing rows with closeReason done/dropped load and show as Resolved/Closed
- [x] SaturnCoreTests cover each status transition via FakeClaude call_tool set_chat_status, the active-run refusal, the tool list, the ChatStage precedence for .finished and the migration; swift test passes

## Verification

Run `swift test` in Packages/SaturnCore and build the app target. In the app, ask a lead to mark its chat finished. The card should show Finished in the open list, and its worktrees should remain. Then ask it to resolve. The card should move to the closed list as Resolved, and its agents should be cleaned up after its turn. Send a message to the chat and check that it shows Open again. Try closing while a run is active and check that the attempt is refused. Use the row menu to step through all four statuses.
