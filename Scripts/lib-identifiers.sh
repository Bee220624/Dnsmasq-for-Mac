#!/bin/bash
# Shared helper: expose Config/Identifiers.xcconfig to shell scripts.
#
# Ticket §3.1 requires that identifiers live in exactly one place. Scripts therefore parse
# the xcconfig rather than repeating literals, so a pre-release rename stays a one-file edit.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IDENTIFIERS_FILE="${REPO_ROOT}/Config/Identifiers.xcconfig"

if [[ ! -f "${IDENTIFIERS_FILE}" ]]; then
    echo "error: missing ${IDENTIFIERS_FILE}" >&2
    exit 1
fi

# Read one KEY from the xcconfig. Values are literals; xcconfig $(VAR) references are
# resolved one level deep, which is all this project uses.
identifier_value() {
    local key="$1" value
    value="$(sed -n -E "s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*(.*[^[:space:]])[[:space:]]*$/\1/p" \
        "${IDENTIFIERS_FILE}" | tail -1)"

    if [[ -z "${value}" ]]; then
        echo "error: ${key} not defined in ${IDENTIFIERS_FILE}" >&2
        return 1
    fi

    # Resolve a single level of $(OTHER_KEY) indirection.
    while [[ "${value}" =~ \$\(([A-Z_][A-Z0-9_]*)\) ]]; do
        local ref="${BASH_REMATCH[1]}" resolved
        resolved="$(sed -n -E "s/^[[:space:]]*${ref}[[:space:]]*=[[:space:]]*(.*[^[:space:]])[[:space:]]*$/\1/p" \
            "${IDENTIFIERS_FILE}" | tail -1)"
        if [[ -z "${resolved}" ]]; then
            echo "error: ${key} references undefined ${ref}" >&2
            return 1
        fi
        value="${value//\$(${ref})/${resolved}}"
    done

    printf '%s' "${value}"
}

export PRODUCT_NAME_BASE="$(identifier_value PRODUCT_NAME_BASE)"
export APP_BUNDLE_ID="$(identifier_value APP_BUNDLE_ID)"
export HELPER_LABEL="$(identifier_value HELPER_LABEL)"
export MACH_SERVICE_NAME="$(identifier_value MACH_SERVICE_NAME)"
export PROTOCOL_VERSION="$(identifier_value PROTOCOL_VERSION)"
export APP_VERSION="$(identifier_value APP_VERSION)"
export APP_BUILD="$(identifier_value APP_BUILD)"
export MNL_DEVELOPMENT_TEAM="$(identifier_value DEVELOPMENT_TEAM)"
export HELPER_RUNTIME_ROOT="$(identifier_value HELPER_RUNTIME_ROOT)"
