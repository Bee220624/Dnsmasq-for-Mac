#!/bin/bash
# Notarize, staple, and package a release.
#
# Requires a notarytool keychain profile. Create one once with:
#
#   xcrun notarytool store-credentials DnsmasqForMac \
#       --apple-id you@example.com --team-id <TEAM> --password <app-specific-password>
#
# Neither the credentials nor the profile are stored in this repository, and nothing here
# writes them anywhere.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-identifiers.sh
source "${SCRIPT_DIR}/lib-identifiers.sh"

RELEASE_DIR="${REPO_ROOT}/build/Release"
APP="${RELEASE_DIR}/${PRODUCT_NAME_BASE}.app"
VENDOR_DIR="${REPO_ROOT}/Resources/ThirdParty/dnsmasq"

NOTARY_PROFILE="${DNSMASQFORMAC_NOTARY_PROFILE:-DnsmasqForMac}"

section() { printf '\n\033[1m==> %s\033[0m\n' "$1"; }
die() { printf '\033[31merror:\033[0m %s\n' "$1" >&2; exit 1; }

[[ -d "${APP}" ]] || die "no staged release. Run: Scripts/build-release.sh"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
    "${APP}/Contents/Info.plist")"
ARCHIVE="${RELEASE_DIR}/${PRODUCT_NAME_BASE}-${VERSION}.zip"

# ---------------------------------------------------------------------------------------
section "Creating the archive"
# ---------------------------------------------------------------------------------------
# ditto with --keepParent, which is the format notarytool expects and which preserves the
# nested signatures. A plain `zip` loses extended attributes and invalidates them.
rm -f "${ARCHIVE}"
ditto -c -k --keepParent "${APP}" "${ARCHIVE}"
echo "    ${ARCHIVE}"

# ---------------------------------------------------------------------------------------
section "Notarizing"
# ---------------------------------------------------------------------------------------
if ! xcrun notarytool history --keychain-profile "${NOTARY_PROFILE}" \
        >/dev/null 2>&1; then
    cat >&2 <<EOF
error: no notarytool keychain profile named "${NOTARY_PROFILE}".

Create one, once, with:

  xcrun notarytool store-credentials ${NOTARY_PROFILE} \\
      --apple-id <your-apple-id> \\
      --team-id ${DFM_DEVELOPMENT_TEAM} \\
      --password <app-specific-password>

The app-specific password is generated at appleid.apple.com. It is stored in your keychain,
never in this repository.

See Docs/RISKS.md R-01.
EOF
    exit 1
fi

xcrun notarytool submit "${ARCHIVE}" \
    --keychain-profile "${NOTARY_PROFILE}" \
    --wait \
    || die "notarization failed. Inspect the log with: xcrun notarytool log <submission-id> --keychain-profile ${NOTARY_PROFILE}"

# ---------------------------------------------------------------------------------------
section "Stapling"
# ---------------------------------------------------------------------------------------
# Stapled to the .app, then re-archived. A ticket attached to the zip would be lost the moment
# the user expanded it, which defeats the point on a machine that is offline.
xcrun stapler staple "${APP}"
xcrun stapler validate "${APP}"

rm -f "${ARCHIVE}"
ditto -c -k --keepParent "${APP}" "${ARCHIVE}"

# ---------------------------------------------------------------------------------------
section "Confirming Gatekeeper accepts it"
# ---------------------------------------------------------------------------------------
spctl --assess --type execute --verbose=4 "${APP}" 2>&1 | sed 's/^/    /'

# ---------------------------------------------------------------------------------------
section "Packaging the GPL source materials"
# ---------------------------------------------------------------------------------------
# Distributing the app distributes dnsmasq, and recipients are entitled to the corresponding
# source. Reproducibility is not the same obligation: the archive itself has to travel with
# the binary, not merely be cited (Docs/RISKS.md R-06).
SOURCE_BUNDLE="${RELEASE_DIR}/${PRODUCT_NAME_BASE}-${VERSION}-dnsmasq-source"
rm -rf "${SOURCE_BUNDLE}"
mkdir -p "${SOURCE_BUNDLE}"

DNSMASQ_VERSION="$(tr -d '[:space:]' < "${VENDOR_DIR}/VERSION")"
SOURCE_ARCHIVE="${VENDOR_DIR}/source/dnsmasq-${DNSMASQ_VERSION}.tar.xz"

[[ -f "${SOURCE_ARCHIVE}" ]] \
    || die "the dnsmasq source archive is missing. Run: make vendor-dnsmasq"

cp "${SOURCE_ARCHIVE}" "${SOURCE_BUNDLE}/"
cp "${VENDOR_DIR}/COPYING" "${VENDOR_DIR}/COPYING-v3" "${SOURCE_BUNDLE}/"
cp "${VENDOR_DIR}/VERSION" "${VENDOR_DIR}/SOURCE_URL" "${VENDOR_DIR}/SHA256SUMS" \
   "${SOURCE_BUNDLE}/"
cp "${SCRIPT_DIR}/build-dnsmasq.sh" "${SOURCE_BUNDLE}/"
if compgen -G "${VENDOR_DIR}/patches/*.patch" >/dev/null 2>&1; then
    mkdir -p "${SOURCE_BUNDLE}/patches"
    cp "${VENDOR_DIR}"/patches/*.patch "${SOURCE_BUNDLE}/patches/"
fi

cat > "${SOURCE_BUNDLE}/README.txt" <<EOF
dnsmasq source corresponding to ${PRODUCT_NAME_BASE} ${VERSION}

${PRODUCT_NAME_BASE} bundles dnsmasq ${DNSMASQ_VERSION}, licensed under the GNU General Public
License version 2 or version 3. This directory contains the corresponding source, the licence
texts, and the exact script used to build the binary that ships inside the app.

  dnsmasq-${DNSMASQ_VERSION}.tar.xz  the unmodified upstream source
  SOURCE_URL                          where it was obtained
  SHA256SUMS                          its digest, verified at build time
  build-dnsmasq.sh                    the build procedure, including compile options
  COPYING, COPYING-v3                 the licence texts
  patches/                            any applied patches (absent if none were needed)

dnsmasq is bundled as a separate, unmodified executable. No dnsmasq source or object code is
compiled or linked into any ${PRODUCT_NAME_BASE} binary.
EOF

SOURCE_ZIP="${SOURCE_BUNDLE}.zip"
rm -f "${SOURCE_ZIP}"
ditto -c -k --keepParent "${SOURCE_BUNDLE}" "${SOURCE_ZIP}"
rm -rf "${SOURCE_BUNDLE}"

cat <<EOF

Release packaged.

  App:    ${ARCHIVE}
  Source: ${SOURCE_ZIP}

Both must be published together: distributing the app distributes dnsmasq, and the
corresponding source has to accompany it.

Before publishing, complete Docs/MANUAL_TEST_PLAN.md on a clean macOS 14 machine.
EOF
