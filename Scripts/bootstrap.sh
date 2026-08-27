#!/bin/bash
# One-time developer machine setup. Development tooling only; nothing installed here is a
# runtime dependency of the shipped app.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${REPO_ROOT}"

echo "==> checking Xcode"
if ! xcodebuild -version >/dev/null 2>&1; then
    echo "error: full Xcode is required (Command Line Tools alone are not enough)." >&2
    echo "       Install Xcode, then: sudo xcode-select -s /Applications/Xcode.app" >&2
    exit 1
fi
xcodebuild -version | head -2

echo "==> checking Homebrew"
if ! command -v brew >/dev/null 2>&1; then
    echo "error: Homebrew not found. See https://brew.sh" >&2
    exit 1
fi

echo "==> installing development tools from Brewfile"
brew bundle --file=Brewfile

echo "==> generating Xcode project"
"${SCRIPT_DIR}/generate-project.sh"

cat <<'EOF'

Bootstrap complete.

  make build          build the app and helper
  make test           run unit, integration, and UI tests
  make vendor-dnsmasq fetch, build, and verify the bundled dnsmasq
  make install-dev    stage a development build into /Applications

The privileged helper needs a one-time approval in
System Settings > General > Login Items & Extensions. See Docs/PRIVILEGED_HELPER.md.
EOF
