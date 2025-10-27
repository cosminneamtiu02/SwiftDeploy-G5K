#!/usr/bin/env bash
# shellcheck shell=bash
# shellcheck source-path=../../../../common
# Manual machine instantiation with auto-detection of allocated node
# - Verifies YAML exists under ~/envs/img-files
# - Tries to detect node from OAR nodefile or oarstat
# - Falls back to prompting the user only if detection fails
set -Eeuo pipefail
IFS=$'\n\t'

YAML_NAME=${1:-}
if [[ -z ${YAML_NAME} ]]; then
	echo "Usage: $0 <image_yaml_filename>" >&2
	exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMON_ENV="$(cd "${SCRIPT_DIR}/../../../../common" && pwd)/environment.sh"
if [[ ! -f ${COMMON_ENV} ]]; then
	COMMON_ENV="experiments-runner/runtime/common/environment.sh"
fi
# shellcheck source=experiments-runner/runtime/common/environment.sh
source "${COMMON_ENV}"
runner_env::bootstrap

CURRENT_NODE_FILE="${RUNNER_ROOT}/current_node.txt"
YAML_DIR="${HOME}/envs/img-files"
YAML_PATH="${YAML_DIR}/${YAML_NAME}"

if [[ ! -f ${YAML_PATH} ]]; then
	log_error "YAML not found at ${YAML_PATH}"
	log_error "Hint: env-creator stores YAMLs under ~/envs/img-files and tars under ~/envs/img"
	exit 1
fi

log_info "Manual instantiation selected."
log_info "Ensure an interactive deploy session exists: oarsub -I -t deploy -q default (run in another terminal)."
log_info "Will deploy image automatically if needed: kadeploy3 -a ${YAML_PATH} -m <node>"

__on_err() {
	local exit_code=$?
	local line_no=${BASH_LINENO[0]:-?}
	local src_file=${BASH_SOURCE[1]:-$(basename "$0")}
	local last_cmd=${BASH_COMMAND:-unknown}
	log_error "Instantiator failed (exit=${exit_code}) at ${src_file}:${line_no} while running: ${last_cmd}"
}
trap __on_err ERR

detect_from_oar_env() {
	# Try common OAR nodefile env vars
	for var in OAR_NODEFILE OAR_NODE_FILE OAR_FILE_NODES; do
		if [[ -n ${!var-} && -f ${!var} ]]; then
			head -n1 "${!var}" | awk '{print $1}'
			return 0
		fi
	done
	return 1
}

detect_from_oarstat() {
	if ! command -v oarstat >/dev/null 2>&1; then
		return 1
	fi
	local last_id
	last_id=$(oarstat -u | awk '/^[0-9]+/ {print $1}' | tail -n1 || true)
	if [[ -z ${last_id} ]]; then
		return 1
	fi
	local line
	line=$(oarstat -j "${last_id}" -f | awk -F': ' '/^assigned_hostnames/ {print $2}')
	# sanitize: remove brackets, quotes, commas, then take first hostname
	echo "${line}" | tr -d '[],' | tr -d "'\"" | awk '{print $1}'
}

NODE_NAME=""
tmp=""

# Try detect from OAR env file without disabling 'set -e' for the whole script
set +e
tmp=$(detect_from_oar_env)
status=$?
set -e
if [[ ${status} -eq 0 && -n ${tmp} ]]; then
	NODE_NAME=${tmp}
	log_info "Auto-detected node from OAR env file: ${NODE_NAME}"
else
	set +e
	tmp=$(detect_from_oarstat)
	status=$?
	set -e
	if [[ ${status} -eq 0 && -n ${tmp} ]]; then
		NODE_NAME=${tmp}
		log_info "Auto-detected node via oarstat: ${NODE_NAME}"
	fi
fi

if [[ -z ${NODE_NAME} ]]; then
	read -r -p "Enter the allocated node hostname (e.g., parasilo-XX.nancy.grid5000.fr): " NODE_NAME
	if [[ -z ${NODE_NAME} ]]; then
		log_error "No node name provided. Aborting."
		exit 1
	fi
fi

printf '%s\n' "${NODE_NAME}" >"${CURRENT_NODE_FILE}"
chmod 600 "${CURRENT_NODE_FILE}"
log_info "Saved node to ${CURRENT_NODE_FILE}: ${NODE_NAME}"

# Deploy the image to the allocated node if SSH isn't ready yet
wait_for_ssh() {
	local host="$1"
	local timeout="${2:-300}"
	local start end
	start=$(date +%s)
	while true; do
		if ssh -o BatchMode=yes -o StrictHostKeyChecking=no "root@${host}" 'echo ok' >/dev/null 2>&1; then
			return 0
		fi
		end=$(date +%s)
		if ((end - start > timeout)); then
			return 1
		fi
		sleep 3
	done
}

if ! ssh -o BatchMode=yes -o StrictHostKeyChecking=no "root@${NODE_NAME}" 'echo ok' >/dev/null 2>&1; then
	if command -v kadeploy3 >/dev/null 2>&1; then
		log_warn "SSH on ${NODE_NAME} not ready. Deploying image via kadeploy3..."
		# Prefer targeting the specific node to avoid ambiguity
		if ! kadeploy3 -a "${YAML_PATH}" -m "${NODE_NAME}"; then
			log_error "kadeploy3 failed on ${NODE_NAME}"
			exit 1
		fi
		log_info "Waiting for SSH to become available on ${NODE_NAME}..."
		set +e
		wait_for_ssh "${NODE_NAME}" 600
		wst=$?
		set -e
		if [[ ${wst} -ne 0 ]]; then
			log_error "Timed out waiting for SSH on ${NODE_NAME}"
			exit 1
		fi
		log_success "SSH is now available on ${NODE_NAME}."
	else
		log_warn "kadeploy3 not found. Deploy manually: kadeploy3 -a ${YAML_PATH} -m ${NODE_NAME}"
	fi
fi
