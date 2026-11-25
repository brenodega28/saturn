---
title: "Lead chat: keep new messages above the composer and follow the thinking lead"
status: done
owner: ""
linked_runs: [70]
created: 2026-11-03
---

## Summary

In the lead request chat, a message you send lands behind the floating composer, and while the lead is thinking you have to keep scrolling down by hand. Cause: in `ChatColumn.leadChat` the `LeadComposer` floats over the chat in a `ZStack(alignment: .bottom)`, and the chat leaves room for it with a fixed 150pt bottom padding. `RequestChat.scrollToEnd` calls `proxy.scrollTo(id, anchor: .bottom)`, which puts the item at the viewport's bottom edge, right behind the composer. The composer also grows past 150pt with multi-line text or attachments. Following is split between `ScrollViewReader.scrollTo` and `FollowsBottom`'s `scrollPosition`, and the two fight each other. `FollowsBottom` only reacts to a new latest transcript entry, not to the thinking or reply row growing taller, and its 48pt "near bottom" check misreads the 150pt padding. The fix: reserve the composer's real height as a bottom safe-area inset, so the content and `.bottom` anchors end above it. Then use one follow-the-bottom mechanism that reacts to content height changes, keeps following while you're at the bottom, and always jumps to the bottom when you send.

## Interfaces

- `ChatColumn.leadChat` (Saturn/Views/V4/ChatColumn.swift): the composer goes in a `.safeAreaInset(edge: .bottom)` (or a measured equivalent) instead of a bottom-aligned ZStack overlay, so the scroll view's bottom inset matches the composer's actual height
- `RequestChat` and `NewRequestHeldSends` (Saturn/Views/Lead/RequestChat.swift, LeadView.swift): drop the hard-coded 150pt bottom padding and use a single bottom-follow mechanism instead of the mix of `proxy.scrollTo(..., anchor: .bottom)` and `followsBottom`
- `FollowsBottom` (Saturn/Views/Agents/Transcript/TranscriptEntryView.swift): may be extended to follow content-height growth, and to accept a 'force to bottom' trigger for the user's own sends. Its other callers must keep working
- `DirectChatView`: gets the same treatment if it shows the same symptoms (sent bubble hidden, no follow while waiting)

## Out of scope

- Restyling the composer or the chat bubbles
- Changing how messages are held, sent or cancelled
- The agent session transcript view, other than keeping `followsBottom` working there

## Acceptance criteria

- [x] Sending a message in an existing request chat shows the new bubble (held or sent) fully visible above the composer, never behind it
- [x] This still holds when the composer is taller than one line (multi-line text, pasted-text or image attachments)
- [x] While the lead is thinking, streaming a reply or running tools, the chat stays pinned to the bottom with no manual scrolling. The growing thinking row and new messages stay visible above the composer
- [x] If the user scrolls up while the lead is working, the chat stops following and doesn't yank them back. Scrolling back near the bottom resumes following
- [x] Sending a message always jumps to the bottom and resumes following, even if the user had scrolled up
- [x] Opening a request chat starts at the bottom with the last item visible above the composer
- [x] Jumping to a message from a chat link (`chatHighlight`) still centers and highlights that message
- [x] The last item can be scrolled fully above the composer, and no oversized empty gap is left below it
- [ ] The app builds, and the existing test suites pass

## Verification

Build and run the app. In a request chat with history: (1) send a short message, then a multi-line message with an attachment, and check that each bubble is fully visible above the composer; (2) send something that makes the lead think for a while and watch without touching the scroll, checking the view keeps the thinking row and reply in view as they grow; (3) scroll up mid-reply and check it stays put, then scroll back down and check it follows again; (4) scroll up and send, and check it jumps to the bottom; (5) open a chat link to an older message and check it is centered and highlighted; (6) repeat 1–2 in a direct agent chat. Run the existing test suites (`swift test` in Packages/SaturnCore and the app scheme's tests via xcodebuild).
