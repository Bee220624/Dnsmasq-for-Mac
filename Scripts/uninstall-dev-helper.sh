#!/bin/bash
# Unregister the development helper and remove the staged app.
#
# Useful when iterating: a registered daemon holds a reference to a specific app bundle, so a
# stale registration produces confusing failures after the bundle is rebuilt or moved.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-identifiers.sh
source "${SCRIPT_DIR}/lib-identifiers.sh"

APPLICATIONS_DIR="${DFM_APPLICATIONS_DIR:-/Applications}"
RUNTIME_ROOT="${DFM_HELPER_RUNTIME_ROOT:-${HELPER_RUNTIME_ROOT}}"
INSTALLED_APP="${APPLICATIONS_DIR}/${PRODUCT_NAME_BASE}.app"
ACTIVE_JOURNAL="${RUNTIME_ROOT}/active-session.json"
REMOVE_APP="${1:-keep-app}"

process_is_running() {
    local executable_name="$1" escaped_name pattern status

    escaped_name="$(printf '%s' "${executable_name}" | sed 's/[][(){}.^$*+?|\\]/\\&/g')"
    pattern="^(.*/)?${escaped_name}([[:space:]]|$)"

    # The Helper name is longer than macOS pgrep's process-name limit, so match its complete
    # argv[0] basename instead. The anchors exclude similarly named processes and arguments.
    if pgrep -f "${pattern}" >/dev/null 2>&1; then
        return 0
    else
        status=$?
    fi
    if [[ ${status} -eq 1 ]]; then
        return 1
    fi

    echo "error: could not determine whether ${executable_name} is running" >&2
    exit 1
}

runtime_has_active_journal() {
    local status

    if [[ ! -e "${RUNTIME_ROOT}" && ! -L "${RUNTIME_ROOT}" ]]; then
        return 1
    fi
    if [[ ! -d "${RUNTIME_ROOT}" ]]; then
        echo "error: Helper runtime path is not a directory: ${RUNTIME_ROOT}" >&2
        exit 1
    fi

    if [[ -x "${RUNTIME_ROOT}" ]]; then
        [[ -e "${ACTIVE_JOURNAL}" || -L "${ACTIVE_JOURNAL}" ]]
        return
    fi

    echo "==> checking protected Helper runtime state (requires admin)"
    if ! sudo -v; then
        echo "error: admin authorization is required to inspect ${RUNTIME_ROOT}; no files were changed" >&2
        exit 1
    fi
    if ! sudo test -d "${RUNTIME_ROOT}"; then
        echo "error: could not inspect Helper runtime directory ${RUNTIME_ROOT}; no files were changed" >&2
        exit 1
    fi

    if sudo test -e "${ACTIVE_JOURNAL}"; then
        return 0
    else
        status=$?
    fi
    if [[ ${status} -ne 1 ]]; then
        echo "error: could not inspect Helper journal ${ACTIVE_JOURNAL}; no files were changed" >&2
        exit 1
    fi

    if sudo test -L "${ACTIVE_JOURNAL}"; then
        return 0
    else
        status=$?
    fi
    if [[ ${status} -ne 1 ]]; then
        echo "error: could not inspect Helper journal ${ACTIVE_JOURNAL}; no files were changed" >&2
        exit 1
    fi

    return 1
}

if process_is_running "${PRODUCT_NAME_BASE}"; then
    echo "error: quit ${PRODUCT_DISPLAY_NAME} before removing its Helper" >&2
    exit 1
fi

if runtime_has_active_journal; then
    cat >&2 <<EOF
error: Helper session evidence remains at ${ACTIVE_JOURNAL}.
       Use the app to stop or recover the session before removing the Helper. If the app cannot
       connect, restore the matching installed app and retry recovery; do not delete the journal.
EOF
    exit 1
fi

echo "==> current daemon state"
if launchctl print "system/${HELPER_LABEL}" >/dev/null 2>&1; then
    launchctl print "system/${HELPER_LABEL}" | sed -n '1,12p'
    HELPER_LOADED=1
else
    echo "    ${HELPER_LABEL} is not loaded"
    HELPER_LOADED=0
fi

# The supported way to unregister is SMAppService.unregister() from the app itself, which is
# what the Remove Helper button in Settings does. This is the escape hatch for when the app
# will not launch or the registration is stale.
if [[ ${HELPER_LOADED} -eq 1 ]]; then
    echo "==> booting out ${HELPER_LABEL} (requires admin)"
    if ! sudo launchctl bootout "system/${HELPER_LABEL}"; then
        echo "error: launchctl could not boot out ${HELPER_LABEL}; the app was not removed" >&2
        exit 1
    fi
    echo "    booted out"
fi

if launchctl print "system/${HELPER_LABEL}" >/dev/null 2>&1; then
    echo "error: ${HELPER_LABEL} is still loaded; the app was not removed" >&2
    exit 1
fi

if process_is_running "${HELPER_LABEL}"; then
    echo "error: ${HELPER_LABEL} is still running; the app was not removed" >&2
    exit 1
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
