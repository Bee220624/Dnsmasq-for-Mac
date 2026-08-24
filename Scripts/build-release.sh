#!/bin/bash
# Produce a signed, Universal 2 Release build (ticket §Phase 12).
#
# This script is complete and will run end to end on a machine that has a Developer ID
# Application certificate. This machine does not — see Docs/RISKS.md R-01 — so it fails at the
# signing step with an explanation rather than producing something that looks like a release
# and is not.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-identifiers.sh
source "${SCRIPT_DIR}/lib-identifiers.sh"

DERIVED_DATA="${REPO_ROOT}/build/DerivedData"
RELEASE_DIR="${REPO_ROOT}/build/Release"
APP="${DERIVED_DATA}/Build/Products/Release/${PRODUCT_NAME_BASE}.app"

section() { printf '\n\033[1m==> %s\033[0m\n' "$1"; }
die() { printf '\033[31merror:\033[0m %s\n' "$1" >&2; exit 1; }

# ---------------------------------------------------------------------------------------
section "Checking for a Developer ID certificate"
# ---------------------------------------------------------------------------------------
# Checked first, before anything is built. A forty-second build that then cannot be signed
# wastes the developer's time and tells them nothing they could not have known up front.
IDENTITIES="$(security find-identity -v -p codesigning 2>/dev/null || true)"
if ! printf '%s' "${IDENTITIES}" | grep -q "Developer ID Application"; then
    cat >&2 <<EOF
error: no "Developer ID Application" certificate is installed.

Off-store distribution requires one; an Apple Development certificate is not sufficient,
because Gatekeeper will not accept it on another machine and notarization will refuse it.

Available identities:
$(printf '%s' "${IDENTITIES}" | sed 's/^/  /')

To proceed:
  1. In your Apple Developer account, create a Developer ID Application certificate.
  2. Download and install it into your login keychain.
  3. Confirm it appears in: security find-identity -v -p codesigning
  4. Re-run this script.

See Docs/RISKS.md R-01.
EOF
    exit 1
fi

SIGNING_IDENTITY="$(printf '%s' "${IDENTITIES}" \
    | grep "Developer ID Application" | head -1 \
    | sed -E 's/.*"(.*)"/\1/')"
echo "    using: ${SIGNING_IDENTITY}"

# ---------------------------------------------------------------------------------------
section "Verifying the vendored engine is present"
# ---------------------------------------------------------------------------------------
[[ -f "${REPO_ROOT}/Resources/ThirdParty/dnsmasq/dist/dnsmasq" ]] \
    || die "dnsmasq has not been vendored. Run: make vendor-dnsmasq"

# ---------------------------------------------------------------------------------------
section "Generating the project"
# ---------------------------------------------------------------------------------------
"${SCRIPT_DIR}/generate-project.sh"

# ---------------------------------------------------------------------------------------
section "Building Release (Universal 2)"
# ---------------------------------------------------------------------------------------
# ARCHS comes from Config/Release.xcconfig, which pins arm64 + x86_64. It is not overridden
# here so that what ships is what the checked-in configuration says.
rm -rf "${DERIVED_DATA}/Build/Products/Release"
xcodebuild \
    -project "${REPO_ROOT}/${PRODUCT_NAME_BASE}.xcodeproj" \
    -scheme "${PRODUCT_NAME_BASE}" \
    -configuration Release \
    -derivedDataPath "${DERIVED_DATA}" \
    CODE_SIGN_IDENTITY="${SIGNING_IDENTITY}" \
    build \
    | grep -E 'error:|warning: .*deprecat|\*\* BUILD' || true

[[ -d "${APP}" ]] || die "the Release build produced no app bundle"

# ---------------------------------------------------------------------------------------
section "Signing, inside out"
# ---------------------------------------------------------------------------------------
# Nested code is signed before the bundle that contains it. Signing the outer bundle first
# would be invalidated by every inner signature that followed.
sign() {
    local target="$1"
    [[ -e "${target}" ]] || return 0
    codesign --force --timestamp --options runtime \
        --sign "${SIGNING_IDENTITY}" "${target}"
    echo "    signed $(basename "${target}")"
}

sign "${APP}/Contents/Library/HelperTools/dnsmasq"
sign "${APP}/Contents/Library/HelperTools/${HELPER_LABEL}"
codesign --force --timestamp --options runtime \
    --entitlements "${REPO_ROOT}/Apps/${PRODUCT_NAME_BASE}/${PRODUCT_NAME_BASE}.entitlements" \
    --sign "${SIGNING_IDENTITY}" "${APP}"
echo "    signed ${PRODUCT_NAME_BASE}.app"

# ---------------------------------------------------------------------------------------
section "Verifying the signature"
# ---------------------------------------------------------------------------------------
codesign --verify --deep --strict --verbose=2 "${APP}"

# Gatekeeper's own assessment. Before notarization this reports the ticket as missing, which
# is expected at this stage and not a failure of the build.
echo "    Gatekeeper assessment:"
spctl --assess --type execute --verbose=4 "${APP}" 2>&1 | sed 's/^/      /' || true

# ---------------------------------------------------------------------------------------
section "Running the bundle checklist"
# ---------------------------------------------------------------------------------------
"${SCRIPT_DIR}/verify-bundle.sh" "${APP}"

# ---------------------------------------------------------------------------------------
section "Staging"
# ---------------------------------------------------------------------------------------
mkdir -p "${RELEASE_DIR}"
rm -rf "${RELEASE_DIR}/${PRODUCT_NAME_BASE}.app"
ditto "${APP}" "${RELEASE_DIR}/${PRODUCT_NAME_BASE}.app"

cat <<EOF

Release build staged: ${RELEASE_DIR}/${PRODUCT_NAME_BASE}.app

Next: Scripts/package-release.sh, which notarizes, staples, and produces the archive
along with the GPL source materials.
EOF
