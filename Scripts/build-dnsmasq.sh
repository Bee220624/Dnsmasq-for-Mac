#!/bin/bash
# Fetch, verify, and build dnsmasq as a Universal 2 binary (ticket §22).
#
# Everything about which dnsmasq ships is data in Resources/ThirdParty/dnsmasq/: the version,
# the URL, the archive digest, and the signing key fingerprint. Nothing is hardcoded here, so
# an upgrade is an edit to those files plus a re-run — reviewable as a diff.
#
# Usage: build-dnsmasq.sh [--skip-download]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-identifiers.sh
source "${SCRIPT_DIR}/lib-identifiers.sh"

VENDOR_DIR="${REPO_ROOT}/Resources/ThirdParty/dnsmasq"
SOURCE_DIR="${VENDOR_DIR}/source"
BUILD_DIR="${VENDOR_DIR}/build"
DIST_DIR="${VENDOR_DIR}/dist"

VERSION="$(tr -d '[:space:]' < "${VENDOR_DIR}/VERSION")"
SOURCE_URL="$(tr -d '[:space:]' < "${VENDOR_DIR}/SOURCE_URL")"
EXPECTED_FINGERPRINT="$(tr -d '[:space:]' < "${VENDOR_DIR}/SIGNING_KEY_FINGERPRINT")"

ARCHIVE="dnsmasq-${VERSION}.tar.xz"
ARCHIVE_PATH="${SOURCE_DIR}/${ARCHIVE}"
SIGNATURE_PATH="${ARCHIVE_PATH}.asc"

# Ticket §3.5. Each of these removes a whole subsystem from the shipped binary: code that is
# not compiled in cannot be reached by a configuration mistake, and cannot carry a
# vulnerability. v0.1 serves DNS and DHCPv4 and nothing else.
#
#   NO_TFTP      - no file server. Out of scope until PXE lands as its own ticket.
#   NO_DHCP6     - IPv4 only.
#   NO_SCRIPT    - no lease-change hooks, so dnsmasq can never execute anything.
#   NO_AUTH      - no authoritative zone serving; this is a forwarder plus local records.
#   NO_DUMPFILE  - no packet capture.
#   NO_ID        - no chaos-class version queries.
COPTS="-DNO_TFTP -DNO_DHCP6 -DNO_SCRIPT -DNO_AUTH -DNO_DUMPFILE -DNO_ID"

DEPLOYMENT_TARGET="$(sed -n -E 's/^[[:space:]]*MACOSX_DEPLOYMENT_TARGET[[:space:]]*=[[:space:]]*(.*[^[:space:]])[[:space:]]*$/\1/p' \
    "${REPO_ROOT}/Config/Base.xcconfig" | tail -1)"
: "${DEPLOYMENT_TARGET:=14.0}"

SKIP_DOWNLOAD=0
[[ "${1:-}" == "--skip-download" ]] && SKIP_DOWNLOAD=1

section() { printf '\n\033[1m==> %s\033[0m\n' "$1"; }
die() { printf '\033[31merror:\033[0m %s\n' "$1" >&2; exit 1; }

# ---------------------------------------------------------------------------------------
section "Fetching dnsmasq ${VERSION}"
# ---------------------------------------------------------------------------------------
mkdir -p "${SOURCE_DIR}"

if [[ "${SKIP_DOWNLOAD}" -eq 0 || ! -f "${ARCHIVE_PATH}" ]]; then
    echo "    ${SOURCE_URL}"
    curl -fsSL --max-time 300 -o "${ARCHIVE_PATH}" "${SOURCE_URL}" \
        || die "could not download ${SOURCE_URL}"
    curl -fsSL --max-time 120 -o "${SIGNATURE_PATH}" "${SOURCE_URL}.asc" \
        || die "could not download the detached signature"
else
    echo "    using cached ${ARCHIVE_PATH}"
fi

# ---------------------------------------------------------------------------------------
section "Verifying the archive"
# ---------------------------------------------------------------------------------------
# Check 1: digest. Catches any change to the artefact we vetted, whatever the cause.
ACTUAL_SHA="$(shasum -a 256 "${ARCHIVE_PATH}" | awk '{print $1}')"
EXPECTED_SHA="$(awk '{print $1}' "${VENDOR_DIR}/SHA256SUMS")"
if [[ "${ACTUAL_SHA}" != "${EXPECTED_SHA}" ]]; then
    die "SHA-256 mismatch
       expected ${EXPECTED_SHA}
         actual ${ACTUAL_SHA}
     Refusing to build. If this is an intentional upgrade, update
     Resources/ThirdParty/dnsmasq/SHA256SUMS in the same change that updates VERSION."
fi
echo "    sha256 ok: ${ACTUAL_SHA}"

# Check 2: signature, made by the pinned key.
#
# The fingerprint pin is the part that matters. Fetching a key and trusting it because it
# signed the file would be circular; requiring a specific fingerprint means a compromised
# keyserver produces a build failure rather than a silent substitution.
if command -v gpg >/dev/null 2>&1; then
    # A short GNUPGHOME on purpose: gpg-agent's socket path is subject to the ~104 byte Unix
    # socket limit, and a long temporary path fails with a confusing "dirmngr" error.
    GNUPGHOME="$(mktemp -d /tmp/mnlgpg.XXXXXX)"
    export GNUPGHOME
    chmod 700 "${GNUPGHOME}"
    trap 'rm -rf "${GNUPGHOME}"' EXIT

    if ! gpg --batch --quiet --keyserver hkps://keyserver.ubuntu.com \
             --recv-keys "${EXPECTED_FINGERPRINT}" 2>/dev/null; then
        echo "    warning: could not fetch the signing key; skipping signature check" >&2
        echo "    the SHA-256 pin above still applies" >&2
    else
        VERIFY_OUTPUT="$(gpg --batch --status-fd 1 --verify \
            "${SIGNATURE_PATH}" "${ARCHIVE_PATH}" 2>/dev/null || true)"

        case "${VERIFY_OUTPUT}" in
            *GOODSIG*) ;;
            *) die "the archive's OpenPGP signature did not verify" ;;
        esac

        # VALIDSIG carries the fingerprint of the key that actually made the signature.
        case "${VERIFY_OUTPUT}" in
            *"VALIDSIG ${EXPECTED_FINGERPRINT}"*)
                echo "    signature ok: ${EXPECTED_FINGERPRINT}" ;;
            *)
                die "signature was made by a different key than
     ${EXPECTED_FINGERPRINT}
     Refusing to build." ;;
        esac
    fi
else
    echo "    warning: gpg not installed; signature not checked (brew bundle installs it)" >&2
fi

# ---------------------------------------------------------------------------------------
section "Extracting"
# ---------------------------------------------------------------------------------------
EXTRACTED="${SOURCE_DIR}/dnsmasq-${VERSION}"
rm -rf "${EXTRACTED}"
tar -xJf "${ARCHIVE_PATH}" -C "${SOURCE_DIR}"
[[ -d "${EXTRACTED}" ]] || die "archive did not contain dnsmasq-${VERSION}/"

# Ticket §22.1: never edit the vendored source in place. A patch, if one is ever needed, is
# applied here from patches/ so that what ships is always source + recorded patches.
if compgen -G "${VENDOR_DIR}/patches/*.patch" >/dev/null 2>&1; then
    section "Applying patches"
    for patch in "${VENDOR_DIR}"/patches/*.patch; do
        echo "    $(basename "${patch}")"
        patch -d "${EXTRACTED}" -p1 < "${patch}" || die "failed to apply ${patch}"
    done
fi

# ---------------------------------------------------------------------------------------
# Build each architecture in its own clean tree.
#
# dnsmasq's Makefile leaves object files beside the source. Building two architectures in one
# tree silently links whichever objects happen to be there — a class of bug that produces a
# binary that runs on the build machine and fails everywhere else.
# ---------------------------------------------------------------------------------------
build_arch() {
    local arch="$1"
    local arch_build="${BUILD_DIR}/${arch}"

    section "Building ${arch}"
    rm -rf "${arch_build}"
    mkdir -p "${arch_build}"
    cp -R "${EXTRACTED}/." "${arch_build}/"

    make -C "${arch_build}" \
        CC="clang" \
        CFLAGS="-arch ${arch} -O2 -Wall -Wextra -mmacosx-version-min=${DEPLOYMENT_TARGET}" \
        LDFLAGS="-arch ${arch} -mmacosx-version-min=${DEPLOYMENT_TARGET}" \
        COPTS="${COPTS}" \
        >"${arch_build}/build.log" 2>&1 \
        || { tail -30 "${arch_build}/build.log" >&2; die "${arch} build failed"; }

    [[ -f "${arch_build}/src/dnsmasq" ]] || die "${arch} build produced no binary"

    local produced
    produced="$(lipo -archs "${arch_build}/src/dnsmasq")"
    [[ "${produced}" == "${arch}" ]] \
        || die "${arch} build produced ${produced}; object files leaked between architectures"

    echo "    ok: $(cd "${arch_build}/src" && pwd)/dnsmasq (${produced})"
}

build_arch arm64
build_arch x86_64

# ---------------------------------------------------------------------------------------
section "Merging into a Universal 2 binary"
# ---------------------------------------------------------------------------------------
mkdir -p "${DIST_DIR}"
UNIVERSAL="${DIST_DIR}/dnsmasq"
lipo -create "${BUILD_DIR}/arm64/src/dnsmasq" "${BUILD_DIR}/x86_64/src/dnsmasq" \
    -output "${UNIVERSAL}"
chmod 755 "${UNIVERSAL}"

ARCHS="$(lipo -archs "${UNIVERSAL}")"
[[ "${ARCHS}" == *arm64* ]] || die "merged binary has no arm64 slice (${ARCHS})"
[[ "${ARCHS}" == *x86_64* ]] || die "merged binary has no x86_64 slice (${ARCHS})"
echo "    architectures: ${ARCHS}"

# ---------------------------------------------------------------------------------------
section "Checking linkage"
# ---------------------------------------------------------------------------------------
# Ticket §3.2 and §22.3: the shipped binary must run on a clean Mac. A stray Homebrew include
# path is the usual way this breaks, and it fails only on the user's machine, never on ours.
# For a universal binary, otool -L prints a "<path> (architecture <arch>):" header before
# each slice's list. Only the indented dylib lines are dependencies; the headers are not.
LINKAGE="$(otool -L "${UNIVERSAL}" | grep -E '^[[:space:]]+/' || true)"
NON_SYSTEM="$(printf '%s\n' "${LINKAGE}" \
    | grep -vE '^[[:space:]]+(/usr/lib/|/System/Library/)' || true)"
if [[ -n "${NON_SYSTEM}" ]]; then
    printf '%s\n' "${LINKAGE}" >&2
    die "dnsmasq links a non-system library; it would not run on a clean Mac"
fi
printf '%s\n' "${LINKAGE}" | sed 's/^/    /'

# ---------------------------------------------------------------------------------------
section "Verifying compiled features"
# ---------------------------------------------------------------------------------------
# Runs the native slice. On this host that is arm64; the x86_64 slice cannot be executed here
# without Rosetta, which is recorded in Docs/RISKS.md R-07.
VERSION_OUTPUT="$("${UNIVERSAL}" --version 2>&1 || true)"
printf '%s\n' "${VERSION_OUTPUT}" | sed 's/^/    /'

case "${VERSION_OUTPUT}" in
    *"Dnsmasq version ${VERSION}"*) ;;
    *) die "binary does not report version ${VERSION}" ;;
esac

# dnsmasq prints its compile-time options as a list, prefixing a disabled one with "no-".
# Presence of the bare word therefore means enabled.
compile_options="$(printf '%s\n' "${VERSION_OUTPUT}" | sed -n 's/^Compile time options: //p')"
[[ -n "${compile_options}" ]] || compile_options="${VERSION_OUTPUT}"

require_enabled() {
    case " ${compile_options} " in
        *" $1 "*) echo "    ✓ $1 is compiled in" ;;
        *) die "$1 is NOT compiled in; MacNetLab cannot serve DHCP without it" ;;
    esac
}
require_disabled() {
    case " ${compile_options} " in
        *" $1 "*) die "$1 is compiled in but must not be (ticket §3.5)" ;;
        *) echo "    ✓ $1 is not compiled in" ;;
    esac
}

require_enabled DHCP
require_disabled TFTP
require_disabled DHCPv6
require_disabled auth
require_disabled dumpfile

# ---------------------------------------------------------------------------------------
section "Smoke-testing configuration parsing"
# ---------------------------------------------------------------------------------------
# `--test` reads and validates a configuration without starting anything, which is the same
# mechanism preflight uses before every start (ticket §9.10).
SMOKE_CONF="$(mktemp -t mnl-dnsmasq-smoke)"
cat > "${SMOKE_CONF}" <<'CONF'
port=0
interface=lo0
bind-interfaces
no-hosts
no-resolv
CONF
"${UNIVERSAL}" --test --conf-file="${SMOKE_CONF}" >/dev/null 2>&1 \
    || { rm -f "${SMOKE_CONF}"; die "--test rejected a minimal valid configuration"; }
rm -f "${SMOKE_CONF}"
echo "    ✓ --test accepts a minimal configuration"

# ---------------------------------------------------------------------------------------
section "Recording the binary digest"
# ---------------------------------------------------------------------------------------
"${SCRIPT_DIR}/generate-dnsmasq-hash.sh" "${UNIVERSAL}"

cat <<EOF

dnsmasq ${VERSION} built: ${UNIVERSAL}

It is staged into the app bundle by the build, and its digest is re-checked by the helper
before every launch. Run 'make build' next, then 'make verify-bundle'.
EOF
