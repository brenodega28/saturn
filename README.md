<p align="center"><img src="Saturn/Resources/Assets.xcassets/AppIcon.appiconset/icon_256x256.png" alt="Saturn app icon" width="128"></p>

<h1 align="center">Saturn</h1>

<p align="center">An agentic development environment that puts modern agentic development norms to work, so more of what you build succeeds.</p>

Saturn is a native macOS ADE (agentic development environment) for solo developers. You chat with one Lead. It plans the work and spins up as many builder and checker agents as the task needs, each coding agent in its own git worktree. Saturn runs your checks, reviewers point you to what matters, and nothing reaches `main` without your approval. Projects can live on this Mac or on a remote host over SSH.

## What you get

- **One chat with the Lead.** You talk only to the Lead. It sizes the crew to the task, from one builder for a small fix to several in parallel. Questions, approvals and failures come to you in the chat they belong to.
- **Agents with different jobs.** Builders write the code; checkers review it and test it end to end. Agent profiles and skills in `.saturn/` tailor them to your project, for example a checker focused on performance.
- **Specs before runs.** For anything non-trivial the Lead drafts a short spec with scope and acceptance criteria. It opens in [Lavish](https://github.com/kunchenguid/lavish-axi), where you annotate it, discuss it with the Lead and approve it before any work starts.
- **Every agent isolated.** Each coding agent works in its own git worktree and branch under `.crew/`, out of your own `git status`.
- **Checks before review.** Saturn runs your project's format, lint, typecheck and test commands itself, outside the agent's session. Work reaches you only once they pass, and retries are capped.
- **Protected tests.** Agents can't edit or disable the checks that judge them. Any change to a protected file is pinned for you to review.
- **AI review that points, not blocks.** Reviewer agents leave pins on the lines you should read. Only you approve.
- **SSH and many machines.** Open a repository on a remote host over SSH. Each machine runs a Saturn daemon (`saturnd`), so runs keep going when your Mac sleeps, and one app shows chats from every machine side by side.
- **Guided onboarding.** The Lead reads a new project, writes its mission and vision, and proposes agent profiles and a workflow you apply with one click.
- **Config in your repo.** Agent profiles, workflows and checks live in `.saturn/`, versioned with your code.
- **Your own Claude account.** Saturn drives the `claude` CLI with your Claude sign-in or your own API key. No reselling.
- **Local-first.** No GitHub integration: a finished run merges into your base branch on the machine that holds the project. You push from the chat when you choose.
- **Native macOS.** Dark and light, with keyboard shortcuts and a ⌘K palette.

## Getting started

### Requirements

- macOS 26 or later
- `git`
- The [Claude Code](https://docs.anthropic.com/en/docs/claude-code) `claude` CLI, signed in
- Node, for live spec review in Lavish (optional; without it specs open read-only)
- For remote projects: an Apple silicon Mac reachable over SSH, kept logged in, with `git` and `claude` installed. Saturn installs its daemon there for you

### Install

Downloads are coming. There are no releases yet, so build from source for now:

```sh
brew install xcodegen
git clone https://github.com/brenodega28/saturn.git
cd saturn
xcodegen generate
open Saturn.xcodeproj
```

Then build and run the **Saturn** scheme in Xcode 26 or later.

### How it works

1. **Open a project.** Pick a folder, clone a repository, or open a folder on a remote host over SSH from the Welcome screen.
2. **Onboard it.** The Lead reads the project and proposes its mission, agent profiles and a workflow. Apply them or ask for changes.
3. **Start a chat.** Tell the Lead what you want done.
4. **Review the spec.** The Lead drafts a spec naming the work and the workers, and it opens in Lavish. Annotate it, ask for changes, or approve and start.
5. **Watch the run.** Builders work in their own worktrees. Saturn runs the checks, and checkers pin what needs your eyes.
6. **Approve.** Review the changes, approve, and the run merges locally. Push to origin from the chat.

## Acknowledgements

Much of Saturn's approach is inspired by the teachings of [Kun Chen](https://github.com/kunchenguid). Saturn integrates his [Lavish](https://github.com/kunchenguid/lavish-axi) editor for spec review.

## Development

Requirements: macOS 26, Xcode 26 or later, [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`), and `git` and the `claude` CLI on every machine that runs a Saturn daemon.

```sh
xcodegen generate
open Saturn.xcodeproj
```

`project.yml` is the source of truth; `Saturn.xcodeproj` is generated and git-ignored. Re-run `xcodegen generate` after adding or removing files.

Engine tests run without Xcode:

```sh
swift test --package-path Packages/SaturnCore
```

The plan and design live in [spec/mission.md](spec/mission.md) and [spec/roadmap.md](spec/roadmap.md).

### Layout

```
Saturn/              macOS app target (SwiftUI)
Packages/SaturnCore  UI-free engine: daemon and protocol, SSH, git, worktrees, workflows, checks, Lavish, storage
                     (also builds saturnd, the headless daemon the app talks to)
Packages/SaturnUI    shared SwiftUI components and theme
Configs/             build settings (copy Local.xcconfig.example to Local.xcconfig for Sparkle keys)
scripts/release.sh   Developer ID archive, notarization, DMG and Sparkle appcast
```

The **Debug** menu has a Worktrees window for creating and removing worktrees under `.crew/`.

### Releases

`scripts/release.sh` needs a Developer ID Application certificate and reads these environment variables:

| Variable | Sensitive | Purpose |
| --- | --- | --- |
| `NOTARY_APPLE_ID`, `NOTARY_TEAM_ID`, `NOTARY_PASSWORD` | yes | `notarytool` credentials (app-specific password) |
| `SPARKLE_PRIVATE_KEY` | yes | EdDSA private key from Sparkle's `generate_keys` |
| `SPARKLE_PUBLIC_ED_KEY`, `SPARKLE_FEED_URL`, `SPARKLE_DOWNLOAD_URL_PREFIX` | no | Public key, appcast URL, and where DMGs are hosted |

The in-app updater stays off until a build has an `https` feed URL and a public key.
