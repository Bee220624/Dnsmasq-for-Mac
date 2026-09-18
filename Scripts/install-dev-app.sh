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
DERIVED_DATA="${DFM_DERIVED_DATA_ROOT:-${REPO_ROOT}/build/DerivedData}"
BUILT_APP="${DERIVED_DATA}/Build/Products/${CONFIGURATION}/${PRODUCT_NAME_BASE}.app"
APPLICATIONS_DIR="${DFM_APPLICATIONS_DIR:-/Applications}"
RUNTIME_ROOT="${DFM_HELPER_RUNTIME_ROOT:-${HELPER_RUNTIME_ROOT}}"
INSTALLED_APP="${APPLICATIONS_DIR}/${PRODUCT_NAME_BASE}.app"
ACTIVE_JOURNAL="${RUNTIME_ROOT}/active-session.json"
STAGED_APP="${APPLICATIONS_DIR}/.${PRODUCT_NAME_BASE}.app.install.$$"
BACKUP_APP="${APPLICATIONS_DIR}/.${PRODUCT_NAME_BASE}.app.backup.$$"
SUDO_COMMAND="${DFM_SUDO_COMMAND:-/usr/bin/sudo}"
LAUNCHCTL_COMMAND="${DFM_LAUNCHCTL_COMMAND:-/bin/launchctl}"
BACKUP_CREATED=0
REPLACEMENT_INSTALLED=0

process_is_running() {
    local executable_name="$1" escaped_name pattern status

    escaped_name="$(printf '%s' "${executable_name}" | sed 's/[][(){}.^$*+?|\\]/\\&/g')"
    pattern="^(.*/)?${escaped_name}([[:space:]]|$)"

    # macOS pgrep silently misses process names longer than 19 characters unless -f is used.
    # Anchor the full argument list at argv[0]'s basename so similarly named processes and
    # command arguments do not count as the app or Helper.
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

helper_is_loaded() {
    local output status

    if output="$("${LAUNCHCTL_COMMAND}" print "system/${HELPER_LABEL}" 2>&1)"; then
        return 0
    else
        status=$?
    fi

    if [[ ${status} -eq 113 && "${output}" == *"Could not find service"* ]]; then
        return 1
    fi

    echo "error: could not determine whether ${HELPER_LABEL} is loaded (launchctl status ${status})" >&2
    [[ -z "${output}" ]] || printf '       %s\n' "${output}" >&2
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
    if ! "${SUDO_COMMAND}" -v; then
        echo "error: admin authorization is required to inspect ${RUNTIME_ROOT}; no files were changed" >&2
        exit 1
    fi
    if ! "${SUDO_COMMAND}" -n /bin/test -d "${RUNTIME_ROOT}"; then
        echo "error: could not inspect Helper runtime directory ${RUNTIME_ROOT}; no files were changed" >&2
        exit 1
    fi

    if "${SUDO_COMMAND}" -n /bin/test -e "${ACTIVE_JOURNAL}"; then
        return 0
    else
        status=$?
    fi
    if [[ ${status} -ne 1 ]]; then
        echo "error: could not inspect Helper journal ${ACTIVE_JOURNAL}; no files were changed" >&2
        exit 1
    fi

    if "${SUDO_COMMAND}" -n /bin/test -L "${ACTIVE_JOURNAL}"; then
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

ensure_install_is_idle() {
    # Replacing a running app or helper can strand a session on old code. The installer never
    # kills either process: the app owns session cleanup and SMAppService registration.
    if process_is_running "${PRODUCT_NAME_BASE}"; then
        cat >&2 <<EOF
error: ${PRODUCT_DISPLAY_NAME} is still running.
       Stop any active session in the app, remove the Helper in Settings, then quit the app.
EOF
        exit 1
    fi

    if helper_is_loaded; then
        cat >&2 <<EOF
error: ${HELPER_LABEL} is still loaded.
       Open the installed app, stop the session, and use Settings > Remove Helper.
       If macOS still shows the Helper after removal, log out and back in before retrying.
EOF
        exit 1
    fi

    if process_is_running "${HELPER_LABEL}"; then
        echo "error: ${HELPER_LABEL} is still running; clean it up from the app before installing" >&2
        exit 1
    fi

    if runtime_has_active_journal; then
        cat >&2 <<EOF
error: Helper session evidence remains at ${ACTIVE_JOURNAL}.
       Open the installed app so the Helper can recover and clean the session, then choose
       Settings > Remove Helper. If the app cannot connect, restore this same app version first.
EOF
        exit 1
    fi
}

rollback_on_failure() {
    local status=$?
    trap - EXIT

    if [[ ${status} -ne 0 && ${REPLACEMENT_INSTALLED} -eq 1 ]]; then
        echo "==> installation failed; restoring the previous application" >&2
        if ! rm -rf "${INSTALLED_APP}"; then
            echo "error: could not remove the failed replacement at ${INSTALLED_APP}" >&2
        elif [[ ${BACKUP_CREATED} -eq 1 ]] && ! mv "${BACKUP_APP}" "${INSTALLED_APP}"; then
            echo "error: could not restore the previous application from ${BACKUP_APP}" >&2
        fi
    elif [[ ${status} -ne 0 && ${BACKUP_CREATED} -eq 1 ]]; then
        echo "==> installation failed; restoring the previous application" >&2
        if ! mv "${BACKUP_APP}" "${INSTALLED_APP}"; then
            echo "error: could not restore the previous application from ${BACKUP_APP}" >&2
        fi
    fi

    if [[ -e "${STAGED_APP}" ]] && ! rm -rf "${STAGED_APP}"; then
        echo "warning: could not remove staging path ${STAGED_APP}" >&2
    fi

    exit "${status}"
}
trap rollback_on_failure EXIT

if [[ ! -d "${BUILT_APP}" ]]; then
    echo "error: no ${CONFIGURATION} build found at ${BUILT_APP}" >&2
    echo "       run: make build" >&2
    exit 1
fi

echo "==> verifying the build before installing it"
"${SCRIPT_DIR}/verify-bundle.sh" "${BUILT_APP}"

ensure_install_is_idle

if [[ ! -d "${APPLICATIONS_DIR}" ]]; then
    echo "error: application directory does not exist: ${APPLICATIONS_DIR}" >&2
    exit 1
fi

echo "==> staging a copy at ${STAGED_APP}"
# ditto preserves the signature; a plain recursive copy can invalidate nested code signatures.
ditto "${BUILT_APP}" "${STAGED_APP}"

echo "==> verifying the staged copy"
codesign --verify --deep --strict --verbose=1 "${STAGED_APP}"

# Copying and authorization can take long enough for the user to reopen the app. Recheck every
# activity signal immediately before the first mutation of the installed application.
ensure_install_is_idle

if [[ -e "${INSTALLED_APP}" ]]; then
    echo "==> preserving the previous application for rollback"
    mv "${INSTALLED_APP}" "${BACKUP_APP}"
    BACKUP_CREATED=1
fi

echo "==> installing to ${INSTALLED_APP}"
mv "${STAGED_APP}" "${INSTALLED_APP}"
REPLACEMENT_INSTALLED=1

echo "==> verifying the installed copy"
codesign --verify --deep --strict --verbose=1 "${INSTALLED_APP}"

if [[ ${BACKUP_CREATED} -eq 1 ]]; then
    if ! rm -rf "${BACKUP_APP}"; then
        echo "warning: could not remove rollback backup ${BACKUP_APP}; the verified new app remains installed" >&2
    fi
    BACKUP_CREATED=0
fi
REPLACEMENT_INSTALLED=0
trap - EXIT

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
