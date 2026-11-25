---
title: Lead-led project onboarding
status: in-progress
version: 1
workers:
  - {role: builder, name: Onboarding Builder, reason: "Builds everything in one task: the onboarding definition and versioning, agent profiles, the propose_setup tool, the card, and the chat trigger. The tool, the card and the trigger depend on each other, so they can't be tested apart."}
  - {role: checker, name: QA, reason: "Runs the engine tests and walks through the code-repo, empty-repo and version-bump flows end to end with fresh eyes."}
owner: ""
linked_runs: [26]
created: 2026-11-25
---

## Summary

When a project is onboarded to Saturn, Saturn opens an onboarding chat with the Lead instead of only running the silent setup. If the repo has code, the Lead reads it and writes up the app's mission and vision. If the repo is empty, the Lead asks the user what the app is. The Lead then asks whether Saturn's .md files (the mission, then every spec) should go in a spec/ folder in the repo or stay in .saturn/specs/ for Saturn only. After that it proposes named agent profiles and a custom workflow through a new propose_setup tool. The chat shows the proposal as a card listing every file, and Saturn writes the files under .saturn/ and the chosen spec folder when the user clicks Apply. Onboarding is versioned. The app bundles an onboarding definition with a version number and a force_onboarding flag, and each project records the version it last completed in .saturn/onboarding.yaml. When a newer bundled version has force_onboarding: true, Saturn reopens the onboarding chat for any project whose recorded version is older. The deterministic part of today's setup still runs first: checks, permissions, .gitignore and the default workflows. The chat adds the parts that need judgment.

## Interfaces

- Bundled resource SaturnCore/Resources/Onboarding/onboarding.yaml: { version: Int, force_onboarding: Bool, instructions: String }. instructions is the Lead's onboarding brief: analyse the repo or ask about the app, write the mission and vision, ask where specs live, propose agents and a workflow. It ships as version: 1 with force_onboarding: false.
- Project file .saturn/onboarding.yaml: { version: Int, completed_at: ISO-8601 date }. It is written on Apply. A missing file means version 0.
- OnboardingDefinition (SaturnCore): load() reads the bundled definition. needsOnboarding(repository:) -> Bool is true when the project has no .saturn/ config, or when the bundled force_onboarding is true and the bundled version is greater than the recorded version.
- Agent profile file .saturn/agents/<id>.yaml: { name, kind: builder|checker, model?, description, instructions, skills?: [String] }. skills is accepted and passed through but nothing populates it yet. It is loaded by ProjectConfigLoader into ProjectConfig.agents: [AgentProfile] and checked for validity like workflows, with ConfigIssue on bad files.
- spawn_agent gains an optional `profile: String` (an agent profile id). The profile fills in kind, model, skills and prepends its instructions to the task. Explicit arguments override the profile.
- Workflow step `agent:` accepts an agent profile id as well as lead/builder/checker, and resolves to that profile's kind, model and instructions. An unknown id is a ConfigIssue.
- Lead system prompt: lists the project's agent profiles (id, kind, one-line description) beside the installed skills.
- New Lead tool propose_setup { mission: String (markdown), spec_folder: "spec" | ".saturn/specs", agents: [{ id, name, kind, model?, description, instructions }], workflow: WorkflowDefinition (JSON, same shape as the YAML), make_default: Bool }. Saturn validates the proposal and returns any errors to the Lead as the tool result, without posting a card. A valid proposal posts a LeadMessage of kind .setupProposal.
- Chat card SetupProposalCard (SwiftUI): lists each file Saturn will write, marking it new or overwrite, with an expandable preview, plus Apply and Dismiss buttons. Apply writes .saturn/specs.yaml (folder), <spec_folder>/mission.md, .saturn/agents/<id>.yaml, .saturn/workflows/<workflow id>.yaml, the default workflow in preferences when make_default is true, and .saturn/onboarding.yaml. It then reloads the config and tells the Lead the setup was applied.
- Onboarding chat: Chat gains an `isOnboarding` flag (DB migration). Saturn creates the chat itself, with an opening message from Saturn rather than the user. The message carries the ProjectScan summary (technologies, docs found, whether the repo is effectively empty). For this chat, the Lead's prompt gets the bundled onboarding instructions. Saturn reuses an existing open onboarding chat instead of starting a second one.
- DaemonWorkspace+Setup: after applyRecommendedSetup, or for an already-configured project where needsOnboarding is true, Saturn starts or selects the onboarding chat when the project is opened.

## Out of scope

- Generating or proposing skills. The agent profile's skills field is reserved for later.
- A manual 'Set up with Lead' command. Reopening happens only through the force_onboarding version bump.
- Committing the written files. They land uncommitted in the project's working tree, as today's setup does.
- Onboarding remote (SSH) projects, which are already skipped by needsSetup.
- Reintroducing the legacy roles system or migrating .saturn/legacy-roles into agent profiles.
- Changing the deterministic checks, permissions or AGENTS.md detection.

## Acceptance criteria

- [ ] Opening a new local project that has no .saturn/ runs the deterministic setup, then opens an onboarding chat with the Lead without the user typing anything.
- [ ] In a repo with source code, the Lead's first reply summarises the app's mission and vision from the code and docs, then asks where specs should be stored (spec/ or .saturn/specs/).
- [ ] In an empty repo (no source files apart from .saturn, .gitignore, LICENSE or a near-empty README), the Lead asks the user what the app is before proposing anything.
- [ ] propose_setup with an invalid workflow, a duplicate or invalid agent id, or a spec_folder other than the two allowed values returns the errors to the Lead and posts no card.
- [ ] A valid propose_setup shows a card listing every file to be written, each marked new or overwrite. Nothing is written until the user clicks Apply.
- [ ] After Apply, <spec_folder>/mission.md, .saturn/specs.yaml, .saturn/agents/*.yaml, .saturn/workflows/<id>.yaml and .saturn/onboarding.yaml (with the bundled version) exist. When make_default is true the default workflow is the proposed one, and the Workflows page shows the new workflow.
- [ ] After Apply, new spec drafts are committed into the chosen spec folder, because SpecStore follows specs.yaml.
- [ ] Agent profiles load into ProjectConfig. A malformed profile shows a ConfigIssue and doesn't crash the app.
- [ ] spawn_agent with profile: <id> starts an agent with the profile's kind, model and instructions. A workflow step whose agent: names a profile runs with that profile.
- [ ] Reopening a project whose onboarding.yaml version equals the bundled version doesn't start an onboarding chat.
- [ ] With a bundled definition at version 2 and force_onboarding: true, opening a project recorded at version 1 reopens the onboarding chat, or reuses an open one. With force_onboarding: false, it doesn't.
- [ ] Opening a project twice while its onboarding chat is still open never creates a second onboarding chat.
- [ ] Engine tests cover OnboardingDefinition.needsOnboarding, agent profile loading and validation, propose_setup validation, and the files Apply writes. `swift test --package-path Packages/SaturnCore` passes.

## Verification

Run `swift test --package-path Packages/SaturnCore`. Build the Saturn scheme. In the app: (1) open a fresh folder containing a small sample app with no .saturn/, and check that the onboarding chat opens, the Lead summarises the mission, asks about the spec folder, then proposes agents and a workflow. Click Apply and check the files on disk and on the Workflows page. (2) Repeat with an empty git repo and check that the Lead asks what the app is. (3) Reopen the project and check that no new onboarding chat starts. (4) Temporarily bump the bundled onboarding version to 2 with force_onboarding: true, reopen the project and check that the onboarding chat comes back. (5) In a regular chat, have the Lead spawn_agent with one of the new profiles and confirm it starts with that profile's kind, model and instructions.
