---
title: Persistent chat drafts and New chat sidebar entries
status: done
version: 1
workers:
  - {role: builder, name: Builder 1, reason: "One task: the store, page kind, composer binding and sidebar rows all depend on each other, so they can't be tested apart"}
  - {role: checker, name: QA 1, reason: Fresh eyes to run the tests and check every acceptance criterion end to end (qa-engineer skill)}
owner: ""
linked_runs: [14]
created: 2026-11-25
---

## Summary

Today a new chat is an unsaved `.chat(chatID: nil)` page, and the composer keeps its text and attachments in view-local @State (LeadComposer.swift:11-12). As a result an unsent prompt is lost when you navigate away, and the new chat is missing from the sidebar until it is sent. This change adds composer drafts that are saved to disk. Every ⌘N, or any other New chat action, creates a new draft entry right away, and the sidebar lists it as "New chat 1", "New chat 2" and so on. The draft keeps its prompt and attachments (images and pasted text) across navigation and app restarts. When it is sent, it turns into the real chat in the same page. The draft entry is removed only when you send it or delete it from the sidebar. Existing chats also keep an unsent message, with its attachments, when you switch away or quit.

## Interfaces

- ChatDraft (new, EnsembleCore): Codable struct { id: UUID, projectID: Int64, number: Int, createdAt: Date, updatedAt: Date, text: String, attachments: [ChatAttachment] }
- ChatDraftStore (new, EnsembleCore): file-backed store under AppPaths root `drafts/<daemonID>/`. Methods: newDrafts(), createNewDraft(projectID:) -> ChatDraft (number = lowest unused positive number across that daemon's new drafts), save(_:), deleteNewDraft(id:), chatDraft(chatID:) -> PendingMessage?, setChatDraft(_:chatID:), clearChatDraft(chatID:). Saves are debounced or coalesced so typing does not write on every keystroke
- MainPageKind gains `.newChat(draftID: UUID, project: ProjectRef)`, or `.chat` gains a draftID. Pages restored from older saved state with `.chat(chatID: nil)` are migrated into a fresh draft
- DaemonWorkspace.newChat(in:) / startNewChat(in:) / requestNewChat(): always create a new draft and open its page, never reuse an existing one
- DaemonWorkspace.adoptNewChat: replaces the page for the draft that was sent (matched by draft id, not just 'the nil-chat page of this project') and deletes that draft
- LeadComposer: text and attachments bind to the draft (new chat) or the per-chat draft (existing chat) instead of @State, and are cleared once a send is accepted. A send that fails and is returned to the composer still restores into the draft
- ChatSidebar ChatList: new drafts show as rows titled 'New chat N' among the open chats, sorted by updatedAt with the others, showing the project name and a preview of the draft text. Clicking one opens it. The context menu has 'Delete draft' and a hover × deletes it. The empty state checks drafts too

## Out of scope

- Per-draft workflow/model/effort options: these stay per project (NewChatOptions)
- Syncing drafts between Macs or storing them on the daemon. Drafts are local to this Mac, kept per daemon
- Drafts for worker/agent composers or line-comment composers
- Renaming draft entries: they keep the 'New chat N' title until sent

## Acceptance criteria

- [x] Pressing ⌘N three times adds 'New chat 1', 'New chat 2' and 'New chat 3' to the sidebar right away, each with its own empty page
- [x] Typing a prompt and attaching an image and a pasted-text attachment in 'New chat 2', then opening another chat and coming back, shows the same text and attachments
- [x] After quitting and relaunching the app, all draft entries are still in the sidebar with their text and attachments
- [x] Leaving a draft empty and opening something else does not remove its entry. Closing its tab does not remove it either, and clicking the sidebar row reopens it
- [x] Right-click > Delete draft, or the row's ×, removes the entry and its file on disk. If the draft's page is open, that page closes
- [x] After deleting 'New chat 1' while 'New chat 2' exists, the next ⌘N creates 'New chat 1' (lowest unused number)
- [x] Sending from a draft creates the real chat in the same page, removes the draft entry, and clears the saved draft. If the send fails, the message goes back into the draft
- [x] In an existing chat, typed-but-unsent text and attachments survive switching chats and restarting the app, and are cleared after a successful send
- [x] Drafts of a project that is closed or removed don't show in the sidebar and don't crash anything
- [x] swift test --package-path Packages/EnsembleCore passes, with new tests for ChatDraftStore: numbering, save/load round trip with image attachments, delete, and chat drafts
- [x] The app target builds

## Verification

Run `swift test --package-path Packages/EnsembleCore` and build the app with xcodebuild (project.yml / XcodeGen). Then do a manual pass in the running app: create three drafts with ⌘N, fill one with text, an image and a paste, navigate away and back, quit and relaunch, delete one and check the numbering, send one and confirm it becomes a real chat, and type in an existing chat, switch away, relaunch and confirm the text is still there.
