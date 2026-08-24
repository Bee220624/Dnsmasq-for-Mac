#!/bin/bash
# Stage the helper's payload into the built app bundle.
#
# Runs as a post-build phase of the MacNetLab target and does two things:
#
#   1. Renders the LaunchDaemon plist template. It cannot simply be copied, because its
#      Label, Mach service name, and BundleProgram path all come from
#      Config/Identifiers.xcconfig.
#   2. Copies the vendored dnsmasq next to the helper and signs it.
#
# Both land under Contents/Library, and both must be in place before Xcode's own code signing
# phase seals the bundle.

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

# --- dnsmasq -----------------------------------------------------------------------------
DNSMASQ_SOURCE="${REPO_ROOT}/Resources/ThirdParty/dnsmasq/dist/dnsmasq"
HELPER_TOOLS_DIR="${APP_PATH}/Contents/Library/HelperTools"
DNSMASQ_DEST="${HELPER_TOOLS_DIR}/dnsmasq"

if [[ ! -f "${DNSMASQ_SOURCE}" ]]; then
    # Not fatal: the app and helper are perfectly buildable before dnsmasq has been vendored,
    # and failing here would block every build until someone ran a network-dependent step.
    # Scripts/verify-bundle.sh reports the absence, and the helper refuses to start a session
    # without a verified binary, so this cannot be mistaken for a working build.
    echo "warning: no vendored dnsmasq at ${DNSMASQ_SOURCE}; run 'make vendor-dnsmasq'" >&2
    exit 0
fi

mkdir -p "${HELPER_TOOLS_DIR}"
# ditto rather than cp: it preserves the extended attributes a signature lives in.
ditto "${DNSMASQ_SOURCE}" "${DNSMASQ_DEST}"

# The digest the helper checks is of the file as it sits in the bundle, so verify it here —
# a copy that changed the bytes would otherwise only be discovered at launch.
EXPECTED_DIGEST="$(tr -d '[:space:]' < "${REPO_ROOT}/Resources/ThirdParty/dnsmasq/BINARY_SHA256")"
ACTUAL_DIGEST="$(shasum -a 256 "${DNSMASQ_DEST}" | awk '{print $1}')"
if [[ "${EXPECTED_DIGEST}" != "${ACTUAL_DIGEST}" ]]; then
    echo "error: staged dnsmasq does not match its recorded digest" >&2
    echo "       expected ${EXPECTED_DIGEST}" >&2
    echo "         actual ${ACTUAL_DIGEST}" >&2
    exit 1
fi

# Xcode signs nested code it placed itself; a file added by a script is invisible to it, so
# this signs dnsmasq explicitly before the outer bundle signature seals it.
if [[ -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]]; then
    codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY}" \
        --options runtime --timestamp=none "${DNSMASQ_DEST}"
    echo "==> signed ${DNSMASQ_DEST}"
fi

echo "==> embedded dnsmasq (${ACTUAL_DIGEST})"
