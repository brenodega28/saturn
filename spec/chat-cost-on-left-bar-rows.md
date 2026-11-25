---
title: Chat cost on left bar rows
status: in-progress
version: 1
workers:
  - {role: builder, name: Swift Dev 1, reason: "One small, connected change: the SaturnCore query, ChatSummary, the row and the footer, with tests"}
  - {role: checker, name: Reviewer, reason: Fresh-eyes review of the branch against the artboard and the criteria}
owner: ""
linked_runs: [29]
created: 2026-11-25
---

## Summary

Match the "Left bar v6 · Finished folded" artboard: each chat row in the left bar shows what that chat has cost so far. The cost goes on the row's second line, right after "project · machine", in SF Mono 11px, secondary text colour (Tokens.text2). Examples are "$4.15" and "$0.62". The cost counts the Lead, its runs and its agents, the same way the existing chat-spend warnings count it. Rows with no recorded spend show nothing. Finished rows show their cost too. The weekly total in the sidebar footer changes from "$115 wk" to "$115 · wk", as drawn.

## Interfaces

- SaturnCore: `AppDatabase.chatSpend() throws -> [Int64: Double]`. Public, keyed by chat (task) id, covering open and finished chats. It is built from the SQL now in the private `openChatSpend`, with the `closedAt IS NULL` filter made optional. `recordChatSpendWarnings` keeps its current behaviour.
- App: `ChatSummary.costUSD: Double` (0 when there is no usage). `DaemonWorkspace.chatSummaries()` fills it from one `chatSpend()` call per refresh, read with `connection.usageRevision` so rows update when usage changes.
- App: `ChatCost.label(_ usd: Double) -> String?`. It returns "$4.15" (two decimals, en_US currency style), or nil when the amount rounds to $0.00.
- `ChatRow` (Saturn/Views/V5/ChatSidebar.swift): a `Text` with the cost label after `MachineLabel`, font `Tokens.mono(11)`, colour `Tokens.text2`, `.fixedSize()`, placed before the Spacer and the WorkerStack. It joins the row's accessibility label as "cost $4.15".
- `SidebarFooter` (Saturn/Views/V5/SidebarParts.swift): text format becomes "$%.0f · wk".

## Out of scope

- Cost on closed-chat rows (ClosedChatRow), drafts, the ⌘K palette or the project overview
- Changing how spend is recorded or priced
- Other artboard differences, such as layout, tabs or the rail, beyond the per-row cost and the footer separator
- Budget limits or warnings

## Acceptance criteria

- [ ] A chat with recorded usage shows its total cost, such as "$4.15", on the second line of its left bar row, right after the machine label, in mono 11pt text2
- [ ] The cost adds up usage from the chat's Lead, its runs and the agents of those runs, and matches what the chat-spend warning query counts for the same chat
- [ ] A chat with no usage, or under half a cent, shows no cost text and no extra gap
- [ ] Finished chats in the Finished panel show their cost
- [ ] The cost updates without a relaunch when new usage is recorded, for example while a run is going
- [ ] The project name truncates before the cost does, and the cost never wraps
- [ ] The sidebar footer reads "$N · wk"
- [ ] Chat-spend milestone warnings still fire only for open chats (existing tests pass)
- [ ] New SaturnCore tests cover `chatSpend()`: lead, run and agent usage summed per chat, finished and closed chats included, and chats without usage left out
- [ ] A unit test covers `ChatCost.label`: 0 gives nil, 0.004 gives nil, 4.149 gives "$4.15", 115 gives "$115.00"

## Verification

Run the SaturnCore tests (`swift test` in Packages/SaturnCore) and the app tests via xcodebuild. Then build and run the app with a project whose chats have usage. Check that each row shows its cost after the machine label, that finished rows show it when the panel is expanded, that a fresh chat shows none, that the footer reads "$N · wk", and that the cost goes up while a run spends.
