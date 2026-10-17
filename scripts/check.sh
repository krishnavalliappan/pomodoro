#!/usr/bin/env bash
# Local feedback loop: same steps as CI, minus packaging. Run before pushing.
#   scripts/check.sh            core tests + app build/tests
#   scripts/check.sh core       PomodoroCore only (seconds)
#   scripts/check.sh app        app build/tests only
#   scripts/check.sh run        build Debug and launch the app
set -euo pipefail
cd "$(dirname "$0")/.."

mode="${1:-all}"
derived="build/DerivedData"
artifacts="$PWD/build/snapshot-failures"

# Regenerate when project.yml or the file list changed; cheap enough to always do.
xcodegen generate --quiet

core() { swift test --package-path Packages/PomodoroCore; }

app() {
  mkdir -p "$artifacts"
  set -o pipefail
  TEST_RUNNER_SNAPSHOT_ARTIFACTS="$artifacts" TEST_RUNNER_OS_ACTIVITY_MODE=disable \
  xcodebuild -project Pomodoro.xcodeproj -scheme Pomodoro -destination 'platform=macOS' \
    -derivedDataPath "$derived" -skipMacroValidation -skipPackagePluginValidation \
    build test 2>&1 | { command -v xcbeautify >/dev/null && xcbeautify || cat; } || {
      echo
      echo "Tests failed. Snapshot renders (if any) are in $artifacts"
      echo "CI renders are the source of truth for references; see HANDOFF.md > Snapshots."
      exit 1
    }
}

run() {
  pkill -x Pomodoro 2>/dev/null || true
  xcodebuild -project Pomodoro.xcodeproj -scheme Pomodoro -configuration Debug \
    -derivedDataPath "$derived" -skipMacroValidation -skipPackagePluginValidation build -quiet
  open "$derived/Build/Products/Debug/Pomodoro.app"
}

case "$mode" in
  core) core ;;
  app) app ;;
  run) run ;;
  all) core && app ;;
  *) echo "usage: scripts/check.sh [all|core|app|run]"; exit 2 ;;
esac
