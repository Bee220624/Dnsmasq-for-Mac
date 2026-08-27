#!/bin/bash
# Regenerate DnsmasqForMac.xcodeproj from project.yml.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

if ! command -v xcodegen >/dev/null 2>&1; then
    cat >&2 <<'EOF'
error: xcodegen not found.

Dnsmasq for Mac keeps project.yml as the source of truth and never commits project.pbxproj,
so XcodeGen is required to build. Install it with either:

    brew bundle --file=Brewfile
    brew install xcodegen

then re-run `make generate`.
EOF
    exit 1
fi

cd "${REPO_ROOT}"
echo "==> xcodegen $(xcodegen --version)"
xcodegen generate --spec project.yml --project .
echo "==> generated ${REPO_ROOT}/DnsmasqForMac.xcodeproj"
