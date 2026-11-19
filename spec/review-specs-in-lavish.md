---
title: Review specs in Lavish
status: in-progress
version: 1
workers:
  - {role: builder, name: Swift Dev}
  - {role: qa-engineer, name: QA}
owner: ""
linked_runs: [4]
created: 2026-11-19
---

## Summary

Replace the Markdown spec editor with a Lavish (lavish-axi) review page. The feature flow becomes: discuss in chat → the lead calls `draft_spec` → Ensemble renders the structured SpecDocument into a standalone HTML page and opens it with Lavish in a new Ensemble tab → the user annotates and discusses the page → ensembled long-polls Lavish and delivers each feedback batch to the lead as a chat message → the lead revises with `draft_spec` (the page live-reloads) and answers on the page with a new `reply_spec` tool → the lead proposes the run with a slimmer proposal card → development loop as today. The Markdown SpecDocument stays the engine's source of truth (criteria gating, committing to the run branch and completion are unchanged). The HTML page is a view generated from it. Ensemble bundles a pinned copy of lavish-axi and runs it with Node, with telemetry off and loopback only.

## Interfaces

- `LavishRuntime` (EnsembleCore): locates the bundled lavish-axi (pinned version, vendored under EnsembleCore Resources and copied into the app bundle next to ensembled) and Node on PATH. Every invocation sets `LAVISH_AXI_TELEMETRY=0`, `LAVISH_AXI_NO_OPEN=1` and `LAVISH_AXI_STATE_DIR=<Ensemble data dir>/lavish`, and binds to loopback only (no Tailscale/`--also-listen`). It exposes `open(file:) async throws -> URL` (session URL), `poll(file:owner:) async throws -> LavishPollResult`, `reply(file:text:) async throws` and `end(file:) async throws`
- `SpecPageRenderer` (EnsembleCore): `render(_ document: SpecDocument) -> String` produces a standalone HTML page from a template in Resources/Templates. It covers the title, status, version, summary, interfaces, out of scope, acceptance criteria (one element per criterion with a stable `data-criterion` id), verification and workers, with an explicit page background and light/dark styles. The page is written next to the draft as `<draft>.html` every time the draft is written, including when the user's edit merges arrive
- `SpecReviewSession` (EnsembleCore, owned by ensembled): one per request with a spec draft. It opens the Lavish session and keeps a single `poll --owner ensemble` listener running for it. Each feedback batch (annotation text, the targeted element/criterion, attachment paths) becomes a user-side lead chat message tagged as spec feedback, which wakes the lead. `ended` and `browser_disconnected` stop the listener. The session ends when the run starts (the spec is committed) or the request closes
- New lead handoff tool `reply_spec(text: String)`: posts the lead's answer to the request's Lavish session via `lavish-axi reply`. Only a request's lead can call it, and it errors when no session is open
- `draft_spec` keeps its signature. Its result text now says the page was (re)rendered and that feedback arrives as chat messages. The `unseenEdit`/edit-merge path is removed along with the Markdown editor
- `MainPage.Kind.spec(path:projectID:)` now shows a `SpecReviewPage`: a WKWebView loading the Lavish session URL. Opening it starts the session through the daemon if needed. If Lavish or Node is unavailable, or the project is remote, it shows the rendered HTML read-only plus a one-line reason
- The `SpecEditor` view, the inspector's 'Open in editor' Markdown path and `saveDaemonFile` for specs are removed. The Chat inspector's Specfile section and the ProposalCard 'Spec attached' link open the Lavish tab
- ProposalCard/SpecCard slimmed down: the title, workflow, and an 'N agents' line with one short reason per agent (from the spec `workers` plus a new optional `reason` on each worker), plus Dismiss/Start. The full brief stays behind Show more. `draft_spec`'s worker entries gain an optional `reason: String`
- Environment check: 'Node for Lavish' reports a warning (not a blocker) when `node` is missing or older than the version the pinned lavish-axi requires

## Out of scope

- Live Lavish review for remote (SSH) projects. They get the read-only rendered page, and feedback goes through chat
- Lead-authored free-form HTML, diagrams or Lavish playbooks. The page is rendered only from the SpecDocument
- `lavish-axi share` / publishing to ht-ml.app
- Changing the workflow steps (plan/build/review/qa/approve) or the criteria gates
- A new agent-picker step before Start
- Auto-updating the bundled lavish-axi

## Acceptance criteria

- [ ] Calling `draft_spec` writes the Markdown draft and a rendered HTML page, and opens (or focuses) a Spec tab in Ensemble that shows the page inside Lavish with annotation controls working
- [ ] Every lavish-axi process Ensemble starts has LAVISH_AXI_TELEMETRY=0, listens only on loopback, never opens an external browser, and keeps its state under Ensemble's data directory
- [ ] Lavish runs from the bundled, version-pinned copy inside the app bundle. Nothing is fetched from npm at runtime
- [ ] Annotating the page and pressing Send to Agent delivers one message to the lead chat with each note's text and the criterion or section it targets. The lead wakes on it, and the message shows in the chat as spec feedback
- [ ] Only one poll listener runs per spec session, and it survives the lead's turns. Restarting ensembled resumes listening for open sessions without losing queued feedback
- [ ] The lead's `reply_spec` text appears in the Lavish conversation panel, and that note shows as done
- [ ] After the lead calls `draft_spec` again, the open tab live-reloads to the new version without losing the user's unsent annotation text
- [ ] Starting the run ends the Lavish session (the page becomes read-only) and commits the Markdown spec to the run branch exactly as today. Criteria gating and spec completion are unchanged
- [ ] The Markdown SpecEditor is gone, and no UI writes the spec draft except the lead's `draft_spec`
- [ ] The proposal card shows the title, workflow, 'N agents' with a one-line reason per agent, and Dismiss/Start. The full brief is only behind Show more
- [ ] Without Node, or for a remote project, the Spec tab shows the rendered page read-only with a clear reason, and the environment check warns about Node
- [ ] No code comments are added. React-style rules don't apply. Swift naming stays short and descriptive
- [ ] `swift test --package-path Packages/EnsembleCore` passes, with new tests for SpecPageRenderer, the LavishRuntime env/args, feedback-to-message mapping and the reply_spec tool. The app builds with `xcodegen generate && xcodebuild -scheme Ensemble build`

## Verification

Run the EnsembleCore tests and build the app. In the running app, start a lead chat on a local project and ask for a small feature, then let the lead call draft_spec. Confirm the Spec tab opens with the Lavish page, and check with `ps eww` that lavish-axi has LAVISH_AXI_TELEMETRY=0 and is bound to 127.0.0.1 only (`lsof -iTCP -sTCP:LISTEN`). Annotate a criterion and send it: the lead gets the feedback message, revises, and replies. The page reloads and the reply appears in Lavish. Restart ensembled mid-review and send another note to confirm it still arrives. Accept the proposal card (check it shows the agent count and reasons) and start the run. The Lavish page goes read-only, and the spec is committed on the run branch. Repeat with Node removed from PATH and with a remote project to see the read-only fallback.
