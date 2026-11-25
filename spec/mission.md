# Saturn — Mission

**An agentic development environment that puts modern agentic development norms to work, so more of what you build succeeds.**

## Mission

Saturn is an ADE, an agentic development environment, for a solo developer who already ships real code with coding agents and wants the results to be dependable, not just fast.

The teams that get good, consistent code from AI agents don't rely on better prompts. They converged on the same norms: a well-scoped task, a short written plan, agents working in isolation, a deterministic loop of linters, type checks and tests the work must pass with capped retries, a change that reaches review only once that loop is green, a precision-tuned AI first-pass review, and approval by a human who owns the change. Then they feed every repeated mistake back into the rules.

Those norms take a platform team to build and maintain. Saturn gives them to one developer as a native macOS app that runs them the same way every time:

- **A Lead that sizes the crew.** You talk only to the Lead. It plans the work and spins up as many builders and checkers as the task needs: one builder for a small fix, several in parallel for work that splits cleanly.
- **Agents with different skills and objectives.** Builders write the code. Checkers review it, test it end to end, and look for what the builder missed. Agent profiles and skills shape each one for the project, for example a checker focused on performance or a builder for one area of the code.
- **Lightweight spec-driven development.** Anything non-trivial starts as a short spec with scope, out-of-scope and acceptance criteria. The spec opens in [Lavish](https://github.com/kunchenguid/lavish-axi), where you annotate it, talk the plan through with the Lead, and approve it before any code is written.
- **Rails the agents can't bend.** Saturn runs the project's checks itself, outside the agent's session, protects the tests that judge the work, and pins the lines a human must read.
- **Native SSH and worktrees.** Every coding agent works in its own git worktree and branch. A project can live on this Mac or on a remote host reached over SSH, and the work runs where the code is.

The developer Saturn is for:

- **Works alone, across several machines.** A laptop, a desktop, a build server reached over SSH. Each machine runs a Saturn daemon (`saturnd`), runs keep going when the Mac you watch from sleeps, and several Macs can attach to one daemon.
- **Already uses agents daily,** and has seen them cut corners: skipping tests, editing them to go green, duplicating code, declaring "done" too early.
- **Is the only reviewer.** Their review time is the real bottleneck, not agent throughput.
- **Pays for their own usage** and watches spend closely.
- **Owns the outcome.** Nothing they can't explain should reach `main`.

## Vision

Saturn becomes the one place where a developer goes from an idea to a merged, verified change: scoping, planning, building, checking, reviewing, shipping and measuring, without stitching together terminals, editors, CI dashboards and chat windows, and without caring which machine the work runs on.

The evidence is consistent: speed is easy and stability is hard. Agents raise output, but unchecked they also raise PR size, review time, duplication, complexity and bugs. Saturn keeps the speed and pays the stability bill up front, with the harness around the model rather than the model. As the norms of agentic development move, Saturn moves with them, and each project's own rules, profiles and checks get better every week.

### Product experience

The [Saturn design canvas](https://claude.ai/artifact/2rBPXF4C8fJi8RvWDGB9BD) is the reference for how the app looks and behaves. When the app and the canvas disagree, the canvas wins or gets updated, never ignored.

- **Chat-first and calm.** One chat with the Lead per request, in dark or light, instead of a wall of terminals.
- **Decisions come to you.** Questions, approvals and failures appear in the chat they belong to. The chat list shows which ones need you, and the Dock, the menu bar and notifications count them.
- **One workspace, every machine.** Chats and projects from every attached daemon sit side by side, labeled with their machine.
- **Keyboard-first.** ⌘K reaches any chat, project, file or action.
- **Written for humans.** Plain-language specs, summaries and pins. Review shows what needs a person and says why.
- **Cost always visible.** Spend shows on every run and agent, and before a plan starts.
- **Guided start.** Onboarding runs the deterministic setup, then the Lead reads the project, writes its mission and vision, and proposes agent profiles and a workflow for it.

## Principles

1. **Rails before autonomy.** Correctness comes from what the agent must pass, not from what it is told. Nothing reaches the developer until its checks are green; retries are capped, and after that the work comes back to the human instead of looping. Autonomy grows only as far as the gates have earned.
2. **Enforce deterministically, and protect the checks.** If a rule matters, it lives in a hook, linter, test or check, and instruction files stay short. Tests are protected code: agents can't edit, disable or work around the checks that judge them, and test changes are reviewed on their own.
3. **Small, planned, isolated changes.** One reviewable unit per task, with acceptance criteria. A lightweight spec for anything non-trivial, and none for a one-sentence diff. Every coding agent works in its own worktree and branch.
4. **The right crew for the task.** The Lead matches the number and kind of agents to the work. Specialists come from agent profiles and skills versioned in the repo, not from a fixed cast.
5. **AI reviews, humans approve.** AI review is a high-precision commenter that points to what matters, never an approver or a rigid gate. A human who can explain the change approves it and owns it, with scrutiny tiered by risk. Review capacity, not agent count, sets the pace.
6. **Close the loop.** A mistake repeated twice becomes one rule, hook or check, encoded once and versioned in the repo.
7. **Measure outcomes, not output.** Track what predicts stability (PR size, review time, rework, duplication), not lines generated or how much code the AI wrote.

## Success criteria

Saturn succeeds when it makes agent work dependable, measured by outcomes rather than by the developer's sense of speed:

- **Nothing unverified reaches review.** Every change presented to the developer has passed its deterministic checks, and no change made them pass by editing or disabling them.
- **Small changes.** PR size stays small and steady as usage grows instead of creeping up.
- **Review stays fast.** Time to review and approve a change stays flat or falls, guided by precise AI comments and pins.
- **Low rework.** Revert and rework rates for agent changes are on par with the developer's own.
- **No quality drift.** Duplication, complexity, warnings and performance in the codebase don't get worse over time.
- **Fewer repeated mistakes.** Corrections the developer makes become rules, checks or profile instructions, and the same mistake stops recurring.
- **Predictable spend.** No run exceeds its budget, and the developer can say what each change cost.
- **Reliable runs.** No lost work across quits, crashes, sleep, rate limits or dropped connections; every run finishes, waits on the developer, or fails with a clear reason.
- **Any machine, same experience.** A project on a remote host works like one on this Mac, and a run started from one Mac can be followed and approved from another.
- **One place to work.** The developer goes from task to merged change without leaving Saturn for a terminal, browser or other tool, unless they choose to.
- **Visible numbers.** The developer can see these metrics in the app, not just trust that they're true.
