---
title: macOS notifications for lead-chat actions and finished runs
status: done
owner: ""
linked_runs: [64]
created: 2026-10-31
---

## Summary

Today `InboxNotifier` (Ensemble/AppModel+Inbox.swift) sends macOS notifications only for new Inbox items, and clicking any of them opens the Inbox. Some events reach the user only in a lead chat and never notify them. This change adds notifications for four events: permission cards in a lead chat, run proposals, the lead finishing a turn with a reply, and a run finishing. Each event gets its own toggle in Settings › Notifications. A notification is skipped when Ensemble is frontmost and the user is already looking at that chat. Clicking a notification opens the chat it's about. Inbox notifications open their own item through `openInboxItem`, not the Inbox list.

## Interfaces

- Notification events: `permissionCard` (a `.permission` LeadMessage is inserted), `runProposal` (a `.proposal` LeadMessage is inserted), `leadReply` (the lead's turn ends with a `.lead` message in a chat), `runFinished` (a run reaches succeeded, failed or cancelled)
- Settings › Notifications: a new 'Lead chat' section with one toggle per event, stored in UserDefaults next to the existing `NotificationPreferences` keys (e.g. `notify.chat.permission`). All default to on.
- `InboxNotifier` (or a sibling notifier) posts these notifications. Each carries `userInfo` naming its target (project id plus task id for chats, inbox item id for Inbox items). The `didReceive` handler routes to the target: a chat opens through `showRequest(id:inProjectID:)` with the lead tab selected, and an Inbox item opens through `openInboxItem`.
- Focus suppression: no notification is posted when `NSApp.isActive` is true and the selected project, tab and request are that chat. Inbox-item notifications follow the same rule when the item belongs to the visible chat.
- Only events that happen after launch notify, as `InboxFeed` does today. No notification fires twice for the same message or run.

## Out of scope

- Changing which Inbox kinds exist or their current toggles
- Notification action buttons (Allow/Deny right from the banner)
- Dock badge changes
- Notifications for agents' direct chats outside a lead request

## Acceptance criteria

- [x] A permission card added to a lead chat posts a macOS notification that names the agent and the request.
- [x] A run proposal posts a notification with the proposal title.
- [x] When the lead ends a turn with a reply in a chat, a notification shows the start of the reply.
- [x] When a run finishes (succeeded, failed or cancelled), a notification shows the run title and its outcome.
- [x] Each of the four events has its own toggle in Settings › Notifications. Turning a toggle off stops that event's notifications. All toggles default to on.
- [x] No notification is posted while Ensemble is frontmost and showing that chat. One is posted if the app is in the background or showing a different chat.
- [x] Clicking a lead-chat or run notification brings the app forward and opens that project's lead chat for that request.
- [x] Clicking an Inbox notification opens that item the same way the Inbox's Open button does (`openInboxItem`), not the Inbox list.
- [x] Events from before launch don't notify, and no event notifies more than once.
- [x] No code comments are added (user preference). Existing EnsembleCore tests still pass.

## Verification

Put the logic that can be tested without the UI (event detection, deduping, the suppression decision, routing a notification to its target) in testable units, and cover it with tests in EnsembleCoreTests. Run `swift test` in Packages/EnsembleCore and build the app with xcodebuild. Manual check: with Ensemble in the background, start a feature-delivery run and confirm a notification for the proposal, a permission card, a lead reply and the run finishing. Click each one and confirm it opens the right chat. Then bring that chat to the front and confirm no notification appears. Turn each toggle off and confirm its event stops notifying.
