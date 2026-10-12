#!/usr/bin/env bash
# Export or verify Cuekeeper's CloudKit schema. Never imports, deploys or resets.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "$here/scripts/cloudkit_schema.py" "$@"
