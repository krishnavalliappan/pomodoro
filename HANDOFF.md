# Handoff: continuing development on a Mac

This project was built by agents in a Linux sandbox, where nothing could be compiled
locally and GitHub Actions' macOS runner acted as the compiler. From here on, development
moves to a Mac running T3 Code, so builds, tests and the real app run locally.

`PLAN.md` is the product spec, `AGENTS.md` holds the rules every agent follows, and the
README covers build and release. This file covers state, decisions and workflow.

## 1. Set up the Mac (once, about 15 minutes)

1. Install **Xcode 26.6** (the version CI pins) and open it once.
   `sudo xcode-select -s /Applications/Xcode.app && sudo xcodebuild -runFirstLaunch`
2. Clone and bootstrap:
   ```sh
   git clone https://github.com/krishnavalliappan/pomodoro.git ~/Developer/pomodoro
   cd ~/Developer/pomodoro
   scripts/bootstrap-mac.sh
   ```
   This installs `xcodegen` and `gh`, logs in to GitHub if needed, generates the project
   and runs `scripts/check.sh`.
3. In **T3 Code**, add `~/Developer/pomodoro` as a project. Agents pick up `AGENTS.md`
   (symlinked as `CLAUDE.md`) automatically.
4. Optional but recommended: give the Debug build its own bundle id (see §6) so dev runs
   don't touch the data of the copy installed in `/Applications`.

## 2. The local loop

| Command | What it does | Time |
|---|---|---|
| `scripts/check.sh core` | `PomodoroCore` tests: timer engine, store, parser, stats | seconds |
| `scripts/check.sh` | Core + app build + all app tests, including snapshots (what CI runs) | about 1–2 min warm |
| `scripts/check.sh run` | Build Debug and launch the real menu-bar app | about 30 s warm |
| `open Pomodoro.xcodeproj` | Work in Xcode (⌘U tests, ⌘R run) | n/a |

PR flow:
1. Branch `issue-<N>-<slug>`, then `gh pr create --draft` early. CI skips drafts.
2. Iterate locally until `scripts/check.sh` is green, and look at the real app (`check.sh run`).
3. `gh pr ready <PR>`, and CI runs once as the merge gate.
4. Review, then `gh pr merge <PR> --squash --delete-branch`. `main` requires `build-test`.

GitHub Actions macOS minutes are free on this public repo; draft-skipping just saves
wall-clock time and failure emails.

## 3. Agent pipeline (how this was run, and how to keep running it in T3)

Each issue went through this pipeline:

1. **Implementer:** a Claude agent in its **own git worktree**, via `delegate_task` with
   `isolation: "worktree"`. It reads the issue, implements it with tests, iterates locally
   with `scripts/check.sh`, opens a draft PR with `Closes #N`, and marks it ready when green.
2. **Code review:** **Codex `gpt-6.1-sol`, reasoningEffort `high`**. It only reads the PR,
   then posts one review comment with `## Blocking` and `## Non-blocking` sections, each item
   with `file:line` and a concrete fix. Its verdict is APPROVE or CHANGES_REQUESTED.
3. **Visual QA:** a cheaper model (**Claude Haiku**) opens every changed snapshot PNG and
   checks it against the issue's acceptance criteria. On the Mac it can also look at the
   real app.
4. **Fix rounds:** a new implementer task gets the review findings. Codex re-reviews with the
   full history in the prompt. **At most 3 fix rounds, then ask the user.**
5. **Merge:** squash-merge when CI is green, Codex approves and visual QA passes. Then watch
   CI on `main`.

Lessons learned:
- **Haiku produces false positives.** Before acting on a "BLOCKING" visual finding, open
  the PNG yourself. Twice it reported missing text that was actually there.
- **Ask Codex to judge design decisions explicitly** and to say which PR should change when
  two parallel PRs disagree on names.
- **Parallel PRs touching the same files** (`PomodoroApp.swift`, `WindowRouter`,
  `MenuBarController`, `AppModel`, `PopoverView`) conflict. Decide merge order up front, and
  have the second PR rebase with a "list every conflict and how you resolved it" comment.
- **Max about 3 implementers at once** on a laptop. Each runs `xcodebuild`, so serialize the
  heavy steps where you can.

## 4. Snapshots (important)

- References live in `Snapshots/` and were **rendered on the CI runner** (macOS 26 and
  Xcode 26.6 at 1×). Tolerance is strict: `precision 1.0, perceptualPrecision 0.995`.
- On your Mac, snapshots may differ slightly if your macOS, Xcode, fonts or display differ.
  That's not a product bug. **CI stays the source of truth:** to add or change a reference,
  push, let CI record it, download it with `gh run download <id> -n snapshots`, check it,
  and commit.
- If local snapshot diffs get noisy, the clean fix is to record locally only when your
  Mac matches the CI image. Don't loosen the tolerance, because a looser one already let a
  real UI change through once (see PR #40).
- Popover sizing must stay deterministic. AppKit-backed controls inside it, such as text
  fields, get pinned heights (PR #39). `PopoverSizeStabilityTests` guards this.

## 5. Current state (2026-10-17)

**v1 is complete and merged** (milestones M0, M1 and M2 are closed): the timer engine with
flow-mode overtime, presets and one-off durations, the GRDB store, sounds, quick-add,
menu bar and popover, actionable notifications, tasks, settings and hotkeys, the planner
timeline, stats, app icon and the release workflow. `main` CI is green.

**No release has been tagged.** To publish one, push tag `v0.1.0`. `release.yml` builds,
ad-hoc signs and publishes it. `MARKETING_VERSION` and `Version.current` are already 0.1.0.

### In flight: milestone "v1.1 Sounds & polish"

| Issue | PR | State |
|---|---|---|
| #43 Popover redesign (Session-style tab bar) | #46 | ✅ **merged**. Codex approved in round 2 and Haiku visual QA passed |
| #42 Ambient sounds engine + bundled library | #47 (draft) | 🟡 **about 90% done, finish locally**. See below |
| #44 Sounds tab UI | — | unblocked once #47 merges. Fills the Sounds tab placeholder from #46 |
| #45 Subtle animations | — | unblocked (#46 merged) |

**PR #47: what's done and what's left**

Done (branch `issue-42-ambient`):
- 15 loops in `App/Resources/Ambient/` (about 9.2 MB): 12 from Blanket plus white, pink and
  brown noise generated by `scripts/import_ambient.py`.
- Credits in `ambient-credits.json`, mirrored in `SOUNDS_LICENSING.md`.
- Core `AmbientLibrary`, `AmbientMix` and `AmbientPolicy`, with a settings migration and tests.
- The `AVAudioEngine`-based `AmbientEngine` and `AmbientPlayer`, with player tests and a fake engine.
- `AppModel+Ambient` (the API #44 binds to) and `SoundCreditsView` in Settings → General.

Left to do:
1. **Rebase onto main.** #46 changed `AppModel.swift` and `README.md`. Resolve those, then
   run `scripts/check.sh`.
2. **Gapless loops (a real bug, not a test quirk).**
   `AmbientBundleTests.testEverySoundLoadsAndLoopsAtItsManifestLength` fails because each
   AAC `.m4a` decodes about 20–30 frames short. For example, rain decodes to 5,290,985
   frames against an expected 5,291,008. That's AAC encoder priming and remainder padding,
   and it would cause an audible click at every loop seam. Two possible fixes:
   - **(a)** re-encode as **ALAC** (lossless, exact length; check the ≤ 12 MB budget,
     since mono and a lower sample rate help); or
   - **(b)** keep AAC, but write correct `iTunSMPB` gapless metadata and have the player
     trim to the manifest length.

   Either way, **listen on your Mac**: `scripts/check.sh run`, then play rain or white
   noise for a few loops.
3. **Record 3 snapshot references** (`SettingsView.general`, `general-approval` and
   `SoundCredits`, light and dark) from CI's `snapshots` artifact once the PR is ready.
4. Mark it ready, get Codex review and Haiku QA, then merge. Then start #44.

**Minor items from #46 reviews, not done (decide or fold into #44 and #45):**
- **Accent colour:** it's a saturated crimson, where the reference Session sounds grid uses a
  softer rose. That's your call.
- **Tab labels:** the tab bar is icon-only, like Session. Confirm you're happy with that.
- **⚙ menu:** it pops up from an NSPopover and can't be snapshot-tested; there's a manual QA
  step on #29.

### Other open issues

- **#29 Real-Mac QA checklist.** Now doable locally: notifications and actions, sounds,
  AirPods switching, popover dismissal, quick-add hotkey focus, ⌘, routing, menu bar glyph
  tint, idle CPU and Energy Impact.
- **#30, #36, #41** are polish and test-gap follow-ups from reviews. None is user-facing
  breakage. #41 includes checking whether the **menu bar glyph renders grey**, which is
  easy to confirm on a real menu bar.
- **#15–#18, #20** form the backlog: EventKit overlay, Shortcuts/App Intents, Focus filter,
  idle detection, iCloud sync.

## 6. Decisions already made (don't relitigate without the user)

- **Stack:** native Swift 6 / SwiftUI with AppKit where needed, macOS 14+, `LSUIElement`
  (no Dock icon), XcodeGen, GRDB, KeyboardShortcuts. All logic lives in `PomodoroCore`.
- **Flow mode:** focus never auto-stops. It counts overtime and prompts *Start break /
  +5 min / Keep going*, with nudges every N minutes.
- **Preset chips are one-off** (one focus plus its break). "Make default" is in Settings.
- **Quick-add:** marked tokens (`~N`, `@time`, `#tag`) are recognised anywhere. Bare days
  and durations only count in the trailing group, and a duration needs `@time`. `#42`
  (digits only) stays in the title.
- **Notifications are silent.** The chime plays in-app, which respects the user's sound
  choice. A single prompt identifier with a confirmed handoff guarantees one banner, never
  zero (PR #27).
- **Ambient sounds (v1.1):** bundled, freely licensed only: Blanket's CC0, public domain
  and CC-BY files with credits, plus noise generated in-app. Moodist was rejected because
  its Pixabay licensing has no per-file records.
- **Popover redesign (v1.1):** a Session-style bottom tab bar (Timer · Tasks · Sounds ·
  Stats · ⚙), the round shown as 4 dots, one primary action. Reference app: **Session**
  (stayinsession.com).
- **Animations:** subtle and native. Honour Reduce Motion, and do zero animation work
  while the popover is closed.

Suggested next small change: in `project.yml`, set a Debug-only
`PRODUCT_BUNDLE_IDENTIFIER: dev.krishna.pomodoro.debug` (and maybe a "Pomodoro Dev" name)
so `scripts/check.sh run` doesn't share settings, database or notifications with the
installed app.

## 7. Prompt templates for T3

**Implementer** (`delegate_task`, worktree isolation, Claude):
> You are the implementer for GitHub issue #N in krishnavalliappan/pomodoro. Read PLAN.md,
> AGENTS.md, HANDOFF.md and `gh issue view N`. Branch `issue-N-slug` from origin/main.
> Implement it with tests. Iterate with `scripts/check.sh` until green and look at the app with
> `scripts/check.sh run`. Open a draft PR (`Closes #N`) and mark it ready when green. Wait for CI
> and, if main moved, rebase. Never push to main or merge. Reply with the PR URL, CI status,
> a summary and any deviations.

**Reviewer** (`delegate_task`, Codex `gpt-6.1-sol`, `reasoningEffort: high`):
> Review only, do not modify files. Read `gh pr view/diff <PR>`, the issue, PLAN.md and AGENTS.md.
> Review correctness, Swift 6 isolation, performance and energy (menu bar app), and test quality.
> [Round K: list the previous blockers and the implementer's response.] Post ONE review with
> `## Blocking` / `## Non-blocking`, each item with file:line and a fix. Mark something blocking
> only for a real bug, perf issue or data loss. Reply APPROVE or CHANGES_REQUESTED plus the list.

**Visual QA** (`delegate_task`, Claude Haiku):
> Open every changed PNG in `Snapshots/` (or the CI `snapshots` artifact) with Read. Check them
> against the issue's acceptance criteria: legibility, clipping, overlap, light/dark parity.
> Reply PASS or FAIL with problems marked BLOCKING or MINOR. Re-check before calling anything
> BLOCKING.
