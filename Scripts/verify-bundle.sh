#!/bin/bash
# Assert that a built MacNetLab.app satisfies the security checklist in ticket §22.5.
#
# This runs against the *built artefact*, not the source, because that is what ships. Every
# check either passes, or the script exits non-zero naming exactly what failed.
#
# Usage: verify-bundle.sh [path-to-MacNetLab.app]
#        defaults to the Debug build in build/DerivedData.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-identifiers.sh
source "${SCRIPT_DIR}/lib-identifiers.sh"

APP="${1:-${REPO_ROOT}/build/DerivedData/Build/Products/Debug/${PRODUCT_NAME_BASE}.app}"

FAILURES=0
WARNINGS=0

pass() { printf '  \033[32m✓\033[0m %s\n' "$1"; }
fail() { printf '  \033[31m✗\033[0m %s\n' "$1"; FAILURES=$((FAILURES + 1)); }
warn() { printf '  \033[33m!\033[0m %s\n' "$1"; WARNINGS=$((WARNINGS + 1)); }
section() { printf '\n\033[1m%s\033[0m\n' "$1"; }

echo "Verifying: ${APP}"

HELPER="${APP}/Contents/Library/HelperTools/${HELPER_LABEL}"
DAEMON_PLIST="${APP}/Contents/Library/LaunchDaemons/${HELPER_LABEL}.plist"
DNSMASQ="${APP}/Contents/Library/HelperTools/dnsmasq"

# ---------------------------------------------------------------------------------------
section "Layout"
# ---------------------------------------------------------------------------------------
[[ -d "${APP}" ]] && pass "app bundle exists" || { fail "app bundle missing: ${APP}"; exit 1; }
[[ -f "${APP}/Contents/MacOS/${PRODUCT_NAME_BASE}" ]] \
    && pass "app executable exists" || fail "app executable missing"
[[ -f "${HELPER}" ]] && pass "helper executable exists" || fail "helper executable missing"
[[ -f "${DAEMON_PLIST}" ]] && pass "LaunchDaemon plist exists" || fail "LaunchDaemon plist missing"

# ---------------------------------------------------------------------------------------
section "Identifiers"
# ---------------------------------------------------------------------------------------
if [[ -f "${APP}/Contents/Info.plist" ]]; then
    actual="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "${APP}/Contents/Info.plist" 2>/dev/null || echo '')"
    [[ "${actual}" == "${APP_BUNDLE_ID}" ]] \
        && pass "app bundle id is ${APP_BUNDLE_ID}" \
        || fail "app bundle id is '${actual}', expected '${APP_BUNDLE_ID}'"
fi

if [[ -f "${DAEMON_PLIST}" ]]; then
    label="$(/usr/libexec/PlistBuddy -c 'Print :Label' "${DAEMON_PLIST}" 2>/dev/null || echo '')"
    [[ "${label}" == "${HELPER_LABEL}" ]] \
        && pass "daemon label is ${HELPER_LABEL}" \
        || fail "daemon label is '${label}', expected '${HELPER_LABEL}'"

    # The Mach service name must match what the helper listens on and what the app dials.
    if /usr/libexec/PlistBuddy -c "Print :MachServices:${MACH_SERVICE_NAME}" "${DAEMON_PLIST}" >/dev/null 2>&1; then
        pass "daemon declares mach service ${MACH_SERVICE_NAME}"
    else
        fail "daemon does not declare mach service ${MACH_SERVICE_NAME}"
    fi

    program="$(/usr/libexec/PlistBuddy -c 'Print :BundleProgram' "${DAEMON_PLIST}" 2>/dev/null || echo '')"
    [[ "${program}" == "Contents/Library/HelperTools/${HELPER_LABEL}" ]] \
        && pass "BundleProgram points at the embedded helper" \
        || fail "BundleProgram is '${program}'"

    # Ticket §10.1: nothing may start at boot or on load.
    for forbidden in RunAtLoad KeepAlive StartInterval; do
        if /usr/libexec/PlistBuddy -c "Print :${forbidden}" "${DAEMON_PLIST}" >/dev/null 2>&1; then
            fail "daemon plist sets ${forbidden}; the helper must be on-demand only"
        else
            pass "daemon plist does not set ${forbidden}"
        fi
    done
fi

# ---------------------------------------------------------------------------------------
section "Code signature"
# ---------------------------------------------------------------------------------------
if codesign --verify --deep --strict "${APP}" 2>/dev/null; then
    pass "signature valid (deep, strict)"
else
    fail "codesign --verify --deep --strict failed"
fi

if [[ -f "${HELPER}" ]]; then
    if codesign --verify --strict "${HELPER}" 2>/dev/null; then
        pass "helper signature valid"
    else
        fail "helper signature invalid"
    fi

    helper_team="$(codesign -dv "${HELPER}" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
    [[ "${helper_team}" == "${MNL_DEVELOPMENT_TEAM}" ]] \
        && pass "helper team is ${MNL_DEVELOPMENT_TEAM}" \
        || fail "helper team is '${helper_team}', expected '${MNL_DEVELOPMENT_TEAM}'"

    app_team="$(codesign -dv "${APP}" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
    [[ "${app_team}" == "${helper_team}" ]] \
        && pass "app and helper share a team identifier" \
        || fail "app team '${app_team}' does not match helper team '${helper_team}'"
fi

# ---------------------------------------------------------------------------------------
section "Hardening"
# ---------------------------------------------------------------------------------------
# Output is captured before matching rather than piped into `grep -q`. Under `pipefail`,
# `grep -q` closes the pipe on its first match, the producer dies of SIGPIPE, and the
# pipeline reports failure — inverting the result of every check written that way.
SIGNATURE_INFO="$(codesign -d --verbose=2 "${APP}" 2>&1 || true)"
if [[ "${SIGNATURE_INFO}" == *"(runtime)"* ]]; then
    pass "hardened runtime enabled"
else
    fail "hardened runtime is not enabled"
fi

# Ticket §10.4 / §12: a release bundle must not carry the relaxed development policy.
CONFIG_NAME="$(basename "$(dirname "${APP}")")"
if [[ "${CONFIG_NAME}" == "Release" ]]; then
    ENTITLEMENTS="$(codesign -d --entitlements - --xml "${APP}" 2>/dev/null || true)"
    if [[ "${ENTITLEMENTS}" == *"get-task-allow"* ]]; then
        fail "release bundle carries get-task-allow"
    else
        pass "release bundle does not carry get-task-allow"
    fi
fi

# ---------------------------------------------------------------------------------------
section "Permissions"
# ---------------------------------------------------------------------------------------
writable="$(find "${APP}" -type f -perm -0002 2>/dev/null || true)"
if [[ -z "${writable}" ]]; then
    pass "no world-writable files"
else
    fail "world-writable files present:"
    echo "${writable}" | sed 's/^/      /'
fi

# ---------------------------------------------------------------------------------------
section "Dependencies"
# ---------------------------------------------------------------------------------------
# Ticket §3.2: the shipped product must not depend on Homebrew or any non-system library.
check_linkage() {
    local binary="$1" name="$2"
    [[ -f "${binary}" ]] || return 0
    local bad
    bad="$(otool -L "${binary}" 2>/dev/null | tail -n +2 \
        | grep -E '/opt/homebrew|/usr/local/opt|/usr/local/lib' || true)"
    if [[ -z "${bad}" ]]; then
        pass "${name} links only system libraries"
    else
        fail "${name} links non-system libraries:"
        echo "${bad}" | sed 's/^/      /'
    fi
}
check_linkage "${APP}/Contents/MacOS/${PRODUCT_NAME_BASE}" "app"
check_linkage "${HELPER}" "helper"

# ---------------------------------------------------------------------------------------
section "GPL licence texts"
# ---------------------------------------------------------------------------------------
# The app ships a GPL program, so each copy of the app has to carry the licence with it
# (GPL v2 §1). Checked here because the failure is silent otherwise: the app still runs, the
# Settings links simply stop rendering, and nobody notices until it is already distributed.
for licence in COPYING COPYING-v3; do
    bundled="${APP}/Contents/Resources/${licence}"
    vendored="${REPO_ROOT}/Resources/ThirdParty/dnsmasq/${licence}"
    if [[ ! -f "${bundled}" ]]; then
        fail "${licence} is not in the bundle"
    elif cmp -s "${bundled}" "${vendored}"; then
        pass "${licence} present and identical to the vendored text"
    else
        fail "${licence} in the bundle differs from ${vendored}"
    fi
done

# ---------------------------------------------------------------------------------------
section "Bundled dnsmasq"
# ---------------------------------------------------------------------------------------
if [[ -f "${DNSMASQ}" ]]; then
    check_linkage "${DNSMASQ}" "dnsmasq"

    if codesign --verify --strict "${DNSMASQ}" 2>/dev/null; then
        pass "dnsmasq signature valid"
    else
        fail "dnsmasq signature invalid"
    fi

    # The digest is taken of the *unsigned* build artefact, not of the copy in the bundle.
    #
    # codesign writes the signature into the Mach-O itself, so the bundled file's bytes — and
    # therefore its digest — necessarily differ from what came out of the compiler. Comparing
    # the bundled copy against the build digest could never pass. What this check answers is
    # "did we ship the dnsmasq we built?", and the dist copy is the right subject for it.
    #
    # Provenance of the copy that actually runs is established by its code signature, checked
    # below and re-checked by the helper before every launch.
    EXPECTED_HASH_FILE="${REPO_ROOT}/Resources/ThirdParty/dnsmasq/BINARY_SHA256"
    DIST_DNSMASQ="${REPO_ROOT}/Resources/ThirdParty/dnsmasq/dist/dnsmasq"
    if [[ -f "${EXPECTED_HASH_FILE}" && -f "${DIST_DNSMASQ}" ]]; then
        expected="$(tr -d '[:space:]' < "${EXPECTED_HASH_FILE}")"
        actual="$(shasum -a 256 "${DIST_DNSMASQ}" | awk '{print $1}')"
        [[ "${expected}" == "${actual}" ]] \
            && pass "vendored dnsmasq matches its recorded digest" \
            || fail "vendored dnsmasq digest mismatch: expected ${expected}, got ${actual}"
    else
        fail "no recorded dnsmasq digest at ${EXPECTED_HASH_FILE}"
    fi

    # The bundled copy must satisfy the same requirement the helper will demand of it.
    DNSMASQ_REQUIREMENT="anchor apple generic and certificate leaf[subject.OU] = \"${MNL_DEVELOPMENT_TEAM}\""
    if codesign --verify -R="${DNSMASQ_REQUIREMENT}" "${DNSMASQ}" 2>/dev/null; then
        pass "bundled dnsmasq is signed by team ${MNL_DEVELOPMENT_TEAM}"
    else
        fail "bundled dnsmasq does not satisfy the team requirement"
    fi

    # Ticket §21.3: a binary a normal user can rewrite is a binary the root helper would
    # happily execute.
    if [[ -L "${DNSMASQ}" ]]; then
        fail "bundled dnsmasq is a symlink"
    else
        pass "bundled dnsmasq is a regular file"
    fi
    if [[ -n "$(find "${DNSMASQ}" -perm -0022 2>/dev/null)" ]]; then
        fail "bundled dnsmasq is group- or world-writable"
    else
        pass "bundled dnsmasq is not group- or world-writable"
    fi

    EXPECTED_VERSION="$(tr -d '[:space:]' < "${REPO_ROOT}/Resources/ThirdParty/dnsmasq/VERSION")"

    DNSMASQ_VERSION_OUTPUT="$("${DNSMASQ}" --version 2>/dev/null || true)"
    if [[ "${DNSMASQ_VERSION_OUTPUT}" == *"Dnsmasq version ${EXPECTED_VERSION}"* ]]; then
        pass "bundled dnsmasq reports version ${EXPECTED_VERSION}"
    else
        fail "bundled dnsmasq did not report version ${EXPECTED_VERSION}"
    fi

    # Ticket §3.5: features that are not compiled in cannot be reached by a configuration
    # mistake and cannot carry a vulnerability. Asserted on the shipped copy, not just at
    # build time, because this is the binary that will actually run.
    for feature in TFTP DHCPv6 auth dumpfile; do
        if [[ " ${DNSMASQ_VERSION_OUTPUT} " == *" ${feature} "* ]]; then
            fail "bundled dnsmasq has ${feature} compiled in"
        else
            pass "bundled dnsmasq has no ${feature}"
        fi
    done
    if [[ " ${DNSMASQ_VERSION_OUTPUT} " == *" DHCP "* ]]; then
        pass "bundled dnsmasq has DHCP compiled in"
    else
        fail "bundled dnsmasq has no DHCP support"
    fi
else
    # Phase 4 vendors dnsmasq. Before then its absence is expected, and reporting it as a
    # hard failure would make this script useless for the phases that come first.
    warn "dnsmasq is not bundled yet (vendored in Phase 4; run 'make vendor-dnsmasq')"
fi

# ---------------------------------------------------------------------------------------
section "Architectures"
# ---------------------------------------------------------------------------------------
if [[ "${CONFIG_NAME}" == "Release" ]]; then
    for binary in "${APP}/Contents/MacOS/${PRODUCT_NAME_BASE}" "${HELPER}" "${DNSMASQ}"; do
        [[ -f "${binary}" ]] || continue
        archs="$(lipo -archs "${binary}" 2>/dev/null || echo '')"
        if [[ "${archs}" == *arm64* && "${archs}" == *x86_64* ]]; then
            pass "$(basename "${binary}") is Universal 2 (${archs})"
        else
            fail "$(basename "${binary}") is not Universal 2 (got: ${archs})"
        fi
    done
else
    warn "architecture check skipped: Universal 2 is a Release requirement (this is ${CONFIG_NAME})"
fi

# ---------------------------------------------------------------------------------------
printf '\n'
if (( FAILURES > 0 )); then
    printf '\033[31mFAILED\033[0m — %d check(s) failed, %d warning(s)\n' "${FAILURES}" "${WARNINGS}"
    exit 1
fi
printf '\033[32mPASSED\033[0m — all checks passed, %d warning(s)\n' "${WARNINGS}"
