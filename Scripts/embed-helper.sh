#!/bin/bash
# Render the LaunchDaemon plist template into the built app bundle.
#
# Runs as a post-build phase of the MacNetLab target. The plist cannot simply be copied,
# because its Label, Mach service name, and BundleProgram path all come from
# Config/Identifiers.xcconfig.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-identifiers.sh
source "${SCRIPT_DIR}/lib-identifiers.sh"

: "${BUILT_PRODUCTS_DIR:?must run from an Xcode build phase}"
: "${WRAPPER_NAME:?must run from an Xcode build phase}"

APP_PATH="${BUILT_PRODUCTS_DIR}/${WRAPPER_NAME}"
TEMPLATE="${REPO_ROOT}/Resources/LaunchDaemons/${HELPER_LABEL}.plist.template"
DAEMON_DIR="${APP_PATH}/Contents/Library/LaunchDaemons"
OUTPUT="${DAEMON_DIR}/${HELPER_LABEL}.plist"

if [[ ! -f "${TEMPLATE}" ]]; then
    echo "error: missing LaunchDaemon template at ${TEMPLATE}" >&2
    exit 1
fi

mkdir -p "${DAEMON_DIR}"

sed \
    -e "s|@HELPER_LABEL@|${HELPER_LABEL}|g" \
    -e "s|@MACH_SERVICE_NAME@|${MACH_SERVICE_NAME}|g" \
    -e "s|@APP_BUNDLE_ID@|${APP_BUNDLE_ID}|g" \
    "${TEMPLATE}" > "${OUTPUT}"

# A malformed daemon plist fails silently at registration time, so validate it here where
# the error is attributable to this build step.
plutil -lint "${OUTPUT}" >/dev/null

# Sanity check: no placeholder survived substitution. Inspect the parsed values rather than
# the raw file, so that the template's own explanatory comments are not mistaken for
# leftover tokens.
# Captured before matching: piping into `grep -q` under `pipefail` inverts the result,
# because grep closes the pipe on its first match and plutil then dies of SIGPIPE.
PARSED_VALUES="$(plutil -p "${OUTPUT}" 2>/dev/null || true)"
if [[ "${PARSED_VALUES}" =~ @[A-Z_]+@ ]]; then
    echo "error: unsubstituted placeholder remains in ${OUTPUT}" >&2
    printf '%s\n' "${PARSED_VALUES}" | grep -n '@[A-Z_]*@' >&2 || true
    exit 1
fi

echo "==> embedded ${OUTPUT}"
