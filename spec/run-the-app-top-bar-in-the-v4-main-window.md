---
title: Run-the-app top bar in the v4 main window
status: in-progress
owner: ""
linked_runs: [83]
created: 2026-11-04
---

## Summary

Add the "Run the app" toolbar from the v4 design (artboard project/V4.dc.html on the Ensemble design canvas, https://claude.ai/artifact/2rBPXF4C8fJi8RvWDGB9BD, page "App v4 · Simple") above the chat and log columns of the main window. It lets the user run the current project's app (dev server) from their own checkout or from any agent's worktree, and stop it. The run command is auto-detected from the project (package.json dev script, Makefile dev target, Procfile) and can be overridden in Settings › Workspaces. Only one app runs per project: starting it on another branch stops the current one. The port is detected from what the server actually listens on, and the bar links to it. The server's output streams into the existing Log column as 'run' rows. When the app quits, or the worktree it runs in is removed, the process and its whole process group are killed. The bar matches the artboard pixel for pixel: 52px glass bar, 16px radius, branch picker, Start/Stop, status line, localhost link and command label.

## Interfaces

- EnsembleCore `RunCommandDetector.detect(in: URL) -> DetectedRunCommand?`: checks in order package.json `scripts.dev` (→ `npm run dev`, or `pnpm`/`yarn`/`bun run dev` when that tool's lockfile is present), a Makefile with a `dev:` target (→ `make dev`), a Procfile (→ runs every process line; shown as `Procfile`); returns the command and where it came from
- `ProjectSettings.runCommand: String` (default empty = use the detected command), decoded with decodeIfPresent so existing projects keep loading
- EnsembleCore `AppRunner` (@MainActor @Observable, one per project): `start(command:in worktree: URL, branch: String, port hint: Int?)`, `stop()`, and state `idle | starting | running(ports: [Int], since: Date) | stopped(exitCode) | failed(message)`. It launches `zsh -lc <command>` in its own process group with PORT/ENSEMBLE_PORT set to the agent's port (base port for the main checkout, when set) and stops it with SIGTERM to the group, then SIGKILL after 5 s. Starting while running stops the old process first
- Port detection: the listening port is the first `http://localhost:<port>` / `127.0.0.1:<port>` / `0.0.0.0:<port>` URL seen in the output, falling back to the TCP ports the process group is listening on (checked every second until found). It is confirmed with `PortProbe.isListening`. Every listening port goes in the status line, and the link opens the first one
- Log: each stdout/stderr line of the server is appended to ActivityLog as a LogEntry with `source: "run"`, the project id, level `.error` for stderr lines that look like errors, `.info` otherwise. Plus lifecycle entries: `make dev · <branch>` (debug) on start, `ready · http://localhost:<port> · <branch>` (info) once a port is detected, `stopped` / `exited with code N` (warning/error)
- SwiftUI `RunBar` in Ensemble/Views/V4/: branch picker button (22px avatar tile, monospaced branch, 'who · place' subline, chevron) opening a 400px listbox popover grouped 'Main' (your checkout of the project) and 'Workers' (every non-archived agent in the project with a worktree: branch, 'Agent name · worktree <path>', colored status word); Start (green when idle, disabled while running); Stop (red tint when running, disabled when idle); hairline divider; status (dot with glow + 'Running'/'Stopped'/'Starting'/'Failed' + detail: '<branch> · up N min · :<ports>' or 'Pick a branch and press Start to run the app from it'); 'localhost:<port> ↗' link opening the default browser (only while running with a port); the command label in monospace
- MainWindowView: RunBar sits at the top of the middle+log area (both columns below it, sidebar to its left), as in the artboard
- Settings › Workspaces: new 'Run command' card showing the detected command (or 'Nothing detected'), a field to override it, Save/Revert
- App quit (applicationWillTerminate) and worktree removal (archiving/cleanup of the agent whose worktree is running) call `AppRunner.stop()` and wait for the group to die

## Out of scope

- Running more than one app per project at once
- Remote projects
- A separate full-output view or terminal for the server (output only goes to the Log column)
- Hot-restarting when the selected worktree changes on disk
- Procfile process managers beyond starting every line in one process group (no foreman/overmind integration)
- The status-bar branch chip from the artboard footer (the footer stays as it is)
- Light mode

## Acceptance criteria

- [ ] The main window shows the run bar above the chat and log columns, matching the artboard's layout, sizes, radii, colors, fonts and copy at 1600×1000 (allowing for real data)
- [ ] RunCommandDetector returns the right command for fixtures with: package.json dev script (npm, pnpm, yarn and bun lockfiles), Makefile dev target, Procfile, and nothing at all. Unit tests cover each case
- [ ] With no override and nothing detected, Start is disabled and the status line says no run command was found, with a link to Settings › Workspaces
- [ ] Setting a Run command override in Settings › Workspaces persists across relaunch and is used instead of the detected one; clearing it falls back to detection
- [ ] The branch picker lists the main checkout and every non-archived agent with a worktree in the current project, with its status; picking one closes the popover and selects it
- [ ] Start runs the command in the selected worktree (or the project folder for Main) with PORT/ENSEMBLE_PORT set when a port exists. Status shows Starting, then Running with the detected port(s) and uptime. The localhost link opens the detected port in the browser
- [ ] Port detection works both from a URL printed in the output and, for a server that prints no URL, from the process group's listening sockets (unit/integration test with a small script server)
- [ ] Server output appears live in the Log column as 'run' rows with the project id; the All and Needs you filters treat them like other entries
- [ ] Stop kills the whole process group (child processes such as a spawned node/vite server are gone afterwards; verified by checking the port stops listening) and the status returns to Stopped
- [ ] Starting on a second branch while one is running stops the first one (its port stops listening) before the new one starts
- [ ] A process that exits on its own shows 'exited with code N' in the status and the Log
- [ ] Quitting Ensemble while the app runs leaves no orphaned processes; archiving or cleaning up the agent whose worktree is running stops the app first
- [ ] EnsembleCore tests pass (swift test in Packages/EnsembleCore) and the app builds with xcodebuild with no new warnings

## Verification

Run swift test in Packages/EnsembleCore (detector, AppRunner start/stop/process-group kill, port detection with a script that spawns a child server) and build the app with xcodebuild. Launch the app on a project with a package.json dev script and at least one agent worktree: start on Main, confirm the Log fills with run rows and the link opens the right port, then switch to the agent's branch and start. Confirm the first server's port stops listening. Stop, confirm nothing is left (`lsof -i :<port>` is empty). Override the command in Settings › Workspaces and relaunch. Quit Ensemble mid-run and confirm no orphans. Finally, screenshot the window at 1600×1000 and compare it against project/V4.dc.html on the design canvas (qa-review skill).
