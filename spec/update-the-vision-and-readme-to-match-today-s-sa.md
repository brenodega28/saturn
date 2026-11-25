---
title: "Update the vision and README to match today's Saturn"
status: done
version: 1
workers:
  - {role: builder, name: Docs Writer, reason: "One builder: the three docs share the tagline and wording, so splitting them would interfere."}
  - {role: checker, name: Docs Reviewer, reason: Fresh eyes to check every claim against the code and the acceptance criteria.}
owner: ""
linked_runs: [30]
created: 2026-11-25
---

## Summary

spec/mission.md still describes Saturn as a toolkit for a solo developer on one machine, with the tagline 'Agents propose, rails verify, humans approve.' Saturn now works differently. It is an ADE (agentic development environment) that applies modern agentic development norms to raise the odds that the work succeeds. It has a Lead that starts builders and checkers based on how hard the task is; agent profiles with their own skills and goals (correctness, review, QA and performance, through custom checkers); lightweight spec-driven development, where you talk the plan over with the Lead in Lavish; and built-in SSH, saturnd daemons and git worktrees. This change rewrites mission.md in the format onboarding now uses: a title, then Mission and Vision sections, followed by the Principles and Success criteria, revised. It replaces the tagline, keeps the target user as a solo developer who now works across several machines and remote hosts, and updates README.md and the parts of spec/roadmap.md that contradict the new vision. Docs only, no code changes.

## Interfaces

- spec/mission.md: '# Saturn' title + new tagline, '## Mission', '## Vision', then '## Principles' and '## Success criteria' (revised). The Product experience and Target user content is folded into Mission/Vision or kept as short subsections.
- README.md: new tagline, an intro calling Saturn an ADE, a 'What you get' list covering the Lead that sizes the crew, agent profiles and skills, Lavish specs, SSH and remote daemons, and worktrees, plus an updated 'How it works'. The Development, Layout and Releases sections are updated where they are stale (e.g. mention the saturnd daemon target).
- spec/roadmap.md: fix only the statements that contradict the new vision: the 'Solo developer, one machine' MVP row, the IDE-style app shell decision (now chat-first), the 'Agents always run on the Mac' and 'one machine' wording, and the intro tagline. Phase history stays as written.

## Out of scope

- Any code, config or .saturn/ changes
- Rewriting the roadmap's phase history or adding new phases
- Editing other specs in spec/
- Changing the bundled onboarding instructions

## Acceptance criteria

- [x] mission.md starts with a title and tagline, then has Mission and Vision sections, followed by Principles and Success criteria
- [x] The old tagline 'Agents propose, rails verify, humans approve' is gone from mission.md, README.md and the roadmap intro, replaced by one new tagline about an ADE that applies modern agentic norms
- [ ] mission.md and README both describe: the Lead spawning builders/checkers according to task difficulty; agent profiles with different skills and objectives for correctness and performance (custom checkers); lightweight spec-driven development with Lavish as the interface for talking to the Lead about the plan; built-in SSH, remote daemons and worktrees
- [ ] The target user is a solo developer working across several machines and remote hosts, and no doc says 'one machine' as a limit
- [x] Every feature claim in the README matches the code (e.g. the workflow end action, GitHub/push behavior, daemon, SSH); nothing describes a feature that doesn't exist
- [ ] The roadmap no longer contradicts the vision (MVP table row, app-shell decision, mobile/Mac-only wording); phase records are untouched
- [ ] Writing follows the repo's plain, short style; links (design canvas, Lavish, Kun Chen) are kept

## Verification

Read the three docs side by side with the source: check the README claims against Packages/SaturnCore (Daemon, Remote, Worktrees, Lavish, Workflow end actions) and .saturn/workflows, grep for 'one machine' and the old tagline, and check that every relative link in README resolves.
