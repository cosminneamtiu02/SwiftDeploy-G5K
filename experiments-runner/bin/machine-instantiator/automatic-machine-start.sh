#!/usr/bin/env bash
# automatic-machine-start.sh
# Purpose: Placeholder for automatic instantiation. Not implemented.
# Exit code 2 per spec.

set -Eeuo pipefail
IFS=$'\n\t'
trap 'echo "[ERROR] ${BASH_SOURCE[0]}:$LINENO ${BASH_COMMAND}" >&2' ERR

echo "TODO: automatic machine instantiation — not implemented yet"
echo "not implemented yet" >&2
exit 2
