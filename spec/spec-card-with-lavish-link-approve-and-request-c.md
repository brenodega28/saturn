---
title: "Spec card with Lavish link, Approve and Request changes"
status: done
version: 1
workers:
  - {role: builder, name: Swift Dev, reason: "One builder: the card, approve flow, tunnel and read_chat all touch the same spec/daemon plumbing and can't be tested apart"}
  - {role: qa-engineer, name: QA, reason: Tests the flow end to end on a local and a remote daemon}
owner: ""
linked_runs: [9]
created: 2026-11-25
---

## Summary

Today, after the lead calls draft_spec, the only way to reach the spec is a tab the app tries to open by itself. Nothing is posted in the chat. Lavish errors are swallowed in SpecReviews.specDrafted. For chats on another machine's daemon, Lavish listens only on that Mac's loopback, so the page can't load. The user then sees only the lead saying the spec is done (chat 96 on daemon f4798762). This change makes every draft_spec post a spec card in the request chat. The card has an "Open spec" link to the live Lavish review page, an Approve button and a Request changes button, and shows the Lavish error when the review couldn't start. Approve marks the spec approved and starts a feature-delivery run right away, using the spec as the brief. Request changes opens the Lavish page so the user annotates there. For chats served by a daemon on another Mac, the app forwards the remote Lavish port over SSH, the same way RemoteAppHost forwards app ports, so live review works there too. read_chat also learns to read chats on other machines' daemons, so links with ?daemon= resolve.

## Interfaces

- New LeadMessage kind `.specDraft` (one per draft_spec call, carrying spec version and title) rendered in RequestChat as a SpecCard: title, version, status, criteria count, 'Open spec' link, Approve and Request changes buttons. Older cards for the same request show as superseded (no buttons)
- SpecReviews.specDrafted returns/records the review status (url or error reason) instead of swallowing it; the draft_spec tool result tells the lead the truth (page opened, or why not)
- New daemon command `ChatCommands.ApproveSpec(chatID:)`: marks the draft approved and starts a feature-delivery run for the request with the spec attached (same path as Start on a proposal with the spec), returns the run id or an error
- Request changes: client action that opens/focuses the Spec tab (Lavish page) for the chat; no daemon command
- SpecReviewStatus gains the remote Lavish port so a client on another Mac can forward it; DaemonWorkspace opens an SSH `-L 127.0.0.1:<local>:127.0.0.1:<remote>` tunnel (reusing the RemoteAppHost/SSHClient pattern) and rewrites the session URL to the local port
- read_chat tool gains an optional `daemon` parameter (UUID from ensemble://chat links); ChatReader resolves it against the connected daemons in the workspace and reads that daemon's replica, erroring clearly when that daemon isn't connected

## Out of scope

- Changing the Lavish page contents or the SpecPageRenderer template
- Editing the spec Markdown in the app
- Removing the existing proposal card / Start flow (it stays for runs proposed without approving a spec)
- Publishing Lavish beyond loopback or via lavish-axi share

## Acceptance criteria

- [x] After every draft_spec call, a spec card appears in the request chat without the user doing anything, both for local chats and for chats on another machine's daemon
- [ ] The card's 'Open spec' link opens the Spec tab showing the live Lavish page with annotation controls, for local and other-machine daemons
- [x] When Lavish can't start (no Node, error), the card shows the reason and the draft_spec tool result tells the lead the page did not open; no error is silently swallowed
- [x] Approve marks the spec approved and immediately starts a feature-delivery run for the request, with the spec committed to the run branch exactly as Start does today; the card then shows the run as started
- [x] Request changes opens or focuses the Spec tab on the Lavish page; feedback sent there still reaches the lead as spec feedback
- [x] Re-running draft_spec adds a new card and marks earlier cards for that request as superseded (no Approve/Request changes buttons)
- [x] For a daemon on another Mac, the Lavish port is forwarded over SSH to 127.0.0.1 only, and the tunnel is closed when the review ends or the connection drops
- [x] read_chat with request_id and daemon from an ensemble://chat/<id>?daemon=<uuid> link reads that chat when that daemon is connected, and gives a clear error otherwise
- [x] `swift test --package-path Packages/EnsembleCore` passes with new tests for the spec card message, ApproveSpec, the error surfacing and read_chat's daemon routing; the app builds with `xcodegen generate && xcodebuild -scheme Ensemble build`
- [x] No unnecessary code comments; short, descriptive names

## Verification

Run the EnsembleCore tests and build the app. In the app, open a local project chat, ask for a small feature, and let the lead call draft_spec. Check that a spec card appears, that Open spec shows the live Lavish page, and that Request changes jumps there. Annotate the page and send the note to confirm the lead gets it. Have the lead revise, and check that the old card is marked superseded. Press Approve and confirm a feature-delivery run starts with the spec committed on the run branch. Repeat on a chat served by the other Mac's daemon: the card appears, the page loads live through the SSH tunnel (check `lsof -iTCP -sTCP:LISTEN` shows only 127.0.0.1), and Approve starts the run there. Remove Node from PATH and confirm the card shows the reason. Finally, have a lead call read_chat on a ?daemon= link to the other machine.
