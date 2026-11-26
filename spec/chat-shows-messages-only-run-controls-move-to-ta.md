---
title: Chat shows messages only; run controls move to Task tab
status: done
version: 1
workflow: small-task
workers:
  - {role: builder, name: Builder, reason: Removes the chat cards and moves the run/proposal controls into TaskPane, model: opus}
  - {role: reviewer, name: Reviewer, reason: Checks the diff against the acceptance criteria and builds the app, model: opus}
owner: ""
linked_runs: [37]
created: 2026-11-25
---

## Summary

The request chat stops showing two kinds of cards. (1) The run progress card: the "Started the run." bubble with the No plan needed pill, the RunCard title/meta row, the stage progress bar and the Details button. (2) The "Proposed run" card. The live run controls move into the right sidebar's Task tab. Those are Pause/Resume, Retry Step and Cancel Run (with its confirmation) plus a Details link to the run page. Removing the proposal card also removes the only Start run / Dismiss buttons for an open proposal. So while a proposal is open, the Task tab shows a small "Proposed run" block with its title, workflow and Start run / Dismiss, with the same disabled rules as today. Step events, hold/approval cards, the run-ended card, spec cards, questions and permission cards stay in chat.

## Interfaces

- RequestChat.row: `.runStarted` renders nothing; `.proposal` messages render nothing in messageRow
- RunCard and ProposalCard (+ ProposalAgents) removed from RequestChat.swift if unused; NoPlanPill kept if still used elsewhere
- RunControls moves out of RequestChat.swift so ChatSideBarView's TaskPane can use it (e.g. Saturn/Views/V5/RunControls.swift), shown when latestRun(of: chat).isActive, plus a Details button calling workspace.openRunDetail(run)
- New TaskPane block for the latest open proposal of the chat: title, workflow name, Start run (workspace.startProposal) and Dismiss (workspace.dismissProposal), disabled when a run is active, the request is closed, or the workflow is missing (same rule as ProposalCard.startHelp)

## Out of scope

- Step event lines, HoldCard approvals, FinalStateCard (merge/run ended), SpecCard, QuestionCard, PermissionCard: unchanged in chat
- Redesigning the Task tab's other sections
- Daemon/model changes to runs or proposals

## Acceptance criteria

- [x] Starting a run adds no card or 'Started the run.' bubble to the chat
- [x] No 'Proposed run' card appears in chat, open or started
- [x] With an active run, the Task tab shows Pause (or Resume when paused/interrupted), Retry Step when the hold is stepFailed/timedOut, and Cancel Run with the existing confirmation dialog, and each calls the same workspace action as before
- [x] The Task tab has a Details control that opens the run detail page
- [x] With an open proposal, the Task tab shows Start run and Dismiss, and they work; Start is disabled while a run is active or the request is closed
- [x] Lead messages, user messages and the other cards still render in chat as before
- [x] The app builds and the SaturnCore tests pass

## Verification

Build the Saturn app and run the SaturnCore tests. Then in the app: have the lead propose a small-task run, and check the chat shows no proposal card while the Task tab shows Start run / Dismiss. Start it, and check the chat gets no progress card while the Task tab shows Pause, Cancel Run and Details. Pause → Resume, then Cancel → confirm dialog → run cancelled.
