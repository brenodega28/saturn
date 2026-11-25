---
title: "Chat inspector: spec and permission requests"
status: done
owner: ""
linked_runs: [59]
created: 2026-10-29
---

## Summary

Match the "In the frame · Chat" design: when the Chat tab is the active editor and a request is selected, the right-hand inspector shows that request's Permission requests and its Specfile. Both are removed from the chat thread. Today the Chat tab has no inspector subject (Workbench+BuiltIns.swift:97 returns nil for everything but Workflows), the spec card sits above the thread (RequestChat.swift:21), and permission cards are thread rows (RequestChat.swift:194). Behavior stays the same (Allow once / Allow for this run / Deny, Open in editor); only where it appears changes. Exception: when a new pending permission request arrives for the request on screen while the inspector is hidden, the inspector opens on its own.

## Interfaces

- InspectorSubject gains `.chat(project: Int64, request: Int64)` with Kind `.chat` (title "Chat"); `project` and `kind` switches are updated.
- The `section` EditorKindSpec's `inspectorSubject`: for `item.tab == .lead`, return `.chat(project:request:)` from `model.selectedRequest(in:)`; return nil when no request is selected (new request / direct chat). The Workflows case is unchanged.
- A `ChatInspector` view registered as one InspectorTabSpec for `.chat` (one tab, so no segmented control). Sections, top to bottom: (1) "Permission requests" header with a count of pending requests; one compact card per pending request showing agent, capability chip, command in monospace, run/agent context and the Allow once / Allow for this run / Deny buttons, calling `model.answerPermission(_:decision:)`; below them a short history of answered requests for this chat (✓/✕, decision, agent, command, time); an empty state when there are none. (2) "Specfile": status pill (SpecStatus title/color), relative path, title, summary, interfaces, out of scope, acceptance criteria (with checked state), verification, from `SpecDocument`; an "Open in editor" button calling `model.openSpec`; an empty state when the request has no spec; an unreadable-spec message when `document` is nil.
- The PermissionCard and SpecDraftCard rows are removed from RequestChat. `.permission` LeadMessages are no longer rendered in the thread (filtered out or rendered as EmptyView). The spec still reaches the ProposalCard 'Spec attached' link as it does now.
- Auto-open: when the number of pending permission cards for the selected request goes up while the Chat tab is active and the inspector pane is hidden, open the inspector pane (WorkbenchState pane `.inspector`). It doesn't reopen for requests that were already pending, and doesn't close it again on its own.
- The data the inspector needs (pending and answered permission cards for a request, the spec draft) comes from existing AppModel APIs (`requestThread(for:in:)` / LeadMessage `.permission` items, `specDraft(for:)`), refreshed the way RequestChat refreshes today (the leadChatRevision change plus polling).

## Out of scope

- The design's 'Always here' permission option and saving to permissions.yaml.
- An 'Approve spec' action or any change to spec status.
- Any change to permission routing, the Inbox path or the decisions themselves.
- An inspector for the new-request or direct-chat states.
- Visual changes to other inspectors.

## Acceptance criteria

- [x] With the Chat tab active and a request selected, the inspector header reads "Chat" and shows the Permission requests section above the Specfile section, laid out as in the design.
- [x] A pending permission request appears in the inspector with Allow once / Allow for this run / Deny. Each button gives the same result as the old chat card did, and the request then moves into the history list with its decision.
- [x] Neither a permission card nor the spec card appears anywhere in the chat thread or above it.
- [x] The Specfile section shows the spec draft's status, path, title, summary, interfaces, out of scope, acceptance criteria and verification, and Open in editor opens the spec. With no spec it shows an empty state.
- [x] The pending count in the section header matches the number of pending requests and updates when one is answered.
- [x] With the inspector hidden, a newly arriving permission request for the request on screen opens the inspector. Requests that were already pending don't reopen it after the user closes it.
- [x] Switching to another request updates the inspector to that request. Selecting New request (or a direct chat) shows the inspector's 'No selection' state.
- [x] The ProposalCard 'Spec attached' link still works.
- [x] No code comments are added.
- [x] `swift test` in Packages/SaturnCore passes and the app builds with xcodebuild.

## Verification

Build the app with xcodebuild and run `swift test` in Packages/SaturnCore. Manual check: open a lead chat that has a spec draft and start a run where a builder runs an unlisted command (e.g. `java -version`). Confirm the request shows up only in the inspector, that the inspector opens on its own if it was hidden, that each of the three decisions works and moves the request into history, that the Specfile section matches the spec, and that Open in editor works. Compare the inspector to the 'In the frame · Chat' artboard.
