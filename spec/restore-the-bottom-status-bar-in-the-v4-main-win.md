---
title: Restore the bottom status bar in the v4 main window
status: done
owner: ""
linked_runs: [68]
created: 2026-11-03
---

## Summary

The v4 chat-and-log rebuild (merge 0e14688) removed the Workbench StatusBar. This brings it back as a full-width bar along the bottom of MainWindowView, under the sidebar, middle and log columns, with all six original items, restyled with V4Style tokens. Click targets that pointed at removed Workbench panels now go to v4 screens.

## Interfaces

- New view `MainStatusBar` (Ensemble/Views/V4/MainStatusBar.swift), placed in `MainWindowView` below the three-column HStack, full width
- Items, left: Agents ("N agents working · M need you"), Checks ("Checks · round N · state"), Problems ("✕ errors ! warnings"); right: Claude CLI health, plan usage %, offline / rate-limited
- Restored helpers that were deleted with the Workbench: `AppModel.problems(...)` (from Ensemble/Workbench/Navigators/RunNavigators.swift at 47ffa4c), `AppModel.steps(of:)` (NavigatorParts.swift at 47ffa4c), `activeRunsInScope`, `CheckBoardEntry.State.statusWord`, `PlanUsageSeverity.color`, and a status button component — adapted to v4 (no WorkbenchState / NavigatorScope dependency)
- Click targets: Agents → MainScreen.tool(.agents); Checks → MainScreen.run(id) of the run the entry belongs to; Problems → the run the first problem came from; Claude → Settings; Plan usage → MainScreen.tool(.usage); Offline / rate limit → not clickable (help text only)

## Out of scope

- Bringing back the old toolbar (project switcher, scheme selector, start/stop, activity viewer)
- Bringing back the bottom panel, navigator or inspector
- A new Problems view
- Changes to PlanUsage / ProjectSignals logic in EnsembleCore

## Acceptance criteria

- [x] A status bar spans the full window width at the bottom of the main window, below all three columns, and does not overlap or clip them
- [x] Each item appears under the same conditions as before (e.g. Agents only when an agent is working or needs you; Checks only when a check board entry exists; Problems only when there are problems; plan usage per PlanUsageDisplay.isVisible; offline only when isOffline; rate limit only when a session hit a 429)
- [x] Item text matches the old wording
- [x] Clicking each item goes to the target listed in Interfaces
- [x] Colors, fonts, background and hairline come from V4Style tokens, no hard-coded Theme/hex colors from the old bar
- [x] Accessibility labels from the old items are kept (e.g. "N errors, M warnings", plan usage label)
- [x] No code comments added
- [x] The app builds and existing tests pass

## Verification

Build the app with xcodebuild and run the EnsembleCore tests. Launch the app, open a project with a running run: confirm the bar sits full width at the bottom, items show and hide per their conditions, and each click lands on the right screen. Toggle network off to see Offline. Screenshot light/dark if V4 supports both.
