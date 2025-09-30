#!/usr/bin/env bash
# Prepare FE -> Node: create remote structure, upload config and scripts
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNNER_ROOT="$(cd "${SCRIPT_DIR}/../../../.." && pwd)"
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
remote_mkdir_via_ssh "${NODE_NAME}" "${REMOTE_ON_MACHINE_DIR}"
remote_mkdir_via_ssh "${NODE_NAME}" "${REMOTE_LOGS_DIR}"

# Upload config and params
log "Uploading config and params"
scp -o StrictHostKeyChecking=no "${CONFIG_PATH}" "root@${NODE_NAME}:${REMOTE_BASE}/config.json"
scp -o StrictHostKeyChecking=no "${PAR_FILE}" "root@${NODE_NAME}:${REMOTE_BASE}/params.txt"

# Upload on-machine scripts
log "Uploading on-machine scripts"
safe_scp_to_node "${RUNNER_ROOT}/bin/project-preparation/on-machine" "${NODE_NAME}" "${REMOTE_ON_MACHINE_DIR}"
safe_scp_to_node "${RUNNER_ROOT}/bin/experiments-delegator/on-machine" "${NODE_NAME}" "${REMOTE_ON_MACHINE_DIR}"
safe_scp_to_node "${RUNNER_ROOT}/bin/experiments-collector/on-machine" "${NODE_NAME}" "${REMOTE_ON_MACHINE_DIR}"

# Save OS type for on-machine logic
ssh -o StrictHostKeyChecking=no "root@${NODE_NAME}" "echo '${OS_TYPE}' > ${REMOTE_BASE}/os_type.txt"

log "Preparation on FE complete."

# Reference the logs directory for clarity and to mark it used
log "FE preparation logs directory (info): ${LOG_DIR}"
