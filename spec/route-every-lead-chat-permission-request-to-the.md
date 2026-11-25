---
title: Route every lead-chat permission request to the lead chat
status: done
owner: ""
linked_runs: [69]
created: 2026-11-03
---

## Summary

Permission requests only become a card in the lead chat when the asker is a non-lead agent in a run whose workflow has a lead agent step and whose lead has a live session (AgentRuntime.relayLead in PermissionRequests.swift). Everything else falls back to the Inbox. Chat 66 hit those gaps: the lead's own git status went to the Inbox, and run 67 uses small-task, which has no lead step, so Builder 2 and Checker went to the Inbox too. Agents the lead starts with spawn_agent outside a run (no runId, spawnedById set to the lead) also go to the Inbox. The fix: work out which request chat the asker belongs to and always post the card there. Only agents that belong to no chat use the Inbox.

## Interfaces

- AgentRuntime (PermissionRequests.swift): replace relayLead(for:runId:) with a lookup that returns the asker's owning chat task id, checking in this order: agent.taskId (the lead itself), then run.taskId for agent.runId, then the owning task of agent.spawnedById, followed recursively with a cycle guard.
- ask(...): whenever an owning task exists, insert the PermissionRequest and a pending .permission LeadMessage in that task (runId set when the asker has one), and reply with leadChatReason. Notify the lead session only if it is live and isn't the asker. The workflow's step types and whether the lead session is live no longer decide where the request goes.
- The Inbox .permission path stays only for agents with no owning chat task.

## Out of scope

- Moving permission requests that are already pending in the Inbox (for example chat 66's) into chats.
- Mirroring chat permission cards into the Inbox.
- Changes to the card UI, how cards are placed in the thread, allow and deny semantics, or permission policy levels.

## Acceptance criteria

- [x] A permission request from the lead agent itself becomes a pending card in its own chat, creates no Inbox item, and the lead is not sent the 'asked to' relay message.
- [x] A request from an agent in a small-task run (a workflow with no lead step) becomes a card in that run's chat, not an Inbox item.
- [x] A request from an agent the lead started with spawn_agent outside any run becomes a card in the lead's chat.
- [x] A request from a run agent becomes a card even when the lead's session isn't live. The relay message is simply skipped.
- [x] An agent with no run, no taskId and no spawning lead still asks in the Inbox (the existing anAgentOutsideALeadChatRunAsksInTheInbox test still passes).
- [x] Allow once, allow for the run and deny on these new cards resume or block the asker exactly as they do for run cards today. When the lead itself is the asker, it is the only one notified.
- [x] No regressions: the PermissionRoutingTests, DesignParityTests, RealClaudeHookTests and LeadChatTests suites pass. New tests in PermissionRoutingTests cover each new case above.

## Verification

Run swift test in Packages/SaturnCore, including the new PermissionRoutingTests cases. Then build the app with xcodebuild, open a chat, run a small-task workflow, get both the lead and a run agent to try an unlisted command, and confirm both cards show up inline in that chat and nothing new appears in the Inbox.
