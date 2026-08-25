#!/bin/bash
# Verify every localizable string has a Simplified Chinese translation (ticket §26.1).
#
# The list of strings comes from the **compiler**, not from a regular expression over the
# sources. Xcode emits a `.stringsdata` file per source file listing exactly which literals it
# treated as localizable, which catches the cases a grep cannot: literals passed to a function
# whose parameter is `LocalizedStringKey`, `String(localized:)` calls, and `Text` initialisers
# spread across several lines.
#
# That distinction is not academic — the first version of this project's catalog was built by
# regular expression and silently missed five strings, which then rendered in English inside an
# otherwise-translated UI.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-identifiers.sh
source "${SCRIPT_DIR}/lib-identifiers.sh"

CATALOG="${REPO_ROOT}/Apps/${PRODUCT_NAME_BASE}/Resources/Localizable.xcstrings"
DERIVED_DATA="${REPO_ROOT}/build/DerivedData"

[[ -f "${CATALOG}" ]] || { echo "error: no string catalog at ${CATALOG}" >&2; exit 1; }

if [[ ! -d "${DERIVED_DATA}" ]]; then
    echo "error: no build output. Run 'make build' first." >&2
    exit 1
fi

python3 - "$CATALOG" "$DERIVED_DATA" <<'PYTHON'
import json
import pathlib
import sys

catalog_path, derived_data = sys.argv[1], sys.argv[2]

# One .stringsdata per compiled source file, under the app target's object directory.
root = pathlib.Path(derived_data)
files = [
    path for path in root.rglob("*.stringsdata")
    if "MacNetLab.build/Objects-normal" in str(path)
    and "Screenshots" not in str(path)
    and "Tests" not in str(path)
]

if not files:
    print("error: no .stringsdata found; is SWIFT_EMIT_LOC_STRINGS enabled?", file=sys.stderr)
    sys.exit(1)

required = {}
for path in files:
    try:
        data = json.loads(path.read_text())
    except (ValueError, OSError):
        continue
    source = pathlib.Path(data.get("source", "?")).name
    for entries in data.get("tables", {}).values():
        for entry in entries:
            key = entry.get("key")
            if key:
                required.setdefault(key, source)

catalog = json.loads(pathlib.Path(catalog_path).read_text())
strings = catalog.get("strings", {})

def translation(key):
    unit = (
        strings.get(key, {})
        .get("localizations", {})
        .get("zh-Hans", {})
        .get("stringUnit", {})
    )
    return unit.get("value") if unit.get("state") == "translated" else None

missing = sorted(key for key in required if translation(key) is None)
stale = sorted(key for key in strings if key not in required)

print(f"compiler found {len(required)} localizable strings")
print(f"catalog holds   {len(strings)} entries")

if missing:
    print(f"\n{len(missing)} string(s) have no Simplified Chinese translation:")
    for key in missing:
        print(f"    [{required[key]}] {key!r}")

if stale:
    # Not a failure: a string may be referenced only from a source file that did not rebuild.
    print(f"\n{len(stale)} catalog entry(ies) are not referenced by the current build:")
    for key in stale:
        print(f"    {key!r}")

if missing:
    print("\nFAILED — untranslated strings render in English inside a translated UI.")
    sys.exit(1)

print("\nPASSED — every localizable string has a Simplified Chinese translation.")
PYTHON
