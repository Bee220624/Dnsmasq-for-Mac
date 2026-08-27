#!/bin/bash
# Stage a development build of Dnsmasq for Mac into /Applications.
#
# SMAppService resolves the daemon's BundleProgram relative to the app bundle and remembers
# the registering bundle's location. A build run straight out of DerivedData therefore breaks
# as soon as that path changes, so development installs go to a stable location like any real
# install would.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-identifiers.sh
source "${SCRIPT_DIR}/lib-identifiers.sh"

CONFIGURATION="${1:-Debug}"
DERIVED_DATA="${REPO_ROOT}/build/DerivedData"
BUILT_APP="${DERIVED_DATA}/Build/Products/${CONFIGURATION}/${PRODUCT_NAME_BASE}.app"
INSTALLED_APP="/Applications/${PRODUCT_NAME_BASE}.app"

if [[ ! -d "${BUILT_APP}" ]]; then
    echo "error: no ${CONFIGURATION} build found at ${BUILT_APP}" >&2
    echo "       run: make build" >&2
    exit 1
fi

echo "==> verifying the build before installing it"
"${SCRIPT_DIR}/verify-bundle.sh" "${BUILT_APP}"

# A previously registered daemon keeps pointing at the old copy, so it is removed first.
if launchctl print "system/${HELPER_LABEL}" >/dev/null 2>&1; then
    echo "==> a previous helper is registered; removing it first"
    "${SCRIPT_DIR}/uninstall-dev-helper.sh" || true
fi

if [[ -d "${INSTALLED_APP}" ]]; then
    echo "==> removing previous ${INSTALLED_APP}"
    rm -rf "${INSTALLED_APP}"
fi

echo "==> copying to ${INSTALLED_APP}"
# -c preserves the signature; a plain recursive copy can invalidate nested code signatures.
ditto "${BUILT_APP}" "${INSTALLED_APP}"

echo "==> verifying the installed copy"
codesign --verify --deep --strict --verbose=1 "${INSTALLED_APP}"

cat <<EOF

Installed ${INSTALLED_APP}

Next steps — the privileged helper needs a one-time approval:

  1. Open ${PRODUCT_NAME_BASE} from /Applications.
  2. Go to Settings and choose Install Helper.
  3. macOS will report that approval is required. Click Open Login Items Settings.
  4. In System Settings > General > Login Items & Extensions, enable ${PRODUCT_NAME_BASE}.
  5. Return to the app; it re-checks automatically and connects.

To watch what the helper does:

  log stream --predicate 'subsystem == "${HELPER_LABEL}"' --level debug

To undo all of this:

  Scripts/uninstall-dev-helper.sh
EOF
