---
title: "Stop a second instance from hijacking runs, and re-drive orphaned steps"
status: in-progress
owner: ""
linked_runs: [74]
created: 2026-11-03
---

## Summary

Runs 71 and 72 stalled because a second Ensemble instance (a builder's `open -n` debug build) opened the same data directory. On launch it SIGTERM'd every live Claude process (AgentRuntime.recoverAfterLaunch) and took over every active run (RunEngine.recover). It marked the in-flight attempts as interrupted and started new attempts that only it drove. The main app then had no task driving those steps, so they stayed `running` forever. The fix has two parts. (1) A single-instance guard: a second process that opens the same AppPaths root refuses to start, shows an alert and quits before it touches agents, runs or the MCP server. (2) An engine watchdog: about every 30s, any active run whose status is `running` but that has no driver task in this process is re-driven the same way `recover()` does after a restart. Each time, a short system note is posted in the request chat. No LLM call is made.

## Interfaces

- EnsembleCore: `InstanceLock` (new, Storage/). `static func acquire(paths: AppPaths) throws -> InstanceLock` takes an exclusive, non-blocking `flock` on `<root>/ensemble.lock` and holds it for the process's lifetime. If another process holds it, it throws `InstanceLockError.alreadyRunning`, with the holder's PID if known.
- Ensemble/AppModel.launch() (or app startup before it): acquire the lock first. On failure, show an NSAlert like 'Ensemble is already running with this data folder. Quit the other copy first.' and terminate. Skip recoverAfterLaunch, ensureServer, engine.recover and every background task.
- RunEngine: `func reviveOrphanedRuns(now: Date = .now) throws -> [Int64]` returns the run ids it re-drove. A run qualifies when its status is `.running`, `drivers[runID] == nil`, there is no `state.hold`, and it was seen orphaned on two consecutive checks (so a driver that is starting up or just finished isn't caught). Reviving reuses the recover path: interruptInFlightSteps, then launch. For each revived run it inserts a `LeadMessage(kind: .note, runId:)` into the request chat, such as 'Run “<title>” had stopped moving at “<step>”, so Ensemble picked it up again.'
- RunEngine/AppModel: `startOrphanWatchdog(interval: Duration = .seconds(30))` is started from AppModel.launch after engine.recover(), and is cancelled with the other background tasks.

## Out of scope

- Making the lead LLM poll runs or giving it a tool to move steps.
- Giving debug builds their own data directory.
- Detecting stalls inside a live driver, such as an agent stuck mid-turn or a verdict recorded in another process. Only runs with no driver in this process are covered.
- Cleaning up runs 71 and 72 by hand. The user restarts the app, and recover() or the watchdog picks them up.

## Acceptance criteria

- [ ] Launching a second Ensemble process against the same data directory shows the alert and quits. It doesn't terminate any Claude process, change any agent or run row, or start an MCP server. Covered by an EnsembleCore test: a second `InstanceLock.acquire` on the same root throws `alreadyRunning`, and succeeds once the first lock is released.
- [ ] A different AppPaths root (for example a temp directory in tests) can be locked at the same time as the standard one.
- [ ] RunEngine test: a run with status `.running` whose driver task has ended without finishing the step is re-driven by `reviveOrphanedRuns` on the second check, not the first. Its stuck step ends `interrupted`, a new attempt starts with `.resume`, and the run reaches its next step.
- [ ] RunEngine test: a run with a live driver, a run in `.waitingOnYou`, a run in `.paused`, and a finished run are never revived.
- [ ] Each revive inserts exactly one `.note` LeadMessage on that run's request chat, and the note shows in the chat as a system line, not as a lead reply. No agent session gets a turn just because of the note.
- [ ] The watchdog stops when the app quits and doesn't revive a run twice in the same orphan episode.
- [ ] No code comments. The xcodebuild app build succeeds, and `swift test --package-path Packages/EnsembleCore` passes.

## Verification

Run the EnsembleCore tests: the new InstanceLock tests and the RunEngine orphan tests, plus the existing suite. Build the app with xcodebuild. If the builder can check it without disturbing the user's live instance, launch the built app with a temporary HOME or AppPaths override twice, and confirm the second launch alerts and exits. Report plainly anything that couldn't be exercised by hand. In particular, never launch a build against the user's real data directory.
