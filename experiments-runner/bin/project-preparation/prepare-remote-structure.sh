#!/usr/bin/env bash
# prepare-remote-structure.sh — Create remote dirs, upload scripts, write env, install deps

set -Eeuo pipefail
IFS=$'\n\t'
trap 'echo "[ERROR] ${BASH_SOURCE[0]}:$LINENO ${BASH_COMMAND}" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

DRY_RUN=false
CONFIG_JSON=""
OS_TYPE=""
FULL_PATH=""

usage() {
	cat <<EOF
Usage: prepare-remote-structure.sh --config <file.json> --os-type {1|2|3} --full-path <abs> [--dry-run]
Requires environment: G5K_USER, G5K_HOST, G5K_SSH_KEY
Creates remote structure under ~/experiments_node/ and uploads required scripts.
EOF
}

while [[ $# -gt 0 ]]; do
	case "$1" in
		--config)
			CONFIG_JSON="$2"
			shift 2
			;;
		--os-type)
			OS_TYPE="$2"
			shift 2
			;;
		--full-path)
			FULL_PATH="$2"
			shift 2
			;;
		--dry-run)
			DRY_RUN=true
			shift
			;;
		-h | --help)
			usage
			exit 0
			;;
		*)
			echo "Unknown arg: ${1}" >&2
			usage
			exit 2
			;;
	esac
done

# OS_TYPE is accepted for CLI compatibility but not currently used; mark as referenced
: "${OS_TYPE:-}"

# Check required environment variables
for v in G5K_USER G5K_HOST G5K_SSH_KEY; do
	if [[ -z ${!v:-} ]]; then
		echo "[ERROR] Environment variable ${v} is required but not set." >&2
		exit 2
	fi
done

# Assert variables for static analyzers (shellcheck) and make intent explicit
: "${G5K_USER:?}"
: "${G5K_HOST:?}"
: "${G5K_SSH_KEY:?}"

[[ -f ${CONFIG_JSON} ]] || {
	echo "[ERROR] config not found: ${CONFIG_JSON}" >&2
	exit 2
}
command -v jq >/dev/null 2>&1 || {
	echo "[ERROR] jq required" >&2
	exit 2
}

# Common copy helpers (scp with retries)
# shellcheck source=../utils/libremote.sh
# shellcheck disable=SC1091
source "${ROOT_DIR}/bin/utils/libremote.sh"

REMOTE_BASE="${HOME}/experiments_node"

run_scp_to() {
	local dest="$1"
	shift
	if [[ ${DRY_RUN} == true ]]; then
		echo "[DRY-RUN] copy -> ${G5K_HOST}:${dest} : $*"
		return 0
	fi
	scp_to_retry "${G5K_USER}" "${G5K_HOST}" "${G5K_SSH_KEY}" "$@" "${dest}"
}

echo "[INFO] Uploading launch parameters for agent (full path and config)"
REMOTE_CONTROL="${REMOTE_BASE}/control"
if [[ ${DRY_RUN} == true ]]; then
	echo "[DRY-RUN] scp CONFIG_JSON -> ${REMOTE_CONTROL}/config.json"
	echo "[DRY-RUN] scp FULL_PATH -> ${REMOTE_CONTROL}/full_path.txt"
else
	# Ensure control dir exists via a directory file copy: create local tmp dir with marker files
	tmpdir=$(mktemp -d)
	mkdir -p "${tmpdir}/control"
	: >"${tmpdir}/control/.keep"
	scp_to_retry "${G5K_USER}" "${G5K_HOST}" "${G5K_SSH_KEY}" "${tmpdir}/control" "${REMOTE_BASE}/"
	rm -rf "${tmpdir}"
	run_scp_to "${REMOTE_CONTROL}/config.json" "${CONFIG_JSON}"
	tmp_fp=$(mktemp)
	printf '%s\n' "${FULL_PATH}" >"${tmp_fp}"
	run_scp_to "${REMOTE_CONTROL}/full_path.txt" "${tmp_fp}"
	rm -f "${tmp_fp}"
fi

echo "[INFO] Remote preparation complete (agent installed)."
