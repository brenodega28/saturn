---
title: Send failed checks and merges to the lead before the user
status: done
version: 1
workflow: feature-delivery
workers:
  - {role: builder, name: Builder 1, reason: "One task: engine hold routing, the lead tool, LeadChat relay and UI stage, which all depend on each other", model: opus}
  - {role: checker, name: QA, reason: Runs the suites and forces real failure and merge-conflict holds end to end, skills: [qa-engineer], model: opus}
owner: ""
linked_runs: [40]
created: 2026-11-25
---

## Summary

Today, when a run step fails, times out or hits its loop limit, RunEngine.hold posts a ChatRequest card ("Retry the step, or fail the run" / "Continue once more, or fail the run") and the user has to act. That covers a checker failing (QA or review exhausting its loops, a check step failing), a checker agent crashing, and the end step's merge failing (integration conflict, unsafe merge into base). With this change, Saturn sends those holds to the chat's lead first. It messages the lead with the step, the error, and the last verdict and issues. The lead fixes the problem with its existing tools: message or spawn builders, or open its own worktree. It then resolves the hold with a new tool: retry, continue, or fail. The user is asked only when the lead escalates with ask_human, or when the lead has already tried twice on the same step. Merge failures from the manual Merge button get the same treatment: the error goes to the lead, which fixes it and tells the user when it is ready to merge again. Approval, plan approval and gate holds remain user decisions and don't change.

## Interfaces

- HoldReason gains a handler: RunHold.handledBy (.lead | .user), saved in engine state. Holds with reason stepFailed, timedOut or loopLimit start as .lead when the run's chat has a lead, and .user otherwise (for example a GitHub-triggered run with no chat).
- RunEngine.hold(...): for a .lead hold, skip the user-facing ChatRequest card and call a new delegate hook, leadShouldHandle(run, hold, details). LeadChat implements it by waking or starting the lead session (leadSession(for:in:)) and sending a structured message: run, step, reason, error text, latest verdict summary and issues, and the conflicting branch and files for a merge conflict.
- New lead MCP tool resolve_run_hold(run_id, action: retry | continue | fail, note?): calls RunEngine.retryStep / resolveLoopLimit(continueOnce:) / resolveFailure(retry: false). Refused when the run has no lead-handled hold.
- Escalation: when the lead calls ask_human during a lead-handled hold, or the same step reaches its third lead-handled hold, the hold flips to .user and the original Retry/Continue/Fail card is posted as today, with the lead's note attached.
- AgentWorkflowDriver.mergeDelivery failure (manual Merge button): the user still sees the error, and Saturn also sends it to the lead with the branch, base and git output.
- ChatStage / RunTimeline / notifications: a lead-handled hold shows as 'Lead is fixing: <title>' (working, not stuck). It sends no macOS 'needs you' notification and doesn't count as waiting on you.

## Out of scope

- Approval, plan-approval and gate holds: these remain user decisions.
- Changing workflow YAML: there is no per-step opt-out flag in this pass.
- New fixing abilities for the lead beyond its current tools (message_agent, spawn_agent, open_worktree).
- Holds that are already pending when the change ships.
- Push-to-origin failures (pushBase).

## Acceptance criteria

- [x] A QA step that returns failed past max_loops sends the lead a message describing the failure. No user card is created, and the chat stage shows 'Lead is fixing'.
- [x] A check or agent step that throws (stepFailed) or times out is routed to the lead the same way.
- [x] An end-step merge conflict or unsafe merge is routed to the lead, and the message names the branch and the conflicting files.
- [x] The lead calling resolve_run_hold with retry, continue or fail behaves exactly like the user's Retry, Continue once and Fail buttons.
- [x] The lead calling ask_human during a lead-handled hold posts the original user card plus the lead's question, and the hold becomes user-handled.
- [x] A third lead-handled hold on the same step goes straight to the user with the usual card.
- [x] A run without a chat lead (no owning task) keeps today's behaviour: the user card is posted at once.
- [x] A manual Merge button failure shows the error to the user and also sends it to the lead.
- [x] No macOS 'needs you' notification fires for a lead-handled hold. One fires when it escalates.
- [x] No regressions: swift test passes in Packages/SaturnCore, and new tests cover each case above in FailureRecoveryTests, RunEngineTests and LeadChatTests.

## Verification

Run swift test in Packages/SaturnCore, including the new cases that use ScriptedWorkflowDriver to force a QA failure past its loop limit, a step error, a timeout, an end-step merge conflict, lead retry/continue/fail, lead escalation and the third-hold auto-escalation. Then build the app with xcodebuild. Start a small-task run whose checker is told to fail, and confirm that the lead gets the failure in the chat, no Retry/Fail card appears, and the lead can retry through resolve_run_hold. Force a merge conflict at the end step and confirm the lead gets the branch and files.
