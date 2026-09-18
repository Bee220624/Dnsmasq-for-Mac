#!/bin/bash

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/dnsmasq-install-tests.XXXXXX")"
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

new_fixture() {
    local name="$1"
    FIXTURE="${TEST_ROOT}/${name}"
    REPO_COPY="${FIXTURE}/repo"
    TEST_APPLICATIONS="${FIXTURE}/Applications"
    TEST_RUNTIME="${FIXTURE}/runtime"
    STUB_BIN="${FIXTURE}/bin"

    mkdir -p "${REPO_COPY}/Scripts" "${REPO_COPY}/Config" "${STUB_BIN}" \
        "${TEST_APPLICATIONS}/DnsmasqForMac.app" "${TEST_RUNTIME}"
    cp "${REPO_ROOT}/Scripts/install-dev-app.sh" \
        "${REPO_ROOT}/Scripts/uninstall-dev-helper.sh" \
        "${REPO_ROOT}/Scripts/lib-identifiers.sh" \
        "${REPO_COPY}/Scripts/"
    cp "${REPO_ROOT}/Config/Identifiers.xcconfig" "${REPO_COPY}/Config/"

    BUILT_APP="${REPO_COPY}/build/DerivedData/Build/Products/Debug/DnsmasqForMac.app"
    mkdir -p "${BUILT_APP}"
    printf 'new-version\n' > "${BUILT_APP}/version.txt"
    mkdir -p "${BUILT_APP}/Contents/Library/HelperTools"
    printf 'new-helper-version\n' \
        > "${BUILT_APP}/Contents/Library/HelperTools/com.bee.dnsmasqformac.helper"
    printf 'old-version\n' > "${TEST_APPLICATIONS}/DnsmasqForMac.app/version.txt"

    USER_CONFIG="${FIXTURE}/user-data/profiles-v1.json"
    mkdir -p "$(dirname "${USER_CONFIG}")"
    printf '{"profile":"keep-me"}\n' > "${USER_CONFIG}"

    make_stub "${REPO_COPY}/Scripts/verify-bundle.sh" \
        '[[ -d "${1:?bundle path required}" ]]' \
        '[[ "${DFM_TEST_VERIFY_SOURCE_FAIL:-0}" != 1 ]]'

    make_stub "${STUB_BIN}/launchctl" \
        'command_name="${1:-}"' \
        'case "${command_name}" in' \
        '    print)' \
        '        [[ -f "${DFM_TEST_HELPER_STATE}" ]] && [[ "$(<"${DFM_TEST_HELPER_STATE}")" == loaded ]]' \
        '        ;;' \
        '    bootout)' \
        '        if [[ "${DFM_TEST_BOOTOUT_FAIL:-0}" == 1 ]]; then exit 78; fi' \
        '        printf "unloaded\n" > "${DFM_TEST_HELPER_STATE}"' \
        '        ;;' \
        '    *) exit 64 ;;' \
        'esac'

    make_stub "${STUB_BIN}/sudo" \
        'if [[ "${1:-}" == -v ]]; then [[ "${DFM_TEST_SUDO_INSPECTION_FAIL:-0}" != 1 ]]; exit; fi' \
        'if [[ "${1:-}" == test ]]; then shift; exec /bin/test "$@"; fi' \
        'exec "$@"'

    make_stub "${STUB_BIN}/pgrep" \
        'pattern="${*: -1}"' \
        'full_arguments=0' \
        'for argument in "$@"; do [[ "${argument}" == -f ]] && full_arguments=1; done' \
        'if [[ "${pattern}" == *DnsmasqForMac* && "${pattern}" != *dnsmasqformac*helper* && "${DFM_TEST_APP_RUNNING:-0}" == 1 ]]; then exit 0; fi' \
        'if [[ "${pattern}" == *dnsmasqformac*helper* && "${DFM_TEST_HELPER_RUNNING:-0}" == 1 ]]; then' \
        '    (( full_arguments == 1 )) && exit 0' \
        '    exit 1 # macOS pgrep silently misses process names longer than 19 characters without -f' \
        'fi' \
        'exit 1'

    make_stub "${STUB_BIN}/ditto" \
        'source_path="${1:?source required}"' \
        'destination="${2:?destination required}"' \
        'if [[ "${destination}" == /Applications/* ]]; then' \
        '    destination="${DFM_TEST_APPLICATIONS_DIR}/${destination#/Applications/}"' \
        'fi' \
        'case "${destination}" in "${DFM_TEST_APPLICATIONS_DIR}"/*) ;; *) exit 97 ;; esac' \
        '[[ "${DFM_TEST_DITTO_FAIL:-0}" != 1 ]] || exit 74' \
        '/bin/rm -rf "${destination}"' \
        'mkdir -p "$(dirname "${destination}")"' \
        '/usr/bin/ditto "${source_path}" "${destination}"'

    make_stub "${STUB_BIN}/rm" \
        'arguments=()' \
        'for argument in "$@"; do' \
        '    if [[ "${argument}" == /Applications/* ]]; then' \
        '        argument="${DFM_TEST_APPLICATIONS_DIR}/${argument#/Applications/}"' \
        '    elif [[ "${argument}" != -* ]]; then' \
        '        case "${argument}" in "${DFM_TEST_APPLICATIONS_DIR}"/*) ;; *) exit 97 ;; esac' \
        '    fi' \
        '    arguments+=("${argument}")' \
        'done' \
        'if [[ "${DFM_TEST_RM_BACKUP_FAIL:-0}" == 1 && " ${arguments[*]} " == *".backup."* ]]; then exit 73; fi' \
        'exec /bin/rm "${arguments[@]}"'

    make_stub "${STUB_BIN}/codesign" \
        'target="${*: -1}"' \
        'if [[ "${target}" == /Applications/* ]]; then' \
        '    target="${DFM_TEST_APPLICATIONS_DIR}/${target#/Applications/}"' \
        'fi' \
        'if [[ "${target}" == *".install."* && "${DFM_TEST_HELPER_LOAD_AFTER_STAGE:-0}" == 1 ]]; then' \
        '    printf "loaded\n" > "${DFM_TEST_HELPER_STATE}"' \
        'fi' \
        'case "${DFM_TEST_CODESIGN_FAIL:-}" in' \
        '    staged) [[ "${target}" != *".install."* ]] ;;' \
        '    installed) [[ "${target}" != "${DFM_TEST_APPLICATIONS_DIR}/DnsmasqForMac.app" ]] ;;' \
        '    *) exit 0 ;;' \
        'esac'

    printf 'unloaded\n' > "${FIXTURE}/helper-state"
}

run_script() {
    local output_file="$1"
    shift
    set +e
    PATH="${STUB_BIN}:/usr/bin:/bin:/usr/sbin:/sbin" \
        DFM_APPLICATIONS_DIR="${TEST_APPLICATIONS}" \
        DFM_DERIVED_DATA_ROOT="${REPO_COPY}/build/DerivedData" \
        DFM_HELPER_RUNTIME_ROOT="${TEST_RUNTIME}" \
        DFM_TEST_APPLICATIONS_DIR="${TEST_APPLICATIONS}" \
        DFM_TEST_HELPER_STATE="${FIXTURE}/helper-state" \
        "$@" > "${output_file}" 2>&1
    SCRIPT_STATUS=$?
    set -e
}

assert_old_app_preserved() {
    local name="$1"
    if [[ "$(<"${TEST_APPLICATIONS}/DnsmasqForMac.app/version.txt")" == old-version ]]; then
        pass "${name}: old app is preserved"
    else
        fail "${name}: old app was changed"
    fi
}

test_loaded_helper_blocks_install() {
    new_fixture loaded-helper
    printf 'loaded\n' > "${FIXTURE}/helper-state"
    run_script "${FIXTURE}/output" "${REPO_COPY}/Scripts/install-dev-app.sh"

    [[ ${SCRIPT_STATUS} -ne 0 ]] && pass "loaded helper: install is rejected" \
        || fail "loaded helper: install unexpectedly succeeded"
    assert_old_app_preserved "loaded helper"
}

test_unload_failure_is_fatal() {
    new_fixture unload-failure
    printf 'loaded\n' > "${FIXTURE}/helper-state"
    export DFM_TEST_BOOTOUT_FAIL=1
    run_script "${FIXTURE}/output" "${REPO_COPY}/Scripts/uninstall-dev-helper.sh" --remove-app
    unset DFM_TEST_BOOTOUT_FAIL

    [[ ${SCRIPT_STATUS} -ne 0 ]] && pass "unload failure: uninstall returns non-zero" \
        || fail "unload failure: uninstall swallowed the failure"
    assert_old_app_preserved "unload failure"
}

test_copy_failure_preserves_old_app() {
    new_fixture copy-failure
    export DFM_TEST_DITTO_FAIL=1
    run_script "${FIXTURE}/output" "${REPO_COPY}/Scripts/install-dev-app.sh"
    unset DFM_TEST_DITTO_FAIL

    [[ ${SCRIPT_STATUS} -ne 0 ]] && pass "copy failure: install returns non-zero" \
        || fail "copy failure: install unexpectedly succeeded"
    assert_old_app_preserved "copy failure"
}

test_staged_signature_failure_preserves_old_app() {
    new_fixture staged-signature-failure
    export DFM_TEST_CODESIGN_FAIL=staged
    run_script "${FIXTURE}/output" "${REPO_COPY}/Scripts/install-dev-app.sh"
    unset DFM_TEST_CODESIGN_FAIL

    [[ ${SCRIPT_STATUS} -ne 0 ]] && pass "staged signature failure: install returns non-zero" \
        || fail "staged signature failure: install unexpectedly succeeded"
    assert_old_app_preserved "staged signature failure"
}

test_final_signature_failure_rolls_back() {
    new_fixture final-signature-failure
    export DFM_TEST_CODESIGN_FAIL=installed
    run_script "${FIXTURE}/output" "${REPO_COPY}/Scripts/install-dev-app.sh"
    unset DFM_TEST_CODESIGN_FAIL

    [[ ${SCRIPT_STATUS} -ne 0 ]] && pass "final signature failure: install returns non-zero" \
        || fail "final signature failure: install unexpectedly succeeded"
    assert_old_app_preserved "final signature failure"
}

test_active_app_and_journal_block_install() {
    new_fixture active-app
    export DFM_TEST_APP_RUNNING=1
    run_script "${FIXTURE}/output" "${REPO_COPY}/Scripts/install-dev-app.sh"
    unset DFM_TEST_APP_RUNNING
    [[ ${SCRIPT_STATUS} -ne 0 ]] && pass "active app: install is rejected" \
        || fail "active app: install unexpectedly succeeded"
    assert_old_app_preserved "active app"

    new_fixture active-journal
    printf '{}\n' > "${TEST_RUNTIME}/active-session.json"
    run_script "${FIXTURE}/output" "${REPO_COPY}/Scripts/install-dev-app.sh"
    [[ ${SCRIPT_STATUS} -ne 0 ]] && pass "active journal: install is rejected" \
        || fail "active journal: install unexpectedly succeeded"
    assert_old_app_preserved "active journal"
}

test_running_long_named_helper_blocks_install() {
    new_fixture active-helper-process
    export DFM_TEST_HELPER_RUNNING=1
    run_script "${FIXTURE}/output" "${REPO_COPY}/Scripts/install-dev-app.sh"
    unset DFM_TEST_HELPER_RUNNING

    [[ ${SCRIPT_STATUS} -ne 0 ]] && pass "active Helper process: install is rejected" \
        || fail "active Helper process: install unexpectedly succeeded"
    assert_old_app_preserved "active Helper process"
}

test_backup_cleanup_failure_keeps_verified_new_app() {
    new_fixture backup-cleanup-failure
    export DFM_TEST_RM_BACKUP_FAIL=1
    run_script "${FIXTURE}/output" "${REPO_COPY}/Scripts/install-dev-app.sh"
    unset DFM_TEST_RM_BACKUP_FAIL

    [[ ${SCRIPT_STATUS} -eq 0 ]] && pass "backup cleanup failure: verified install remains successful" \
        || fail "backup cleanup failure: install was rolled back"
    [[ "$(<"${TEST_APPLICATIONS}/DnsmasqForMac.app/version.txt")" == new-version ]] \
        && pass "backup cleanup failure: verified new app remains installed" \
        || fail "backup cleanup failure: new app was replaced"
    grep -Fq 'warning: could not remove rollback backup' "${FIXTURE}/output" \
        && pass "backup cleanup failure: retained backup is reported" \
        || fail "backup cleanup failure: retained backup was not reported"
}

test_protected_clean_runtime_allows_install_and_uninstall() {
    new_fixture protected-clean-install
    chmod 000 "${TEST_RUNTIME}"
    run_script "${FIXTURE}/output" "${REPO_COPY}/Scripts/install-dev-app.sh"
    chmod 700 "${TEST_RUNTIME}"

    [[ ${SCRIPT_STATUS} -eq 0 ]] && pass "protected clean runtime: install succeeds after read-only admin check" \
        || fail "protected clean runtime: install was permanently blocked"
    [[ "$(<"${TEST_APPLICATIONS}/DnsmasqForMac.app/version.txt")" == new-version ]] \
        && pass "protected clean runtime: new app is installed" \
        || fail "protected clean runtime: old app remains"

    new_fixture protected-clean-uninstall
    chmod 000 "${TEST_RUNTIME}"
    run_script "${FIXTURE}/output" "${REPO_COPY}/Scripts/uninstall-dev-helper.sh" --remove-app
    chmod 700 "${TEST_RUNTIME}"

    [[ ${SCRIPT_STATUS} -eq 0 ]] && pass "protected clean runtime: uninstall succeeds after read-only admin check" \
        || fail "protected clean runtime: uninstall was permanently blocked"
    [[ ! -e "${TEST_APPLICATIONS}/DnsmasqForMac.app" ]] \
        && pass "protected clean runtime: requested app removal completes" \
        || fail "protected clean runtime: requested app removal did not complete"
}

test_helper_starting_during_staging_blocks_replacement() {
    new_fixture helper-started-during-staging
    export DFM_TEST_HELPER_LOAD_AFTER_STAGE=1
    run_script "${FIXTURE}/output" "${REPO_COPY}/Scripts/install-dev-app.sh"
    unset DFM_TEST_HELPER_LOAD_AFTER_STAGE

    [[ ${SCRIPT_STATUS} -ne 0 ]] && pass "late Helper start: install is rejected before replacement" \
        || fail "late Helper start: install unexpectedly succeeded"
    assert_old_app_preserved "late Helper start"
}

test_successful_upgrade_preserves_user_configuration() {
    new_fixture success
    run_script "${FIXTURE}/output" "${REPO_COPY}/Scripts/install-dev-app.sh"

    [[ ${SCRIPT_STATUS} -eq 0 ]] && pass "successful upgrade: install succeeds" \
        || fail "successful upgrade: install failed"
    [[ "$(<"${TEST_APPLICATIONS}/DnsmasqForMac.app/version.txt")" == new-version ]] \
        && pass "successful upgrade: new app is installed" \
        || fail "successful upgrade: installed app is not the new version"
    [[ "$(<"${TEST_APPLICATIONS}/DnsmasqForMac.app/Contents/Library/HelperTools/com.bee.dnsmasqformac.helper")" == new-helper-version ]] \
        && pass "successful upgrade: matching Helper is at the installed bundle path" \
        || fail "successful upgrade: installed Helper does not match the new app"
    [[ "$(<"${FIXTURE}/helper-state")" == unloaded ]] \
        && pass "successful upgrade: Helper remains unloaded for in-app registration" \
        || fail "successful upgrade: Helper state changed during install"
    [[ "$(<"${USER_CONFIG}")" == '{"profile":"keep-me"}' ]] \
        && pass "successful upgrade: user configuration is unchanged" \
        || fail "successful upgrade: user configuration changed"
}

test_loaded_helper_blocks_install
test_unload_failure_is_fatal
test_copy_failure_preserves_old_app
test_staged_signature_failure_preserves_old_app
test_final_signature_failure_rolls_back
test_active_app_and_journal_block_install
test_running_long_named_helper_blocks_install
test_backup_cleanup_failure_keeps_verified_new_app
test_protected_clean_runtime_allows_install_and_uninstall
test_helper_starting_during_staging_blocks_replacement
test_successful_upgrade_preserves_user_configuration

printf '\n%d passed, %d failed\n' "${PASS_COUNT}" "${FAIL_COUNT}"
(( FAIL_COUNT == 0 ))
