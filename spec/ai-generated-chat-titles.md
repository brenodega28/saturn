---
title: AI-generated chat titles
status: done
version: 1
workers:
  - {role: builder, name: Builder, reason: "Adds ChatTitler, wires it into LeadChat.createRequest, and writes the tests — one small, self-contained change"}
  - {role: checker, name: QA, reason: Fresh eyes to review the branch and test titles end to end in the app}
owner: ""
linked_runs: [15]
created: 2026-11-25
---

## Summary

Today a new chat's title is the first line of the message cut to 80 chars (LeadRequest.title), so many cards look alike. After the first message of a new chat is sent, Ensemble asks a small, fast model (Haiku) in the background for a short 3–6 word title and renames the chat with it. The truncated first line stays as the immediate placeholder and as the fallback if generation fails, times out, or Claude isn't available. A title the user renamed by hand is never overwritten.

## Interfaces

- New `ChatTitler` (EnsembleCore/Workflow) with `func generateTitle(for chat: Chat, text: String) async` — runs a one-shot `claude -p --model haiku` (reusing ClaudeLaunch/ToolLocator, same provider mode/env as agents, no tools, no MCP, no session persistence) with a prompt asking for a 3–6 word title, plain text only
- `static func cleanTitle(_ reply: String) -> String?` — strips quotes, trailing punctuation, markdown and newlines, caps at LeadRequest.maxTitleLength; nil when empty
- LeadChat.createRequest kicks off ChatTitler in a detached Task after the chat is inserted; it never blocks sending to the lead
- Rename goes through AppDatabase.renameChat only if the chat's title still equals the placeholder (so a manual rename wins), so the sidebar updates through existing DB observation

## Out of scope

- Re-titling on later messages or after runs
- A setting to turn it off or pick the model
- Retitling existing chats
- Using the Lead agent's own session to name the chat

## Acceptance criteria

- [x] Sending the first message of a new chat shows the truncated first line immediately, then within a few seconds the card shows a short AI title (≤ 6 words, no quotes/punctuation noise)
- [x] Two chats starting with the same first line get distinct, content-specific titles
- [x] If the user renames the chat before the title arrives, their name is kept
- [x] If claude is missing, errors, or takes longer than ~20s, the placeholder title stays and no error is shown to the user
- [x] Attachment-only chats (image / pasted text) still get a title; image-only keeps "Image" if nothing useful can be generated
- [x] Sending later messages in the chat does not change its title
- [x] Unit tests cover cleanTitle and the 'don't overwrite manual rename' rule using FakeClaude; existing tests pass (swift test in Packages/EnsembleCore)

## Verification

Run `swift test` in Packages/EnsembleCore. Then build the app, start a new chat with a long message and another with a near-identical opening line; confirm both cards get distinct short titles within seconds. Rename one chat immediately after sending and confirm the manual name sticks. Temporarily point to a missing claude binary and confirm the placeholder remains.
