# Agent rules for this repo

Read `PLAN.md` first. It is the spec. `HANDOFF.md` has the current state and conventions.

## Environment facts
- Development happens on a **Mac** with Xcode 26.6 (the version CI pins). First time:
  `scripts/bootstrap-mac.sh`.
- **Build and test locally first.** `scripts/check.sh core` runs the Core tests in seconds;
  `scripts/check.sh` runs Core plus the app build and tests; `scripts/check.sh run`
  launches a Debug build so you can look at the real app.
- Open PRs as **drafts** (`gh pr create --draft`). CI skips drafts, so work-in-progress
  pushes cost nothing. When `scripts/check.sh` is green locally, run `gh pr ready <PR>`;
  CI then runs once as the merge gate (`build-test` is required on `main`).
- If CI fails, read it with `gh run view <run-id> --log-failed`, reproduce locally, fix,
  and push. Don't hand back a PR with red CI unless you've documented exactly why.
- **Snapshots:** CI renders are the source of truth for references in `Snapshots/`.
  A snapshot that differs only locally (other macOS/Xcode/display) isn't a failure;
  record new or changed references from the CI `snapshots` artifact (see README).
- Several agents may run at once on the same Mac. Use your own git worktree, and run one
  `xcodebuild` at a time when possible.

## Git / PR rules
- Never push to `main`. Work on `issue-<N>-<slug>`, open a PR whose body contains
  `Closes #<N>`, and keep each PR scoped to its issue.
- Don't commit generated `.xcodeproj` files, because the project comes from
  `project.yml` through XcodeGen.
- Commit messages are imperative and short.

## Code rules
- Swift 6 with strict concurrency, targeting macOS 14+. Put logic in `Packages/PomodoroCore`
  (no SwiftUI or AppKit imports there) and keep the app target thin.
- Timers are anchored to the wall clock (`Date`) through an injectable `Clock`
  protocol. Never count ticks.
- No new dependencies beyond the ones listed in PLAN.md without saying why in the PR.
- Every Core change ships with XCTest/Swift Testing tests. Every new UI view ships
  with a snapshot test, so CI uploads its PNG for visual QA.
- Match the existing style. Keep comments sparse and explain *why*, not *what*.
