#!/bin/bash

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/dnsmasq-make-tests.XXXXXX")"
PASS_COUNT=0
FAIL_COUNT=0

cleanup() {
    /bin/rm -rf "${TEST_ROOT}"
}
trap cleanup EXIT

pass() {
    printf 'ok - %s\n' "$1"
    PASS_COUNT=$((PASS_COUNT + 1))
}

fail() {
    printf 'not ok - %s\n' "$1" >&2
    FAIL_COUNT=$((FAIL_COUNT + 1))
}

make_stub() {
    local path="$1"
    shift
    mkdir -p "$(dirname "${path}")"
    printf '%s\n' '#!/bin/bash' 'set -euo pipefail' "$@" > "${path}"
    chmod +x "${path}"
}

FIXTURE="${TEST_ROOT}/repo"
STUB_BIN="${TEST_ROOT}/bin"
RENDER_MARKER="${TEST_ROOT}/screenshot-rendered"
mkdir -p "${FIXTURE}/Scripts" "${STUB_BIN}"
cp "${REPO_ROOT}/Makefile" "${FIXTURE}/Makefile"

make_stub "${FIXTURE}/Scripts/generate-project.sh" 'exit 0'
make_stub "${STUB_BIN}/xcodebuild" 'printf "%s\n" "** TEST FAILED **"' 'exit 42'
make_stub \
    "${FIXTURE}/build/DerivedData/Build/Products/Debug/DnsmasqForMacScreenshots.app/Contents/MacOS/DnsmasqForMacScreenshots" \
    'touch "${RENDER_MARKER:?}"' \
    'exit 0'

expect_xcode_failure() {
    local target="$1"
    if PATH="${STUB_BIN}:${PATH}" RENDER_MARKER="${RENDER_MARKER}" \
        make -C "${FIXTURE}" "${target}" >/dev/null 2>&1; then
        fail "${target} propagates xcodebuild failure"
    else
        pass "${target} propagates xcodebuild failure"
    fi
}

expect_xcode_failure test-xcode
expect_xcode_failure test-ui
expect_xcode_failure screenshots

if [[ -e "${RENDER_MARKER}" ]]; then
    fail "screenshots skips rendering after a build failure"
else
    pass "screenshots skips rendering after a build failure"
fi

make_stub "${STUB_BIN}/xcodebuild" 'printf "%s\n" "** TEST SUCCEEDED **"' 'exit 0'
for target in test-xcode test-ui screenshots; do
    if PATH="${STUB_BIN}:${PATH}" RENDER_MARKER="${RENDER_MARKER}" \
        make -C "${FIXTURE}" "${target}" >/dev/null 2>&1; then
        pass "${target} accepts xcodebuild success"
    else
        fail "${target} accepts xcodebuild success"
    fi
done

printf '%s passed; %s failed\n' "${PASS_COUNT}" "${FAIL_COUNT}"
[[ "${FAIL_COUNT}" -eq 0 ]]
