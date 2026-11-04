---
title: Show pending command approvals in the left sidebar
status: done
owner: ""
linked_runs: [81]
created: 2026-11-04
---

## Summary

When an agent working on a chat asks to run a command that needs the user's OK, Ensemble posts an Allow/Deny permission card in that chat (LeadMessage kind .permission, permissionStatus .pending) instead of an Inbox item. The sidebar's request rows only look at Inbox items and run status, so a chat blocked on an approval shows its normal step label and no badge. This change makes the sidebar show a "Needs approval" status for any chat with a pending permission card, so the user can see which chat is waiting on them.

## Interfaces

- EnsembleCore: an AppDatabase read that returns pending permission-card counts per task for a project (e.g. `pendingPermissionCounts(projectId:) -> [Int64: Int]`), from LeadMessage rows with kind == .permission and permissionStatus == .pending
- AppModel: a way for sidebar views to get pending approvals per request that refreshes when a card is created or answered (reuse an existing revision/observation path such as leadChatRevision, or add one)
- AppModel.requestStatusLabel(of:latestRun:needsYouTaskIDs:) returns "Needs approval" when the request has a pending permission card
- ProjectSidebar RequestRow / ProjectGroup: status dot, badge count and collapsed-project attention dot account for pending approvals

## Out of scope

- Approving or denying directly from the sidebar
- Changes to the bottom status bar, Inbox, or macOS notifications
- Changing how permission requests are routed or stored

## Acceptance criteria

- [x] A chat with at least one pending permission card shows "Needs approval" as its sidebar subtitle, taking priority over "Needs you" and over the run step label
- [x] That chat's status dot is the orange needs-you color while the approval is pending
- [x] The chat row's orange badge count includes its pending approvals (added to the existing needs-you count) and stays hidden for the currently open chat, as today
- [x] A collapsed project with a chat that has a pending approval shows the orange attention dot on its header
- [x] Allowing or denying the card (once, for run, or deny) clears the status, dot and badge without restarting the app or switching chats
- [x] A new permission card appears in the sidebar status without restarting the app or switching chats
- [x] The VoiceOver label of the row includes the "Needs approval" status
- [x] Permission requests that go to the Inbox (agents with no owning chat) keep their current behavior
- [x] New core logic has unit tests in EnsembleCoreTests; the full EnsembleCore test suite passes and the app builds

## Verification

Run `swift test` in Packages/EnsembleCore and build the app with xcodebuild. Then launch the app, start a chat whose agent runs a command that requires approval (an `ask`-level command in .ensemble/permissions.yaml), switch to a different chat, and confirm the first chat's sidebar row shows "Needs approval" with an orange dot and badge; collapse the project and confirm the header dot. Answer the card and confirm the row returns to its normal status.
