#!/usr/bin/env bash
# One-time setup for developing Pomodoro on a Mac. Safe to re-run.
set -euo pipefail

XCODE_VERSION="26.6"   # keep in sync with .github/workflows/ci.yml

step() { printf '\n==> %s\n' "$*"; }

[[ "$(uname)" == "Darwin" ]] || { echo "Run this on macOS."; exit 1; }

step "Xcode"
if ! xcodebuild -version >/dev/null 2>&1; then
  echo "Full Xcode is required (not just Command Line Tools). Install Xcode $XCODE_VERSION, then:"
  echo "  sudo xcode-select -s /Applications/Xcode.app && sudo xcodebuild -runFirstLaunch"
  exit 1
fi
installed="$(xcodebuild -version | awk 'NR==1{print $2}')"
echo "Xcode $installed (CI pins $XCODE_VERSION)"
if [[ "$installed" != "$XCODE_VERSION" ]]; then
  echo "warning: snapshot tests may render slightly differently than CI on another Xcode/macOS."
fi

step "Homebrew tools"
command -v brew >/dev/null || { echo "Install Homebrew first: https://brew.sh"; exit 1; }
for tool in xcodegen gh; do
  command -v "$tool" >/dev/null || brew install "$tool"
done

step "GitHub auth"
gh auth status >/dev/null 2>&1 || gh auth login

step "Generate Xcode project"
cd "$(dirname "$0")/.."
xcodegen generate

step "Resolve packages and run the fast checks"
scripts/check.sh

cat <<'EOF'

Done. Next:
  - open Pomodoro.xcodeproj         (or keep using scripts/check.sh from agents)
  - read HANDOFF.md                 (state of the project and how to continue)
EOF
