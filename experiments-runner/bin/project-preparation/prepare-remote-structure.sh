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

# Common SSH helpers (key-only auth, retries)
# shellcheck source=../utils/libremote.sh
# shellcheck disable=SC1091
source "${ROOT_DIR}/bin/utils/libremote.sh"

REMOTE_BASE="${HOME}/experiments_node"
REMOTE_ONM="${REMOTE_BASE}/on-machine"
REMOTE_BOOTSTRAP="${REMOTE_ONM}/bootstrap"
REMOTE_EXECUTABLES="${REMOTE_ONM}/executables"
REMOTE_RESULTS="${REMOTE_ONM}/results"
REMOTE_LOGS="${REMOTE_ONM}/logs"
REMOTE_COLLECTION="${REMOTE_ONM}/collection"

run_ssh() {
	if [[ ${DRY_RUN} == true ]]; then
		echo "[DRY-RUN] remote: $*"
		return 0
	fi
	ssh_retry "${G5K_USER}" "${G5K_HOST}" "${G5K_SSH_KEY}" "$*"
}

run_scp_to() {
	local dest="$1"
	shift
	if [[ ${DRY_RUN} == true ]]; then
		echo "[DRY-RUN] copy -> ${G5K_HOST}:${dest} : $*"
		return 0
	fi
	scp_to_retry "${G5K_USER}" "${G5K_HOST}" "${G5K_SSH_KEY}" "$@" "${dest}"
}

echo "[INFO] Creating remote directories under ${REMOTE_BASE}"
run_ssh "mkdir -p '${REMOTE_EXECUTABLES}' '${REMOTE_RESULTS}' '${REMOTE_LOGS}' '${REMOTE_COLLECTION}' '${REMOTE_BOOTSTRAP}'"

echo "[INFO] Uploading on-machine scripts"
run_scp_to "${REMOTE_ONM}/" \
	"${ROOT_DIR}/bin/experiments-delegator/on-machine/run-batch.sh"

if compgen -G "${ROOT_DIR}/bin/experiments-collector/on-machine/*.sh" >/dev/null; then
	run_scp_to "${REMOTE_ONM}/collection/" "${ROOT_DIR}/bin/experiments-collector/on-machine/"*.sh
fi

echo "[INFO] Ensuring full_path_to_executable directory exists: ${FULL_PATH}"
REMOTE_EXEC_DIR="$(dirname "${FULL_PATH}")"
run_ssh "mkdir -p '${REMOTE_EXEC_DIR}' && { test -f '${FULL_PATH}' && chmod +x '${FULL_PATH}' || true; }"

echo "[INFO] Writing environment variables on remote"
TMP_JSON="/tmp/exp_config_$$.json"
TMP_WRITE_ENV="/tmp/write-env_$$.sh"
if [[ ${DRY_RUN} == true ]]; then
	echo "[DRY-RUN] upload config to remote: ${CONFIG_JSON} -> ${TMP_JSON}"
	echo "[DRY-RUN] upload write-env.sh to remote: ${TMP_WRITE_ENV}"
else
	# Use the same copy helper to benefit from oarcp when in an OAR context
	run_scp_to "${TMP_JSON}" "${CONFIG_JSON}"
	run_scp_to "${TMP_WRITE_ENV}" "${ROOT_DIR}/bin/project-preparation/node-setup/write-env.sh"
fi
opt_dry=""
if [[ ${DRY_RUN} == true ]]; then opt_dry=" --dry-run"; fi
run_ssh "bash '${TMP_WRITE_ENV}' --json-file '${TMP_JSON}'${opt_dry}"

echo "[INFO] Skipping package installation (list_of_needed_libraries removed). Remote preparation complete."

echo "[INFO] Remote preparation complete."
