---
title: "Saturn Remote: mobile web client"
status: in-progress
version: 1
workflow: feature-delivery
workers:
  - {role: builder, name: Daemon Bridge Dev, reason: "Owns Packages/SaturnCore (RemoteAccessServer, auth, allowlist, remote.* commands, Package.swift) and the Mac Settings › Remote access pane; tested with Swift tests over a real WebSocket", model: opus}
  - {role: builder, name: Web Client Dev, reason: Owns web/ and scripts/build-remote.sh plus the committed Resources/Remote/dist; builds the Mobile v6 UI against the existing protocol using a fixture-replaying mock WS server, model: opus}
  - {role: checker, name: QA, reason: "Tests the combined work end to end: pairing, live sync, commands from the phone, allowlist and bind checks", skills: [qa-engineer], model: opus}
owner: ""
linked_runs: [39]
created: 2026-11-25
---

## Summary

Let the user control Saturn from a phone or another computer. saturnd gets an opt-in HTTP + WebSocket listener (Hummingbird 2) that serves a prebuilt React + Vite + TypeScript PWA and carries the daemon's existing ProtocolMessage JSON (hello → snapshot → changes/live, command/result, file chunks) over WebSocket. The web client is just another daemon client, not a new API. Access is off by default, binds only to loopback and the Tailscale interface, needs a pairing token shown as a QR code in the Mac app, and only allows commands on a fixed allowlist, so a remote client can chat, answer, approve and run but can't exec code, write files or touch keys. The UI follows the canvas design "Mobile v6" (https://claude.ai/artifact/2rBPXF4C8fJi8RvWDGB9BD#page-3c013dea42ab): the chat screen; a left Chats drawer with search, project chips and Needs you / In progress / Not started / Finished groups; a right drawer with Task, Project and Log tabs, using the v6 dark and light tokens. The work is split into two builders that can't interfere. The wire protocol already exists in SaturnProtocol.swift and doesn't change, so the bridge is tested with Swift tests over a real WebSocket, and the client is tested against a mock WebSocket server that replays recorded protocol fixtures. Neither needs the other's branch to pass its own tests.

## Interfaces

- saturnd: `RemoteAccessServer` (Hummingbird 2, a new SaturnCore dependency): `GET /` and static assets from `SaturnCore/Resources/Remote/dist`, `GET /ws` WebSocket upgrade. Each text frame is one `ProtocolMessage` JSON, the same as a `LineChannel` line
- Auth: `POST /pair {code}` → `{token}` (one-time 6-digit code shown in the Mac app, 5-minute expiry). WebSocket needs `Authorization: Bearer <token>` or `?token=`; otherwise it closes with 4401. Tokens are stored in the daemon's AppPaths and can be revoked
- Command allowlist for remote clients: chat.* (except chat.delete), run.* (except run.stageForMergeTool), approval.*, agent.send, agent.perform, agent.setModel, settings.status, code.readFile (read-only), file requests for transcript/specDraft/attachment. Any other command returns CommandFailure `.forbidden` (new code)
- Settings commands: `remote.status` → {enabled, port, addresses, pairedDevices}; `remote.setEnabled {enabled, port?}`; `remote.beginPairing` → {code, url, expiresAt}; `remote.revoke {deviceID}`. Not callable by remote clients
- Bind: 127.0.0.1 plus the Tailscale (100.64.0.0/10, utun) addresses only, default port 7878. Never 0.0.0.0
- Mac app: Settings › Remote access pane with an on/off toggle, port, a 'Pair a device' button showing the QR code (URL + code), and a paired devices list with Revoke
- web/: Vite + React + TS project. `npm run dev` proxies /ws and /pair to the daemon. `scripts/build-remote.sh` builds into Packages/SaturnCore/Sources/SaturnCore/Resources/Remote/dist (committed and added to Package.swift resources)
- Web client modules: `protocol.ts` (TS types mirroring ProtocolMessage, CommandEnvelope, DBValue), `replica.ts` (in-memory tables built from snapshot + ChangeBatch, resync on `resync`), `store.ts` (Zustand), screens Chat, ChatsDrawer, DetailsDrawer(Task|Project|Log), Pairing
- PWA: manifest, icons from the app icon, a service worker for the app shell (vite-plugin-pwa), installable from iOS Safari's Add to Home Screen

## Out of scope

- A native iOS app
- Web Push notifications (next step, once the PWA works)
- Exposing on 0.0.0.0, public internet, or relaying through a cloud service
- Full diff review screen and line pins. 'Review changes' opens a changed-files list (run.diffSummary) with Approve/Request changes. Per-line pins stay on the Mac
- Creating, cloning or opening projects, onboarding, editing .saturn config, Usage and Settings screens. The drawer's Usage/Settings buttons are hidden in v1
- Lavish spec editing. Specs show read-only in the chat with Approve & start / feedback via chat
- The design's 'Open PR' button: Saturn has no GitHub integration, so it becomes 'Push' (run.push), as the Mac app does
- Multi-daemon fleet view. The web client shows the daemon that serves it
- Changing the wire protocol or the replica schema

## Acceptance criteria

- [ ] Remote access is off by default; with it off, nothing listens on any TCP port
- [ ] When on, the listener binds only to 127.0.0.1 and Tailscale addresses (checked with `lsof -iTCP -sTCP:LISTEN`)
- [ ] A WebSocket without a valid token is closed with 4401; a revoked token is rejected on the next connect and live sockets using it are closed
- [ ] A remote client sending code.exec, code.writeFile, code.removeItem, settings.saveAPIKey, settings.shutdown or remote.* gets `.forbidden`, and the daemon doesn't run it (Swift test)
- [ ] Pairing: the Mac app shows a QR code; opening its URL on a phone and entering the code stores a token, and the code works only once and expires after 5 minutes
- [ ] The web client reaches the same chat list and statuses as the Mac app from snapshot + changes, and updates live within 1 s when a chat or run changes on the Mac
- [ ] Chat screen matches Mobile v6: the header with status dot, title, project tile · host · cost; Lead messages; the spec card; the run event rows; the 'Ready for your review' card with +/− counts, files and checks; and the composer with workflow and model line
- [ ] Sending a message from the composer calls chat.send and the reply streams in
- [ ] Lead questions and permission prompts can be answered (approval.answerQuestion / answerPermission), and spec Approve & start (chat.approveSpec) and run approval/merge/push work from the phone
- [ ] The left drawer lists chats grouped Needs you / In progress / Not started / Finished, with search and project chips filtering, and tapping a chat opens it
- [ ] The right drawer's Task tab shows stages, branch, app runner status, changes, checks and workers; the Project tab shows the summary, stats and agents; the Log tab shows the run timeline
- [ ] Dark and light follow prefers-color-scheme using the v6 token values. Touch targets are ≥44 px, and the layout fits 360–430 px wide with no horizontal scroll, scaling up to tablet/desktop widths
- [ ] The client reconnects with resumeFrom seq after network loss, without a full reload, and shows an offline banner while it is disconnected
- [ ] Installable as a PWA on iOS Safari (manifest + service worker valid in Lighthouse)
- [ ] Dist is committed. `xcodegen generate` + the Xcode build work without Node installed
- [ ] Existing Swift tests pass; new Swift tests cover auth, allowlist, bind addresses and WebSocket framing; web tests (Vitest) cover replica apply/resync and the main screens against the fixture server

## Verification

1) Run the SaturnCore Swift tests and `cd web && npm test && npm run build`. 2) Build and run Saturn, turn on Remote access, and pair from a browser at http://127.0.0.1:7878 (and from a phone over Tailscale, if available). 3) Start a chat on the Mac and check that it appears in the phone's drawer. Send a message from the phone, answer a Lead question, approve a spec, and watch the run update live in Task/Log. 4) Try a forbidden command from the browser console (code.exec) and check that you get `.forbidden`. 5) Revoke the device and check that the socket drops. 6) Turn Remote access off and check with lsof that nothing is listening. 7) Compare the screens with the Mobile v6 artboards at 390 px in dark and light.
