#!/usr/bin/env bash
# Runs on node. Creates structure, persists env vars, installs libs based on OS type
set -euo pipefail
IFS=$'\n\t'

BASE_DIR="/root/experiments_node"
CONFIG_JSON="${BASE_DIR}/config.json"
PARAMS_FILE="${BASE_DIR}/params.txt"
OS_TYPE_FILE="${BASE_DIR}/os_type.txt"
LOGS_DIR="${BASE_DIR}/on-machine/logs"
ENV_FILE="${BASE_DIR}/on-machine/.env"

mkdir -p "${LOGS_DIR}"

log() {
	local ts
	ts=$(date +"%H:%M:%S")
	echo "[${ts}] $*" | tee -a "${LOGS_DIR}/prepare_on_machine.log"
}
err() { echo "ERROR: $*" | tee -a "${LOGS_DIR}/prepare_on_machine.log" >&2; }

die() {
	err "$*"
	exit 1
}

require_cmd() { command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"; }

# Ensure jq exists (install if missing)
ensure_jq() {
	if command -v jq >/dev/null 2>&1; then
		return 0
	fi
	log "jq not found; attempting to install..."
	# Try package manager detection first
	if command -v apt-get >/dev/null 2>&1; then
		bash -lc 'DEBIAN_FRONTEND=noninteractive apt-get update -y && apt-get install -y jq' || true
	elif command -v dnf >/dev/null 2>&1; then
		bash -lc 'dnf makecache && dnf install -y jq' || true
	elif command -v yum >/dev/null 2>&1; then
		bash -lc 'yum makecache fast && yum install -y jq' || true
	else
		log "No known package manager detected; will try OS_TYPE fallback if available."
		# Fall back to OS_TYPE-based installer below
	fi
	if command -v jq >/dev/null 2>&1; then
		log "jq installation successful"
		return 0
	fi

	# Fallback to OS_TYPE if direct detection failed
	os_t="${OS_TYPE:-1}"
	case "${os_t}" in
		1)
			bash -lc 'DEBIAN_FRONTEND=noninteractive apt-get update -y && apt-get install -y jq' || true
			;;
		2)
			bash -lc 'yum makecache fast && yum install -y jq' || true
			;;
		3)
			bash -lc 'dnf makecache && dnf install -y jq' || true
			;;
		*)
			log "Unknown OS_TYPE=${os_t}; cannot auto-install jq via fallback."
			;;
	esac
	if ! command -v jq >/dev/null 2>&1; then
		die "Missing required command: jq (auto-install failed). Please include jq in the image or provide it via machine_setup.list_of_needed_libraries."
	fi
}

[[ -f ${CONFIG_JSON} ]] || die "Missing ${CONFIG_JSON}"
[[ -f ${PARAMS_FILE} ]] || die "Missing ${PARAMS_FILE}"

OS_TYPE=1
if [[ -f ${OS_TYPE_FILE} ]]; then
	OS_TYPE=$(cat "${OS_TYPE_FILE}")
fi

# Ensure jq is available before using it
ensure_jq

# Persist env vars
log "Persisting environment variables to ${ENV_FILE}"
: >"${ENV_FILE}"
count=$(jq '.machine_setup.env_variables_list | length' "${CONFIG_JSON}")
for ((i = 0; i < count; i++)); do
	# each item is an object with a single key
	key=$(jq -r ".machine_setup.env_variables_list[${i}] | keys[0]" "${CONFIG_JSON}")
	val=$(jq -r ".machine_setup.env_variables_list[${i}][\"${key}\"]" "${CONFIG_JSON}")
	echo "export ${key}='${val}'" >>"${ENV_FILE}"
	export "${key}=${val}"
	log "Set ${key}"
done

# Optionally install libraries if provided under machine_setup.list_of_needed_libraries
LIST_FILE=$(jq -r '.machine_setup.list_of_needed_libraries // empty' "${CONFIG_JSON}")
if [[ -n ${LIST_FILE} && -f ${LIST_FILE} ]]; then
	log "Installing libraries from ${LIST_FILE} (OS_TYPE=${OS_TYPE})"
	case "${OS_TYPE}" in
		1)
			PKG_CMD="apt-get update && xargs -a ${LIST_FILE} -r apt-get install -y"
			;;
		2)
			PKG_CMD="yum makecache fast && xargs -a ${LIST_FILE} -r yum install -y"
			;;
		3)
			PKG_CMD="dnf makecache && xargs -a ${LIST_FILE} -r dnf install -y"
			;;
		*)
			die "Unknown os_distribution_type: ${OS_TYPE}"
			;;
	esac
	bash -lc "${PKG_CMD}" || die "Package installation failed"
else
	log "No libraries list provided or file not found; skipping package installation"
fi

log "prepare_on_machine completed"
