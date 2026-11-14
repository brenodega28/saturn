---
title: Open projects on a remote host over SSH
status: in-progress
owner: ""
linked_runs: []
created: 2026-11-14
---

## Summary

Let the user open a git repository that lives on another machine as an Ensemble project. They type a host (an `~/.ssh/config` alias or `user@host[:port]`), Ensemble connects with the system `ssh`, and they navigate to the folder with a path input that autocompletes directories as they type, as in T3 Code's add-project flow. Once open, the project lives on the host: git, worktrees, Claude Code agents, checks and the run-the-app server all run there over SSH. The Mac only renders state and keeps the database.

The engine currently assumes a local folder everywhere (`Process` with a local cwd, `FileManager` on the project path), so this lands in phases. Each phase ends with something usable. Until a phase lands, the features it covers stay unavailable on SSH projects and say so, instead of acting on a local folder that happens to share the remote path.

## Phases

1. **Connect and browse (done).** SSH host input, folder navigator, remote project record, and the remote command layer. SSH projects open, appear in the sidebar and recents with their host, and show the host, path, branch and tool check (git and claude on the host). Agents, worktrees, checks, the code browser and settings are gated with a notice.
2. **Remote git and worktrees (done).** `GitClient` and `WorktreeManager` run through a command executor (local `Process` or `ssh`), so recovery, worktree create/remove and branch state work on the host.
3. **Remote files (done).** Ensemble's own project files live in a local mirror kept in sync with the host; the code browser reads the host directly. Agent memory and hooks move with agents in phase 4.
4. **Remote agents.** `claude` runs on the host through `ssh -T` with its stream-json stdin/stdout piped back. The Ensemble MCP endpoint is reached through a reverse tunnel (`ssh -R`). The host keeps its own Claude Code login.
5. **Remote checks and run-the-app.** Checks and the dev server run on the host. The detected port is forwarded to the Mac (`ssh -L`) so the localhost link works.

## Interfaces (phase 1)

- EnsembleCore `SSHDestination`: validates what the user typed (no whitespace, no leading `-`) and normalizes `host:port` / `user@host:port` to `ssh://user@host:port`
- EnsembleCore `SSHConfigHosts.parse(_:)`: concrete `Host` aliases from `~/.ssh/config` (skips patterns with `*`, `?` or `!`), offered as suggestions in the host field
- EnsembleCore `SSHClient`: runs one remote command through `/usr/bin/ssh` with `BatchMode=yes`, `ConnectTimeout=10` and connection sharing (`ControlMaster=auto`, `ControlPersist=300`, sockets in a private `0700` folder under `/tmp`), so each folder listing reuses one connection. `run(arguments:in:)` shell-quotes arguments and a working directory for later phases
- EnsembleCore `RemoteHostProbe`: one round trip that returns the host's `$HOME`, `uname -sm`, and the paths of `git` and `claude` (if any)
- EnsembleCore `RemoteDirectoryLister`: lists the subdirectories of a path on the host (with `~` expanded on the host) and marks the ones that are git repositories. Entries are NUL-separated so any file name survives
- EnsembleCore `RemotePathCompletion`: pure logic for the path input. It splits the input into the directory to list and the filter after the last `/`, filters entries case-insensitively (prefix matches first, then other matches), hides dot folders unless the filter starts with `.`, and builds the completion for a chosen entry
- EnsembleCore `RemoteFolderBrowser` (@MainActor @Observable): owns the input, caches listings per directory (one SSH round trip per directory, not per keystroke), and exposes the suggestions, the highlighted row and a loading/error state
- `Project.host: String?` (nil = local). A migration rebuilds the `project` table so uniqueness is `(host, path)` instead of `path`. `AppDatabase.openProject(at:host:)` finds or creates by both
- App: `AppModel.openRemoteFolder(host:path:)` resolves the repository root on the host (`git rev-parse --show-toplevel`) and opens it. `refresh` reads the branch over SSH, and config loading, role migration, check notices, onboarding, the code browser and GitHub polling skip SSH projects. In EnsembleCore, `RemoteProjectUnsupported` makes agent spawning, Lead creation and `RunEngine.start` refuse SSH projects until their phases land
- SwiftUI `RemoteFolderSheet`: a host field with `~/.ssh/config` suggestions and Connect, then the host summary (home, system, git/claude found) and the path input with the suggestion list. ↑/↓ move the highlight, Tab completes the highlighted folder, Return opens the typed folder (or descends into the highlighted one when the input names a partial match), and clicking a row descends. Git repositories carry a badge
- Entry points: Welcome "Open SSH Folder…", File › Open SSH Folder… (no shortcut), the ⌘K palette (it lists File menu commands), and a "+" menu in the sidebar with Open Folder…, Open SSH Folder… and Clone…
- Main window: when the current project is an SSH project, the chat/log area is replaced by `RemoteProjectView` (host, path, branch, tools on the host, Reconnect, and what the next phases bring). The sidebar shows the host under the project name and hides the section tree

## Interfaces (phase 2)

- `GitClient` has two transports: `init(executable:runner:)` (local `Process`, as before) and `init(ssh:)` (each call runs `git` in the folder on the host through the shared connection). `execute(_:in:)` returns the unchecked result; every caller that used to reach into `git.runner` with `git.executable` goes through it, so no git call bypasses the transport
- EnsembleCore `ProjectFileSystem` with `LocalFileSystem` (FileManager) and `SSHFileSystem` (`test -e`, `mkdir -p`, `cat`, `printf … > tmp && mv`, the NUL-separated listing, `rm -rf`): exists, create folder, read and write text, list subfolders, remove, and canonical path. The SSH canonical path is purely textual (`.`/`..`/slashes), because `URL.standardizedFileURL` and `resolvingSymlinksInPath` consult the local disk
- `WorktreeManager(repository:git:fileSystem:branchPrefix:)` does all its file work through the file system, including `.git/info/exclude`, `.crew/` and orphan cleanup. `WorktreeManager.make(repository:git:fileSystem:)` reads `branch_prefix` from `.ensemble/project.yaml` on the host. `deleteOrphanedDirectory` is now async
- App: `refreshRemote` runs worktree recovery on the host and fills the project's worktrees and recovery. Debug › Worktrees, Create Debug Worktree and Recover Worktrees work on SSH projects (Reveal is disabled for them). The SSH project view lists the host's worktrees and what the last recovery fixed
- Agents still refuse SSH projects (phase 4), so nothing creates worktrees on the host except the Debug tools

## Acceptance criteria (phase 2)

- [x] Creating a worktree on an SSH project adds `.crew/<agent>` and `crew/<agent>/<slug>` on the host, adds `/.crew/` to the host's exclude file once, and leaves `git status` clean (checked on `orb` from Debug › Create Debug Worktree)
- [x] Recovery on the host prunes worktrees whose folder is gone (keeping the branch) and lists leftover folders in `.crew/`; deleting a leftover folder removes it on the host and refuses paths outside `.crew/` (checked on `orb` in Debug › Worktrees)
- [x] Removing a worktree with its branch removes both on the host (checked on `orb`)
- [x] The SSH project view lists the host's worktrees
- [x] Tests run the real `WorktreeManager` through a fake `ssh`: create, list, remove, prune, orphan cleanup, restore, the exclude entry, the host's branch prefix, file round trips with quotes, `$` and backticks, and textual path normalisation. An opt-in test (`ENSEMBLE_REAL_SSH_HOST`, `ENSEMBLE_REAL_SSH_REPO`) does the same against a real host
- [x] EnsembleCore tests pass and the app builds with xcodebuild

## Interfaces (phase 3)

- EnsembleCore `RemoteMirror` (one per SSH project, under `<app data>/remote/<project id>/files` with a `manifest.json` of SHA-256 hashes beside it). `pull()` copies, in one `tar | base64` round trip, `.ensemble/`, `.claude/skills`, `.claude/settings.json` and the top-level files up to 256 KB (so the setup scanner and run-command detection see `package.json`, `Makefile` and the like). A second round trip fetches the spec folder and any doc paths named in `.ensemble/`. The pull is staged and swapped in whole
- `pendingChanges()` compares the mirror with the manifest; `push()` checks each changed path's hash on the host first and throws `RemoteMirrorConflict` without writing anything if any of them changed there since the pull, otherwise writes (base64, temp file and `mv`) or deletes each file and updates the manifest
- `Project.filesRoot`: the mirror for SSH projects, the folder itself for local ones. Every app call site that reads or writes project files (config, onboarding, workflows, settings, skills, docs, specs, AGENTS.md, memory) uses it; every git call keeps the host path and `AppModel.git(for:)`
- App: refresh pulls the mirror (after pushing local changes), app activation pulls every SSH project, and a loop pushes changes every 2 s, so any write, including from an external editor opened on a mirror file, reaches the host. Pushes and pulls of one project never overlap. A conflict shows an alert naming the files, then the host's versions are pulled. Push errors show in the project overview instead of an alert. Forgetting an SSH project deletes its mirror
- `ProjectScanner.scan(repository:git:files:)` and `AppDatabase.encode(_:as:repository:git:files:sync:)` take the files root and the git repository separately; encoding and the AGENTS.md setup push the mirror before committing on the host
- Code browser: `CodeWorkspace` on a remote `GitClient` lists files with git (subtracting deleted ones), `loadDocument` fetches a file over SSH (size checked first), and `search` runs `git grep -I -i -F --untracked` on the host. `CodeDocument.loading` shows while a file is fetched; Go to Symbol only indexes files already opened
- UI: SSH projects show Overview, Workflows, Source and Settings in the sidebar. Chat, Tasks, Agents, Changes, runs and the run bar stay on the overview until phase 4/5. Settings hides GitHub and Workspaces for SSH projects. Skill plugins (which use the `claude` CLI) stay off until phase 4

## Acceptance criteria (phase 3)

- [x] Opening an SSH project with no `.ensemble/` shows onboarding with what the host's `package.json` implies (checked on `orb`: Node.js, Vitest, base branch `main`); finishing it writes `.ensemble/`, `AGENTS.md` and `CLAUDE.md` on the host
- [x] Workflows, settings and specs read the host's files; a change to a mirror file reaches the host within seconds; a host change shows up after a refresh (checked on `orb`)
- [x] A file changed on both sides is not overwritten: the alert names it and the host's version wins (checked on `orb`)
- [x] Source lists the host's files with added/modified markers and opens them with syntax highlighting (checked on `orb`); text search runs on the host (real-host test; the finder's Text tab wasn't driven in the app)
- [x] Tests: the mirror's selective pull, push of edits/additions/deletions, binary files and awkward names, conflict refusal, empty and missing repositories; remote code listing, reading, binary/size detection and search; opt-in real-host tests for browsing, worktrees and code
- [x] EnsembleCore tests pass and the app builds with xcodebuild

## Out of scope (phase 1)

- Everything listed under phases 2–5
- Password or keyboard-interactive authentication (keys and the ssh agent only, through BatchMode). Unknown host keys are not accepted automatically: the error tells the user to connect once in Terminal
- Cloning onto a remote host
- Editing `~/.ssh/config` from Ensemble

## Acceptance criteria

- [ ] Welcome, File menu, ⌘K and the sidebar "+" menu all open the SSH folder sheet
- [x] Typing a host alias from `~/.ssh/config` suggests it; Connect shows the host's home, system and whether git and claude were found; a failure shows ssh's message (with the Terminal hint for host-key failures)
- [x] The path input starts at `~/` and lists that directory's folders; typing filters without a new SSH call; typing past a `/` lists the next directory; Tab, ↑/↓, Return and clicks behave as described above; dot folders show only when the filter starts with `.`
- [ ] Opening a folder inside a repository opens its root as a project named after the folder, with the host shown in the sidebar and in recents; opening a non-repository shows the "Not a git repository" alert
- [ ] The same path on the Mac and on a host are two different projects; reopening an SSH project from recents goes back to the same record
- [x] An SSH project never reads, writes or migrates a local folder at the same path (config loading, role migration, check notices, onboarding, the code browser and worktree recovery are skipped; agents and runs refuse to start)
- [x] Unit tests cover destination parsing, ssh config parsing, path completion, listing parsing, the browser cache, the SSH command line, and the `(host, path)` migration, with a fake `ssh` executable standing in for a real host
- [x] EnsembleCore tests pass and the app builds with xcodebuild

## Verification

Run `swift test --package-path Packages/EnsembleCore` and build the app with xcodebuild. Against a real host with key auth (or `localhost` with Remote Login on): open the sheet from each entry point, connect with an alias, navigate with typing, Tab, arrows and clicks into a repository, open it, and check that the sidebar, recents and the remote project view show the host, path and branch. Reopen it from recents. Open a local project with the same path and confirm it is a separate entry.
