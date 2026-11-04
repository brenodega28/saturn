---
title: End agent turns when Claude Code lingers after its result
status: done
owner: ""
linked_runs: [80]
created: 2026-11-04
---

## Summary

A workflow step only advances once the agent's Claude Code process exits. `AgentSession` marks the agent idle and calls `runtime.turnEnded` from `processEnded` only (AgentSession.swift:491-502), and `AgentWorkflowDriver.waitForTurnEnd` (AgentWorkflowDriver.swift:662-667) waits while `isRunning` (`handle != nil`) or status is `.working`. When an agent leaves background tasks running (run 76's builder started `runserver` and `vite` with `run_in_background` and a 1-hour timeout), Claude Code stays alive after emitting its `result` event, even though Ensemble has already closed its stdin. The builder had submitted its result, but the run sat in `build` for up to an hour. Fix: once a turn's `result` event arrives and the input is closed, give the process a short grace period to exit, then kill it and its child processes, and end the turn as normal. Also tell agents to stop any background processes before handing off.

## Interfaces

- AgentSession: after `.turnCompleted` (where it already calls `source.closeInput()`), schedule a linger timeout for that handle. If the same handle is still current and still running when it fires, kill it with `handle.kill()` (which already SIGKILLs descendants via `ClaudeProcess.descendants`) and let the resulting `.exited` go through `processEnded`, which sees `turnCompletedInProcess == true` and ends the turn as idle (not failed, not a crash restart).
- AgentRuntime (or wherever runtime tunables like `crashRestartLimit` / `apiRetryDelays` live): new `lingerGrace: Duration`, default 10 seconds, injectable so tests can set it to something small.
- The timeout is cancelled or ignored when the process exits on its own, when a new turn starts on the same session, when `stop()`/restart sets `stopTarget`, or when the handle has changed (`source === handle` guard).
- A linger kill records a transcript notice (e.g. `.info`/existing notice kind) such as "Claude Code was still running background tasks after the turn ended, so Ensemble stopped it." Reuse an existing notice kind if one fits; don't add a new one unless needed.
- AgentWorkflowDriver build/fix/merge-conflict messages (`buildMessage`, `feedbackMessage`, the step `.result` message and the conflict message): one added sentence telling the agent to stop any servers or background commands it started before calling `submit_result`.
- FakeClaude: new mode (e.g. `linger-after-result`) where the fake prints its `result` line and then keeps running (e.g. `sleep 600`) instead of exiting when stdin closes.

## Out of scope

- A general inactivity watchdog or lead nudge after N minutes without events.
- Changing how `ask_human` or permission waits are detected.
- Recovering run 76 itself (it unsticks when its background tasks time out, or when the Builder is stopped).
- Keeping an agent's dev servers alive across the handoff for QA to reuse.

## Acceptance criteria

- [ ] With FakeClaude in the new linger mode and a small `lingerGrace`, a session's turn ends: status becomes `.idle`, `isRunning` is false and `runtime.turnEnded` fires within about `lingerGrace` after the `result` line.
- [x] The lingering fake process and its child processes are gone after the kill (check that the recorded pid is no longer alive).
- [ ] A workflow build step whose builder calls `submit_result` and then lingers advances with that recorded result. It doesn't wait for the process to exit, and doesn't raise `missingHandoff` or `agentFailed`.
- [ ] A linger kill is not treated as a crash: no `.retrying` notice, no restart, `crashRestarts` unchanged, and status isn't `.failed`.
- [ ] Normal mode is unchanged: a fake that exits right after its result ends the turn the same way it does today, and no linger notice is recorded.
- [ ] A new turn sent to the session before the grace period runs out isn't killed by the old timer, and neither is a process that was stopped or restarted by the user.
- [ ] Builder-facing step messages tell the agent to stop background servers or commands before `submit_result`.
- [ ] No code comments are added. Existing EnsembleCore tests still pass (`swift test` in Packages/EnsembleCore).

## Verification

Run `swift test` in Packages/EnsembleCore: the new AgentSession linger test, the new workflow test (a build step with a lingering builder advances with its submitted result), and the full existing suite. Then do a manual check in the app: start a small-task run on a scratch repo and ask the builder to start `python3 -m http.server` with run_in_background before submitting. The run should move to review within about 10 seconds of the builder's result, and the http.server process should no longer be running (`lsof -i :8000` comes back empty).
