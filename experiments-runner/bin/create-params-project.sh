#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

if [[ $# -ne 1 ]]; then
	echo "Usage: $0 <project-name>" >&2
	exit 2
fi

PROJECT_NAME="$1"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PARAMS_DIR="${ROOT_DIR}/params/${PROJECT_NAME}"
PARAMS_FILE="${PARAMS_DIR}/${PROJECT_NAME}.txt"

if [[ -d ${PARAMS_DIR} ]]; then
	echo "Project params directory already exists: ${PARAMS_DIR}" >&2
	exit 1
fi

mkdir -p "${PARAMS_DIR}"
cat >"${PARAMS_FILE}" <<'EOF'
# params for project
# one params line per experiment
# e.g. arg1 arg2 arg3

EOF

echo "Created ${PARAMS_FILE}"

echo "Note: trackers will be created next to the params file as ${PARAMS_FILE%.txt}_tracker.txt and are ignored by .gitignore"
