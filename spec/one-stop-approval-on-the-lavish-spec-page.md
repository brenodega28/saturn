---
title: One-stop approval on the Lavish spec page
status: in-progress
version: 1
workers:
  - {role: builder, name: Swift Dev 1, reason: "One task: spec model, renderer, Lavish approve routing and the run-engine hold rule are tightly coupled and tested together."}
  - {role: checker, name: QA 1, reason: Fresh eyes to run swift test and the end-to-end approve flow with the qa-engineer skill.}
owner: ""
linked_runs: [19]
created: 2026-11-25
---

## Summary

Today a request needs up to three separate approvals before code is written: the spec (chat spec card), the Start button on the proposed run, and the plan_approval hold after the lead's plan step. This change makes the Lavish spec review page the single place to approve everything up front. The page shows the full plan: the workflow that will run with its steps, every worker (role, name, skills, model, reason), the total number of agents, and which approvals will still come later (only code-side ones: lead review outcome, final "approve the pins", and risky-command permission prompts). The page gets an "Approve & start" action; using it approves the spec and starts the run, exactly like the chat spec card's Approve does today. Once a run starts from an approved spec, the plan step no longer holds for plan approval as long as the lead's plan stays within what was approved (same or fewer agents, same roles). If the lead's plan goes beyond it, Saturn still holds and shows the difference.

## Interfaces

- draft_spec gains optional `workflow` (workflow id, defaults to the open proposal's or feature-delivery) and each worker gains optional `skills: [String]` and `model: String`; stored in the spec front matter (SpecDocument / SpecWorker).
- SpecPageRenderer renders a new "Plan & approvals" section: workflow name + steps, worker table, "N agents total" (lead + workers), and a list of approvals that remain after starting.
- Spec page gets an "Approve & start" control (e.g. element `#spec-approve`). A Lavish prompt targeting it (or whose text is just "approve") is routed by SpecReviews/SpecFeedback to LeadChat.approveSpec instead of being delivered to the lead as feedback; the page reply confirms the run started.
- RunEngine: when the run's committed spec is approved and the plan's assignments fit the approved workers (count <= approved, roles a subset), skip the planApproval hold and route straight on. Otherwise hold as today, with the hold body naming what exceeds the approval.
- Lead instructions (AgentRuntime / draft_spec tool description): the spec must list every worker and the workflow, and approving it is the user's go-ahead; the lead must not ask for further approval of plan or agent count.

## Out of scope

- Removing code-side approvals: lead review routes, the workflow's final approval step, gate decisions and risky-command permission prompts stay.
- Changing the approve_plans project preference semantics for runs started without a spec (they still hold as today).
- Lavish review for remote projects (still read-only).
- Redesigning the chat spec card beyond keeping its Approve in sync with the page.

## Acceptance criteria

- [ ] The spec review page shows a "Plan & approvals" section listing the workflow, its steps, each worker with role/name/reason (and skills/model when given), and the total agent count.
- [ ] The same section lists the approvals still to come after starting, derived from the workflow (approval steps, review routes) plus a line about permission prompts for risky commands.
- [ ] Using the page's "Approve & start" action approves the spec and starts the run with no further click in the Saturn chat; the page shows a reply confirming it.
- [ ] Approving from the page when a run is already active, or the spec is committed, replies on the page with the reason and starts nothing.
- [ ] A run started from an approved spec whose lead plan has the same or fewer workers with approved roles goes from plan to build without a plan_approval hold.
- [ ] A run whose lead plan exceeds the approved workers (more agents or a new role) still holds for plan approval and the hold body names the excess.
- [ ] Runs started without a spec keep today's plan-approval behaviour governed by approve_plans.
- [ ] draft_spec accepts and round-trips `workflow`, worker `skills` and `model` through the spec markdown; older specs without them still parse.
- [ ] Unit tests cover rendering, approve routing from Lavish prompts, and the hold-skip rule; `swift test` in Packages/SaturnCore passes.

## Verification

Run `swift test` in Packages/SaturnCore. Then end to end in a local project: as lead, call draft_spec with 2 workers; open the Lavish page and confirm the Plan & approvals section and agent count; trigger Approve & start on the page; confirm the run starts, the plan step passes to build without a plan_approval card, and the only later stops are review/QA/final approval. Repeat with a lead plan that adds a third worker and confirm the plan hold appears naming the extra agent.
