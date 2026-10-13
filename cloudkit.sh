#!/usr/bin/env bash
# Initialize Development, export, or verify the CloudKit schema. Never deploys or resets.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ "${1:-}" = "init" ]; then
    shift
    exec python3 "$here/scripts/initialize_cloudkit.py" "$@"
fi
exec python3 "$here/scripts/cloudkit_schema.py" "$@"
