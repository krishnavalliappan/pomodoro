# Agent rules for this repo

Read `PLAN.md` first. It is the spec.

## Environment facts
- The dev sandbox is **Linux**. There's no Xcode, no Swift toolchain, and no macOS,
  so you **cannot build or run the app locally**. Every build and test runs in
  GitHub Actions (`.github/workflows/ci.yml`, macOS runner).
- Your feedback loop: push the branch, then `gh pr checks <PR> --watch`. On failure,
  run `gh run view <run-id> --log-failed` to read compiler and test errors, then fix
  and push again. Repeat until green. Don't hand back a PR with red CI unless you
  have documented exactly why.
- The sandbox has 5 GB RAM shared with other agents. Don't run heavy local jobs.

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
