#!/usr/bin/env bash
# Prepare FE -> Node: create remote structure, upload config and scripts
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# From on-fe -> project-preparation -> bin -> experiments-runner (3 levels up)
RUNNER_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
# shellcheck source=/dev/null
source "${RUNNER_ROOT}/bin/utils/common.sh"

NODE_NAME=""
CONFIG_PATH=""
OS_TYPE="1"
# shellcheck disable=SC2034 # LOG_DIR kept for future use / debugging
LOG_DIR="${RUNNER_ROOT}/logs" # reserved for future use (debugging)

while [[ $# -gt 0 ]]; do
	case "$1" in
		--node)
			NODE_NAME=$2
			shift 2
			;;
		--config)
			CONFIG_PATH=$2
			shift 2
			;;
		--os-type)
			OS_TYPE=$2
			shift 2
			;;
		--logs)
			LOG_DIR=$2
			shift 2
			;;
		*) die "Unknown arg: $1" ;;
	esac
done

[[ -n ${NODE_NAME} ]] || die "--node is required"
[[ -f ${CONFIG_PATH} ]] || die "Config file not found: ${CONFIG_PATH}"

require_cmd jq

# Parse config values
PAR_PATH=$(jq -r '.running_experiments.on_fe.to_do_parameters_list_path' "${CONFIG_PATH}")
PAR_FILE=$(resolve_params_path "${PAR_PATH}")
[[ -f ${PAR_FILE} ]] || die "Parameters list not found: ${PAR_FILE}"

# Remote structure
REMOTE_BASE="/root/experiments_node"
REMOTE_ON_MACHINE_DIR="${REMOTE_BASE}/on-machine"
REMOTE_LOGS_DIR="${REMOTE_BASE}/on-machine/logs"
# NOTE: remote delegator dir equals on-machine; kept for readability
# shellcheck disable=SC2034 # kept for readability even if not used directly
REMOTE_DELEGATOR_DIR="${REMOTE_BASE}/on-machine"

# Create base dirs
log "Creating remote directories on ${NODE_NAME}"
if ! remote_mkdir_via_ssh "${NODE_NAME}" "${REMOTE_ON_MACHINE_DIR}"; then
	log_warn "SSH not ready on ${NODE_NAME}. Skipping remote mkdir. After deploy is ready, rerun controller or run this step manually."
fi
if ! remote_mkdir_via_ssh "${NODE_NAME}" "${REMOTE_LOGS_DIR}"; then
	log_warn "SSH not ready on ${NODE_NAME}. Skipping remote logs mkdir."
fi

# Upload config and params
log "Uploading config and params"
if ssh -o BatchMode=yes -o StrictHostKeyChecking=no "root@${NODE_NAME}" 'echo ok' >/dev/null 2>&1; then
	scp -o StrictHostKeyChecking=no "${CONFIG_PATH}" "root@${NODE_NAME}:${REMOTE_BASE}/config.json"
	scp -o StrictHostKeyChecking=no "${PAR_FILE}" "root@${NODE_NAME}:${REMOTE_BASE}/params.txt"
else
	log_warn "SSH not ready on ${NODE_NAME}. Skipping upload."
fi

# Upload on-machine scripts
log "Uploading on-machine scripts"
if ssh -o BatchMode=yes -o StrictHostKeyChecking=no "root@${NODE_NAME}" 'echo ok' >/dev/null 2>&1; then
	# copy the contents of each local on-machine folder into the single remote on-machine folder
	scp -o StrictHostKeyChecking=no -r "${RUNNER_ROOT}/bin/project-preparation/on-machine/." "root@${NODE_NAME}:${REMOTE_ON_MACHINE_DIR}/"
	scp -o StrictHostKeyChecking=no -r "${RUNNER_ROOT}/bin/experiments-delegator/on-machine/." "root@${NODE_NAME}:${REMOTE_ON_MACHINE_DIR}/"
	scp -o StrictHostKeyChecking=no -r "${RUNNER_ROOT}/bin/experiments-collector/on-machine/." "root@${NODE_NAME}:${REMOTE_ON_MACHINE_DIR}/"
else
	log_warn "SSH not ready on ${NODE_NAME}. Skipping script upload."
fi

# Save OS type for on-machine logic
if ssh -o BatchMode=yes -o StrictHostKeyChecking=no "root@${NODE_NAME}" 'echo ok' >/dev/null 2>&1; then
	ssh -o StrictHostKeyChecking=no "root@${NODE_NAME}" "echo '${OS_TYPE}' > ${REMOTE_BASE}/os_type.txt"
else
	log_warn "SSH not ready on ${NODE_NAME}. Skipping OS type save."
fi

log "Preparation on FE complete."

# Reference the logs directory for clarity and to mark it used
log "FE preparation logs directory (info): ${LOG_DIR}"
