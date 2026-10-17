<img src="assets/icon.svg" width="64" height="64" alt="">

# pomodoro

A native macOS menu-bar Pomodoro app with tasks and time-blocking. See [`PLAN.md`](PLAN.md)
for the spec and [`AGENTS.md`](AGENTS.md) for contributor and agent rules.

Created in [T3 Code](https://t3.codes).

## Layout

```
App/                      SwiftUI app target (thin, menu-bar only, LSUIElement)
Packages/PomodoroCore/    pure-Swift logic package (no SwiftUI/AppKit) + its tests
Tests/PomodoroTests/      app test target (snapshot tests)
Snapshots/                snapshot reference PNGs
scripts/gen_sounds.py     regenerates App/Resources/Sounds/*.wav (stdlib Python, deterministic)
project.yml               XcodeGen spec — the .xcodeproj is generated, never committed
```

## Build locally (macOS 14+, Xcode 26)

```sh
brew install xcodegen && xcodegen && open Pomodoro.xcodeproj
```

Or from the command line:

```sh
xcodegen generate
swift test --package-path Packages/PomodoroCore
xcodebuild -project Pomodoro.xcodeproj -scheme Pomodoro -destination 'platform=macOS' build test
```

Re-run `xcodegen` whenever you add or remove files or change `project.yml`.

## CI

`.github/workflows/ci.yml` runs on `macos-latest` with Xcode pinned to 26.6 for every PR and
every push to `main`: XcodeGen → `swift test` for `PomodoroCore` → `xcodebuild build test` →
a check that `LSUIElement` is set in the built `Info.plist`. Artifacts:

- `snapshots`: `reference/` holds the reference PNGs (plus any recorded on this run), and
  `failures/` holds failed renders. On a mismatch, `failures/<TestClass>/<test>/` also holds
  `reference.png`, `failure.png` (actual), and `difference.png`, exported from the xcresult.
- `xcresult`: the full test result bundle.
- `Pomodoro.app`: zipped Release build (pushes to `main` only; PRs build Release but don't upload).

## Snapshot tests

Snapshot tests use [swift-snapshot-testing](https://github.com/pointfreeco/swift-snapshot-testing)
and store references in `Snapshots/` as `<View>.<variant>.png` (for example `PopoverView.dark.png`).

**Strategy: commit references and record when one is missing.** If a reference doesn't exist,
the test writes it and then **fails** on purpose, so a PR can't go green without a committed
reference. To add a snapshot for a new view:

1. Push the test. CI fails with "No reference was found on disk" and uploads the newly
   recorded PNG in the `snapshots` artifact under `reference/`.
2. Download it and look at it: `gh run download <run-id> -n snapshots -D /tmp/snapshots`.
3. Copy the new PNGs into `Snapshots/`, commit, and push. CI goes green.

To re-record an intentional UI change, delete the old PNG and follow the same steps, or run the
tests locally on a Mac and commit the result. References are rendered by the CI runner (macOS 26,
Xcode 26.6). A local Mac with a different OS version may render slightly differently, so treat
CI-rendered PNGs as the source of truth.

When `macos-latest` moves to a new macOS image, or `XCODE_VERSION` changes, update both in one
PR and re-record every reference in that same PR. AppKit rendering follows the OS, so references
are only valid for the runner image and Xcode that rendered them.
