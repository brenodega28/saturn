---
title: Auto-allow file changes inside temp folders
status: done
version: 1
workers:
  - {role: builder, name: Builder, reason: "One change in Config/ShellRisk.swift, PermissionProfiles.swift and their tests; too coupled to split"}
  - {role: checker, name: Reviewer, reason: "Fresh eyes on the security boundary: tries to sneak non-temp writes past the new rule"}
owner: ""
linked_runs: [25]
created: 2026-11-25
---

## Summary

Checkers and QA agents keep asking the user's OK for routine test housekeeping in temp folders: redirecting build logs into their scratchpad, mkdir/cp/tar into /tmp/checkerN, rm -rf of old scratch data, chmod on a helper script. Saturn's ShellRisk classifier flags these because read-only agents get every `>` and file-changing tool marked risky, and because `$S/...` paths are treated as unknown even when S was just set to a temp path. This change teaches the classifier which paths are temp paths (/tmp, /private/tmp, /var/folders, /private/var/folders, $TMPDIR, and variables or `cd` targets that resolve to them) and allows file-changing and deleting commands whose every target sits strictly inside one, for every agent kind, read-only or not, without asking. Read-only agents may also use Write/Edit on files inside temp folders. Nothing outside temp folders changes.

## Interfaces

- ShellRisk: new `TempPaths` helper (or equivalent) with `isTemp(_ path: String, variables: [String: String], cwd: String?) -> Bool`: true only for a path strictly below a temp root (never the root itself, never a bare glob at the root such as /tmp/*), after expanding $VAR/${VAR} and standardizing `..`
- ShellRisk.needs: tracks `NAME=value` assignments, `export NAME=value`, `NAME=$(mktemp …)` (treated as temp) and `cd <dir>` across the commands of one command line, and passes them to path checks
- redirectNeed: a redirect whose target is a temp path yields no need, for read-only agents too
- classify/fileChangingRule: rm, rmdir, unlink, mkdir, touch, chmod, ln, tee, sed -i, perl -i, unzip, tar -x/-c, git init, git clone return no risky need when every path they change is a temp path (cp: destination only; mv: sources and destination; tar: -C dir / -f archive, else cwd; git clone: target dir, else cwd)
- PermissionPolicy.assess / permissionDecision: Edit/Write/MultiEdit/NotebookEdit to a temp path is allowed for read-only agents instead of denied

## Out of scope

- kill, pkill, killall, osascript, launchctl, defaults and other process/system commands, even when they mention tmp paths
- Network rules (curl etc.) and package installs
- Any change to paths outside temp folders, including the agent's own worktree rules
- UI or settings for configuring extra temp roots
- Sandbox or Claude Code-level permission settings

## Acceptance criteria

- [x] For a read-only policy, `swift build > /tmp/checker8/build.log 2>&1` produces no ask
- [x] For a read-only policy, `mkdir -p /tmp/checker8/src && git -C /repo archive main | tar -x -C /tmp/checker8/src` produces no ask
- [ ] `S=/private/tmp/claude-501/x/scratchpad; mkdir -p $S/data; rm -rf $S/data; cat > $S/run.sh <<'EOF'\necho hi\nEOF\nchmod +x $S/run.sh` produces no ask for both read-only and developer policies
- [x] `swift test 2>&1 > $TMPDIR/t.log` and `D=$(mktemp -d); cp file.txt $D/` produce no ask
- [x] `cd /tmp/q7 && mkdir c d && git init repo` produces no ask
- [ ] Still asks: `rm -rf /tmp`, `rm -rf /tmp/*`, `rm -rf /tmp/../Users/x`, `rm -rf $HOME/tmp`, `rm -rf $S/x` when S is unset or set to a non-temp path, `mv ./Sources/a.swift /tmp/`, `cp /tmp/a ./b` for read-only agents, `chmod 777 ~/x`
- [x] Still asks: `pkill -f /tmp/q7/daemon` and `osascript` regardless of tmp mentions
- [x] A read-only agent's Write to /private/tmp/.../scratchpad/x.py is allowed; its Write to a repo file is still denied
- [x] Existing ShellRiskTests, PermissionRoutingTests and related suites pass unchanged except where a case is deliberately updated by this spec

## Verification

Run `swift test` in Packages/SaturnCore. New ShellRiskTests cases cover every acceptance example (allowed and still-asked lists), driven through PermissionPolicy.shellNeeds/assess for both the reviewer (read-only) and developer profiles. Additionally replay the real past requests from the permissionRequest table that mention tmp/var/folders through the classifier and confirm the tmp-only ones no longer ask while the kill/osascript/launchctl ones still do.
