#!/bin/bash
# Unregister the development helper and remove the staged app.
#
# Useful when iterating: a registered daemon holds a reference to a specific app bundle, so a
# stale registration produces confusing failures after the bundle is rebuilt or moved.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-identifiers.sh
source "${SCRIPT_DIR}/lib-identifiers.sh"

INSTALLED_APP="/Applications/${PRODUCT_NAME_BASE}.app"
REMOVE_APP="${1:-keep-app}"

echo "==> current daemon state"
if launchctl print "system/${HELPER_LABEL}" >/dev/null 2>&1; then
    launchctl print "system/${HELPER_LABEL}" | sed -n '1,12p'
else
    echo "    ${HELPER_LABEL} is not loaded"
fi

# The supported way to unregister is SMAppService.unregister() from the app itself, which is
# what the Remove Helper button in Settings does. This is the escape hatch for when the app
# will not launch or the registration is stale.
echo "==> booting out ${HELPER_LABEL} (requires admin)"
if sudo launchctl bootout "system/${HELPER_LABEL}" 2>/dev/null; then
    echo "    booted out"
else
    echo "    not loaded, or already removed"
fi

# Deliberately NOT run here: `sudo sfltool resetbtm` clears the background task database for
# the ENTIRE Mac, not just this app, so every other login item and daemon registration goes
# with it. It is mentioned in the closing message as a last resort for the user to decide on.

if [[ "${REMOVE_APP}" == "--remove-app" && -d "${INSTALLED_APP}" ]]; then
    echo "==> removing ${INSTALLED_APP}"
    rm -rf "${INSTALLED_APP}"
fi

cat <<EOF

Done.

If System Settings > General > Login Items & Extensions still lists ${PRODUCT_NAME_BASE},
remove it there. macOS keeps that record independently of launchd's loaded state.

If a registration is genuinely stuck, the last resort is:

    sudo sfltool resetbtm

Be aware that this resets the background task database for the whole Mac — every login item
and daemon from every application — so treat it as a recovery step, not routine cleanup.
EOF
