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
PKG_FILE=""

usage() {
	cat <<EOF
Usage: prepare-remote-structure.sh --config <file.json> --os-type {1|2|3} --full-path <abs> --packages-file <path> [--dry-run]
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
		--packages-file)
			PKG_FILE="$2"
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

# Check required environment variables
for v in G5K_USER G5K_HOST G5K_SSH_KEY; do
	if [[ -z ${!v:-} ]]; then
		echo "[ERROR] Environment variable ${v} is required but not set." >&2
		exit 2
	fi
done

[[ -f ${CONFIG_JSON} ]] || {
	echo "[ERROR] config not found: ${CONFIG_JSON}" >&2
	exit 2
}
command -v jq >/dev/null 2>&1 || {
	echo "[ERROR] jq required" >&2
	exit 2
}

REMOTE_BASE="${HOME}/experiments_node"
REMOTE_ONM="${REMOTE_BASE}/on-machine"
REMOTE_BOOTSTRAP="${REMOTE_ONM}/bootstrap"
REMOTE_EXECUTABLES="${REMOTE_ONM}/executables"
REMOTE_RESULTS="${REMOTE_ONM}/results"
REMOTE_LOGS="${REMOTE_ONM}/logs"
REMOTE_COLLECTION="${REMOTE_ONM}/collection"

run_ssh() {
	if [[ ${DRY_RUN} == true ]]; then
		if [[ -z ${G5K_USER:-} ]]; then
			echo "G5K_USER is not set" >&2
			exit 1
		fi
		if [[ -z ${G5K_HOST:-} ]]; then
			echo "G5K_HOST is not set" >&2
			exit 1
		fi
		echo "[DRY-RUN] ssh ${G5K_USER}@${G5K_HOST}: $*"
	else
		if [[ -z ${G5K_SSH_KEY:-} ]]; then
			echo "G5K_SSH_KEY is not set" >&2
			exit 1
		fi
		ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -i "${G5K_SSH_KEY}" "${G5K_USER}@${G5K_HOST}" "$*"
	fi
}

run_scp_to() {
	local dest="$1"
	shift
	if [[ ${DRY_RUN} == true ]]; then
		echo "[DRY-RUN] scp -> ${G5K_USER}@${G5K_HOST}:${dest} : $*"
	else
		scp -o BatchMode=yes -o StrictHostKeyChecking=accept-new -i "${G5K_SSH_KEY}" -r "$@" "${G5K_USER}@${G5K_HOST}:${dest}"
	fi
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
	scp -o BatchMode=yes -o StrictHostKeyChecking=accept-new -i "${G5K_SSH_KEY}" "${CONFIG_JSON}" "${G5K_USER}@${G5K_HOST}:${TMP_JSON}"
	scp -o BatchMode=yes -o StrictHostKeyChecking=accept-new -i "${G5K_SSH_KEY}" "${ROOT_DIR}/bin/project-preparation/node-setup/write-env.sh" "${G5K_USER}@${G5K_HOST}:${TMP_WRITE_ENV}"
fi
run_ssh "bash '${TMP_WRITE_ENV}' --json-file '${TMP_JSON}' ${DRY_RUN:+--dry-run}"

echo "[INFO] Installing dependencies on remote (type=${OS_TYPE}, file=${PKG_FILE})"
TMP_PKGS="/tmp/exp_pkgs_$$.txt"
TMP_INSTALL="/tmp/install-deps_$$.sh"
if [[ ${DRY_RUN} == true ]]; then
	echo "[DRY-RUN] upload packages file to remote: ${PKG_FILE} -> ${TMP_PKGS}"
	echo "[DRY-RUN] upload install-dependencies.sh to remote: ${TMP_INSTALL}"
else
	scp -o BatchMode=yes -o StrictHostKeyChecking=accept-new -i "${G5K_SSH_KEY}" "${PKG_FILE}" "${G5K_USER}@${G5K_HOST}:${TMP_PKGS}"
	scp -o BatchMode=yes -o StrictHostKeyChecking=accept-new -i "${G5K_SSH_KEY}" "${ROOT_DIR}/bin/project-preparation/node-setup/install-dependencies.sh" "${G5K_USER}@${G5K_HOST}:${TMP_INSTALL}"
fi
run_ssh "bash '${TMP_INSTALL}' --os-type '${OS_TYPE}' --packages-file '${TMP_PKGS}' ${DRY_RUN:+--dry-run}"

echo "[INFO] Remote preparation complete."
