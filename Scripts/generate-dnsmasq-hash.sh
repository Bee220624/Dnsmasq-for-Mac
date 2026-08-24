#!/bin/bash
# record the SHA-256 of the vendored dnsmasq binary
#
# Implemented in Phase 4. Failing loudly here is deliberate: a silent no-op would let a
# caller believe this step ran.

set -euo pipefail

echo "error: Scripts/generate-dnsmasq-hash.sh is implemented in Phase 4 and is not available yet." >&2
exit 1
