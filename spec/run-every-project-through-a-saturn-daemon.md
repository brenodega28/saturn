---
title: Run every project through a Saturn daemon
status: done
version: 2
workers:
  - {role: claude-code, name: Daemon Dev}
  - {role: qa-engineer, name: QA}
owner: ""
linked_runs: [86]
created: 2026-11-14
---

## Summary

Move the engine out of the Mac app into a headless daemon, `saturnd`, so runs keep going when the computer you watch them from is off. Every project belongs to a daemon. Local projects use a daemon on this Mac, installed as a launchd agent. Remote projects use a daemon on a macOS server, installed and reached over SSH. Each daemon owns its own SQLite database, data folder, agents, MCP server, hooks, checks and workflow driver. Agents run as local processes on that machine, so the current `ssh -T` wrapper and reverse tunnel go away. The Mac app becomes a client that can attach to many daemons at once (a fleet). Several Macs can attach to one daemon. Approvals and questions wait on the daemon until any attached client answers. To keep the UI change small, the client keeps a read-only replica of each daemon's database, fed by a change stream, so the existing GRDB-backed feeds keep working. Every action (send a message, approve, start or stop a run, spawn an agent) goes to the daemon as a command. On servers, the daemon is a LaunchAgent in the logged-in user's GUI launchd domain (option a: the server stays logged in at the console). The work lands in four phases, delivered in one run, in order, with a commit per phase. Phase 1: extract the daemon and protocol, and run it locally behind the app. Phase 2: the app becomes a pure client of the local daemon, and the in-process engine is removed from it. Phase 3: remote install and attach, the fleet sidebar, and moving SSH projects onto remote daemons. Phase 4: several clients per daemon.

## Interfaces

- New executable target `saturnd` (macOS 26, depends on SaturnCore), bundled in the app at `Saturn.app/Contents/Helpers/saturnd`. CLI: `saturnd serve [--data-dir <path>]` (runs the engine and listens), `saturnd attach` (bridges stdin/stdout to the running daemon's socket, used over SSH), `saturnd version` (prints the protocol and build versions as JSON).
- SaturnCore `SaturnHost`: a new UI-free type that owns everything `AppModel.init`/`launch` wires today: `AppDatabase`, `AgentRuntime`, `AgentWorkflowDriver`, `RunEngine`, `LeadChat`, `IdleCleanupScheduler`, `StallReporter`, the MCP server, `InstanceLock`, recovery and the orphan watchdog. `static func start(paths: AppPaths, secrets: any SecretStore) async throws -> SaturnHost`, `func stop() async`.
- Daemon identity: `<data-dir>/daemon.json` holds `{id: UUID, name, protocolVersion}`. Each daemon has a stable id, and the client namespaces everything by `(daemonID, rowID)`.
- Transport: a Unix domain socket at `<data-dir>/saturnd.sock`, mode 0600. Messages are newline-delimited JSON. Local clients connect directly. Remote clients run `ssh -T <host> ~/.saturn/bin/saturnd attach`.
- Protocol `SaturnProtocol` (in SaturnCore, Codable): `hello {clientID, protocolVersion}` → `welcome {daemon, protocolVersion}` (a version mismatch is refused with an error that tells the client to upgrade the daemon); `snapshot` (the full DB as a SQLite backup stream, plus a change sequence number); `changes {seq, table, op, row}` streamed from a GRDB `TransactionObserver`; `resync` when the client's sequence number is too old; `command {id, name, args}` → `result {id, ok|error}`; `file {kind: transcript|evidence|specDraft|attachment, id}` for data that lives outside the DB (transcripts are tailed as streams).
- Commands cover every engine call the app makes today, about 80 call sites across `.engine`, `.agents`, `.driver`, `.leadChat` and `.database` writes in Saturn/ and SaturnUI. They are grouped into `ChatCommands`, `RunCommands`, `AgentCommands`, `ProjectCommands`, `ApprovalCommands`, `SettingsCommands` and `CodeCommands` (the git, worktree and file reads the Code and Changes tabs need).
- SaturnCore `DaemonClient`: connects, handshakes, keeps `ReplicaDatabase` (a read-only `AppDatabase` at `~/Library/Application Support/Saturn/replicas/<daemonID>.sqlite`) in sync and exposes `send(_ command:) async throws -> Result`. It reconnects with backoff and resyncs from the last sequence number it holds.
- App: `AppModel` holds `[DaemonID: DaemonConnection]` instead of `database`/`agents`/`driver`/`engine`. Feeds (`ChatRequestFeed`, `ChatNotificationFeed`, `PendingPermissionFeed`, pins and so on) observe the replicas. Native alerts, Dock badge, menu bar, run-the-app port forwards and Terminal take-over stay in the app.
- Local daemon lifecycle: the app registers `saturnd serve` as a launchd agent with `SMAppService.agent(plistName:)` on first launch, starts it if it isn't running and connects. Quitting the app doesn't stop the daemon. A menu item "Stop Saturn daemon" stops it.
- Phase 3, remote: `RemoteDaemonInstaller` copies `saturnd` to `~/.saturn/bin/` on the host over SSH, writes `~/Library/LaunchAgents/dev.monoliti.saturnd.plist` (RunAtLoad, KeepAlive), bootstraps it into `gui/<uid>` with `launchctl bootstrap` and verifies it with `saturnd version`. If the versions differ, it upgrades by swapping the binary and restarting with `launchctl kickstart -k`, refusing while a run is active unless the user confirms. If `gui/<uid>` doesn't exist (no console login), it fails with a message telling the user to log in at the server, and to turn on automatic login where FileVault allows it.
- Phase 3, Settings › Servers lists the daemons this Mac knows (local plus remotes) with their status, version, active runs, claude login state and a warning when the host has FileVault on (after a reboot it needs a console unlock, or `sudo fdesetup authrestart` for planned restarts).
- Phase 3, migration: an existing SSH project offers "Move to this server's daemon". It reopens the project on the remote daemon from the same path and branch, and history stays read-only in the local daemon. The SSH agent wrapper, `RemoteTunnel`, `hostGit` swapping and the remote mirror are removed once no project uses them.
- Secrets: API-key mode keeps the key in the keychain of the daemon's machine. A remote daemon stores it in the host user's login keychain through `security add-generic-password`, sent from the client once over the SSH channel, never as an argument.

## Out of scope

- Linux or other non-macOS servers.
- Auto-approve policies or push notifications while no client is attached: approvals and questions simply wait.
- Any transport other than SSH (no open ports, no relay service, no TLS listener).
- System-wide LaunchDaemons or anything needing sudo on servers; turning FileVault off.
- Teams or multi-user permissions on a daemon: every attached client acts as the same user.
- Moving a project and its history between daemons (migrating old SSH projects starts fresh on the remote daemon).
- The iOS companion app, though the protocol should not prevent it.
- Scheduling work across the fleet (picking a server for a run): the user chooses the server when opening a project.

## Acceptance criteria

- [x] Phase 1: `saturnd serve --data-dir <tmp>` starts, takes the instance lock, recovers runs, starts the MCP server and accepts a client on its socket. A second `serve` on the same data dir refuses and exits.
- [x] Phase 1: SaturnCore test: a `DaemonClient` connects to an in-process `SaturnHost`, receives a snapshot, and sees a chat message, run step change and pending permission appear in its replica within 1 s of the host writing them.
- [x] Phase 1: SaturnCore test: a client that disconnects and reconnects resyncs from its last sequence number without a full snapshot, and gets a full snapshot when its sequence number is too old.
- [x] Phase 1: engine test with fake `claude`: feature delivery runs end to end with the engine in `SaturnHost` and every user action (start run, approve plan, answer a question, approve merge) sent as protocol commands.
- [x] Phase 2: the app has no `AgentRuntime`, `RunEngine` or writable `AppDatabase` of its own. A grep of Saturn/ and SaturnUI finds no engine writes outside `DaemonConnection`.
- [ ] Phase 2: on first launch the app registers and starts the local daemon. Quitting the app leaves the daemon and a running build agent alive. Reopening the app shows the run still progressing, with its transcript caught up.
- [x] Phase 2: with the app quit, a run that reaches an approval waits. On reopening, the approval shows in the Inbox and approving it continues the run.
- [x] Phase 2: existing users' data is kept: the daemon opens the same `~/Library/Application Support/Saturn` data folder, and every project, chat and run from before the update is shown.
- [x] Phase 3: adding `bgomes@macserver.local` as a server installs the daemon into `gui/<uid>` on the host and shows it in Settings › Servers with its version, claude login state and the FileVault warning. A project opened on it runs agents as local processes on the host, with no `ssh -R` tunnel.
- [x] Phase 3: on macserver.local, start a feature-delivery run, then quit Saturn on the Mac and put the Mac to sleep or shut it down. Wait for a build step to finish, then wake the Mac and open Saturn: the run has moved on, and its transcript and pins are there.
- [x] Phase 3: a daemon built from a newer app version is upgraded on connect, and an older client attached to a newer daemon gets a clear "update Saturn" message instead of broken data.
- [x] Phase 4: two clients attached to one daemon see the same chats and runs live. An approval answered on one disappears from the other, and a second answer to the same approval is refused cleanly.
- [x] SaturnCore tests pass, the app builds with xcodebuild, and the existing SSH project tests keep passing until phase 3 removes that path.

## Verification

Run the SaturnCore test suite (`swift test` in Packages/SaturnCore) and build the app with xcodebuild. Phases 1–2, by hand: launch the app, start a feature-delivery run on a small local repo, quit the app during the build step, check with `ps` that `saturnd` and the agent's `claude` are still running, wait for the step to finish, reopen the app and confirm the run advanced, the transcript caught up and the pending approval is in the Inbox. Phase 3: repeat this against bgomes@macserver.local (bgomes is logged in at its console; FileVault is on, so don't reboot it), with the Mac's app quit and the Mac asleep during the step. Use a scratch repo under ~/saturn-test on the server and remove the test LaunchAgent afterwards if the user asks. Phase 4: attach a second client with its own replica dir (for example a second data dir via SATURN_DATA_DIR) and answer an approval from one while watching the other.
