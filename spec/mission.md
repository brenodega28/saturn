# Saturn — Mission

Saturn formalizes the proven workflow for agentic development: **agents propose, rails verify, humans approve.**

The teams that get good, consistent code from AI agents don't rely on better prompts. They converged on the same pipeline: a well-scoped task, a written plan, an agent working in isolation, a deterministic loop of linters, type checks and tests it must pass with capped retries, a change that reaches review only once that loop is green, a precision-tuned AI first-pass review, and approval by a human who owns the change. Then they feed every repeated mistake back into the rules.

That pipeline takes a platform team to build and maintain. Saturn gives it to a solo developer on their own machine, as a native app that runs it the same way every time.

Saturn is a complete developer toolkit for agentic coding, in the way Xcode and Android Studio are for their platforms. It is one integrated, polished environment where the developer scopes work, runs agents, verifies, reviews, ships and measures, instead of stitching together terminals, editors, CI dashboards and chat windows. Every stage of the pipeline has a first-class home in the app, and the tools work together so they feel like one.

---

## Product experience

The [Saturn design canvas](https://claude.ai/artifact/2rBPXF4C8fJi8RvWDGB9BD) is the reference for how the app looks and behaves. It covers every screen: the chat with the Lead, Agents, Workflows, Changes, Source, Run detail, Agent session, Usage, Settings, the ⌘K palette, Welcome, project onboarding and the website. The v5 pages are the current design. When the app and the canvas disagree, the canvas wins or gets updated, never ignored.

The experience it sets out:

- **Native and calm.** A macOS app in dark or light, and one quiet place to run the crew instead of a wall of terminals.
- **Keyboard-first.** ⌘K reaches any run, agent, file or action; ⌘P opens any file; common actions have shortcuts.
- **Written for humans.** Plain-language summaries, plans and pins. Review shows what needs a person and says why.
- **Decisions come to you.** You talk only to the Lead. Questions, approvals and failures appear in the chat they belong to, the chat list shows which ones need you, and the Dock, the menu bar and notifications count them.
- **Cost always visible.** Spend shows in the sidebar, on every run and agent, and before a plan starts.
- **Guided start.** Onboarding scans the project, suggests workflows, skills, checks and limits, and gets to the first task in a few steps.

The evidence is consistent: speed is easy and stability is hard. Agents raise output, but unchecked they also raise PR size, review time, duplication, complexity and bugs. Saturn's job is to keep the speed and pay the stability bill up front. It does that with the harness around the model, not with the model.

---

## Target user

A solo developer who already ships real code with a coding agent and wants the results to be dependable, not just fast.

- **Works alone, on one machine,** across one or a few repos they know well.
- **Already uses agents daily,** and has seen them cut corners: skipping tests, editing them to go green, duplicating code, declaring "done" too early.
- **Is the only reviewer.** Their review time is the real bottleneck, not agent throughput.
- **Pays for their own usage** and watches spend closely.
- **Owns the outcome.** Nothing they can't explain should reach `main`.

What gets in their way today:

- The verification harness is ad hoc: some checks run, some don't, and nothing stops an agent from finishing while tests fail.
- Plans, conventions and lessons learned live in their head or in sprawling instruction files that agents half-ignore.
- Reviews arrive large and unfiltered, with no signal about where to look.
- They can't tell whether agents are actually making them better or just faster, because nothing measures it.

---

## Principles

1. **Rails before autonomy.** Correctness comes from what the agent must pass, not from what it is told. Nothing reaches the developer until its checks are green; retries are capped, and after that the work comes back to the human instead of looping. Autonomy grows only as far as the gates have earned.
2. **Enforce deterministically, and protect the checks.** If a rule matters, it lives in a hook, linter, test or check, and instruction files stay short. Tests are protected code: agents can't edit, disable or work around the checks that judge them, and test changes are reviewed on their own.
3. **Small, planned, isolated changes.** One reviewable unit per task, with acceptance criteria. A lightweight plan with scope, out-of-scope and a verification step for anything non-trivial, and none for a one-sentence diff. Every agent works in its own sandboxed worktree and branch.
4. **AI reviews, humans approve.** AI review is a high-precision commenter that points to what matters, never an approver or a rigid gate. A human who can explain the change approves it and owns it, with scrutiny tiered by risk. Review capacity, not agent count, sets the pace.
5. **Close the loop.** A mistake repeated twice becomes one rule, hook or check, encoded once and versioned in the repo.
6. **Measure outcomes, not output.** Track what predicts stability (PR size, review time, rework, duplication), not lines generated or how much code the AI wrote.

---

## Success criteria

Saturn succeeds when it makes agent work dependable, measured by outcomes rather than by the developer's sense of speed:

- **Nothing unverified reaches review.** Every change presented to the developer has passed its deterministic checks, and no change made them pass by editing or disabling them.
- **Small changes.** PR size stays small and steady as usage grows instead of creeping up.
- **Review stays fast.** Time to review and approve a change stays flat or falls, guided by precise AI comments and pins.
- **Low rework.** Revert and rework rates for agent changes are on par with the developer's own.
- **No quality drift.** Duplication, complexity and warnings in the codebase don't climb over time.
- **Fewer repeated mistakes.** Corrections the developer makes become rules or checks, and the same mistake stops recurring.
- **Predictable spend.** No run exceeds its budget, and the developer can say what each change cost.
- **Reliable runs.** No lost work across quits, crashes, sleep or rate limits; every run finishes, waits on the developer, or fails with a clear reason.
- **One place to work.** The developer goes from task to merged change without leaving Saturn for a terminal, browser or other tool, unless they choose to.
- **Visible numbers.** The developer can see these metrics in the app, not just trust that they're true.
