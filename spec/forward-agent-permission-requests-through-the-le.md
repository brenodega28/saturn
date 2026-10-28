---
title: Forward agent permission requests through the lead chat
status: done
owner: ""
linked_runs: [57]
created: 2026-10-28
---

## Summary

Today, when a builder runs a shell command that isn't on its allow-list (e.g. `java -version`, `curl …`) and the profile sets Run shell to Allow, the PreToolUse hook returns no decision (`PermissionRequests.swift:56`). Claude's `dontAsk` mode then denies the command silently, and no request reaches the user. This change makes every such denial a permission request. In a run that belongs to a lead chat, the request appears in that chat as an Allow/Deny card. The user chooses Allow once, Allow for this run, or Deny. The decision goes back to the requesting agent. The lead is told about each request and its answer so it can follow the run, but it can't approve anything. Requests from agents outside a lead chat keep today's Inbox flow.

## Interfaces

- `PermissionPolicy.capability(ofTool:input:)` / `AgentRuntime.permissionDecision`: a Bash command that isn't covered by `policy.commands` creates a `.runShell` permission request instead of returning no decision. Allow-listed commands still return `{}`. `.never` capabilities still deny outright. Chained or redirected commands (&&, ;, |, >, subshells, heredocs) are still denied without a request.
- The `askMatcher` hook matcher always includes `Bash` when the agent has Bash, so the hook sees every command that isn't on the allow-list.
- `PermissionRequest` gains `scope: PermissionScope` (`once` | `run`) and `runId: Int64?`, plus a DB migration. A `run`-scoped allow matches later requests from any agent in the same run by command name (first word, e.g. `java`, `curl`). A `once` allow covers the next single attempt of that exact command and is then used up.
- `LeadMessageKind.permission`: a chat card carrying the permission request id, agent name, capability and request text, with status pending | allowedOnce | allowedForRun | denied.
- `AgentRuntime.answerPermission(requestId:decision:)` with `PermissionDecision` (`allowOnce` | `allowForRun` | `deny`). It updates the request and the card, messages the requesting agent, and posts a short note to the lead's session. The existing Inbox path calls it with `allowOnce` / `deny`.
- Routing: when the agent's run has a relay lead (`relayLead(for:runId:)`) and that lead has a chat (`taskId`), Ensemble inserts the `.permission` LeadMessage in that chat and creates no Inbox item. It also sends the lead a message: '<Agent> asked to <action>. The user sees an Allow/Deny card in this chat; don't answer it yourself.' Otherwise it creates the existing Inbox `.permission` item.
- Lead chat UI: a permission card with three buttons (Allow once, Allow for this run, Deny). After an answer it shows the decision and the buttons are disabled.
- Agent-facing deny reasons: when the hook holds a command, the reason says the user is being asked through the lead chat and that the agent should carry on or end its turn.

## Out of scope

- The lead approving or denying requests itself (the user decided every request goes to them).
- Showing lead-routed requests in the Inbox as well.
- Persisting approvals to permissions.yaml or across runs.
- Allowing chained, piped or redirected shell commands.
- Changing the built-in permission profile levels.

## Acceptance criteria

- [x] A builder in a run with a lead chat runs `java -version` (not on the allow-list). No silent deny happens: a pending PermissionRequest exists, the lead chat shows a `.permission` card, no Inbox item is created, and the hook's deny reason tells the agent it's waiting for the user.
- [x] The lead's session receives one message naming the agent and the command and saying it must not answer the request itself.
- [x] Allow once: the agent is messaged that the user allowed it. The next `java -version` passes the hook. A second `java -version` after that creates a new request.
- [x] Allow for this run: the agent is messaged. Any later `java …` command from any agent in that run passes the hook without a new card. A different run doesn't inherit it.
- [x] Deny: the agent is messaged with the deny text, and the same command is denied without a new card for the rest of the run.
- [x] The lead gets a short note with each decision.
- [x] An agent outside a lead-chat run that runs a command outside its allow-list gets an Inbox `.permission` item (today's behavior extended to unlisted shell commands). Allow/deny there works as before.
- [x] Allow-listed commands and `.never` capabilities behave exactly as before. Existing PermissionRequest, RolesAndSpawning, DesignParity and RealClaudeHook tests still pass.
- [x] A command containing &&, ;, |, > or $( ) is denied with the existing shell-rules reason and creates no request.
- [x] Answering a card that's already answered does nothing, and its buttons are disabled.
- [x] No code comments are added (user preference).

## Verification

Unit tests in EnsembleCoreTests cover: hook routing (lead chat vs Inbox), the three decisions and their scope matching, the run boundary, the used-up once grant, chained-command rejection, and the lead notification. Use the FakeClaude harness for the agent messages. Run `swift test` in Packages/EnsembleCore and build the app with xcodebuild. Manual check: start a feature-delivery run, have the builder run `java -version`, then confirm the card appears in the lead chat, Allow for this run lets `java` commands through, and the builder receives the message.
