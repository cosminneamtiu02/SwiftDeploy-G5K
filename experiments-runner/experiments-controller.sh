#!/usr/bin/env bash
# Orchestrates: machine instantiation -> project preparation -> delegate runs -> collect
# Usage: experiments-controller.sh --config <config_name.json> [--verbose]
set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
RUNNER_ROOT="${REPO_ROOT}/experiments-runner"
BIN_DIR="${RUNNER_ROOT}/bin"
LOGS_DIR_BASE="${RUNNER_ROOT}/logs"
CONFIGS_DIR_PRIMARY="${RUNNER_ROOT}/experiments-configurations"
CONFIGS_DIR_IMPL="${CONFIGS_DIR_PRIMARY}/implementations"
CURRENT_NODE_FILE="${RUNNER_ROOT}/current_node.txt"
ALT_NODE_FILE="${REPO_ROOT}/current_node.txt"
REMOTE_BASE_DIR="/root/experiments_node"
REMOTE_LOGS_DIR="${REMOTE_BASE_DIR}/on-machine/logs"

# --- CLI args ---
CONFIG_NAME=""
VERBOSE=false

while [[ $# -gt 0 ]]; do
	case "$1" in
		--config)
			CONFIG_NAME=${2:-}
			shift 2
			;;
		--verbose | -v)
			VERBOSE=true
			shift
			;;
		*)
			echo "Unknown argument: $1" >&2
			echo "Usage: $0 --config <config.json> [--verbose]" >&2
			exit 1
			;;
	esac
done

if [[ -z ${CONFIG_NAME} ]]; then
	echo "ERROR: --config <config.json> is required" >&2
	exit 1
fi

CONFIG_PATH=""
for base in "${CONFIGS_DIR_PRIMARY}" "${CONFIGS_DIR_IMPL}"; do
	if [[ -f "${base}/${CONFIG_NAME}" ]]; then
		CONFIG_PATH="${base}/${CONFIG_NAME}"
		break
	fi
done

if [[ -z ${CONFIG_PATH} ]]; then
	echo "ERROR: Config ${CONFIG_NAME} not found in: ${CONFIGS_DIR_PRIMARY} or ${CONFIGS_DIR_IMPL}" >&2
	exit 1
fi

# --- Logging ---
timestamp() { date +"%Y-%m-%d_%H-%M-%S"; }
LOG_DIR="${LOGS_DIR_BASE}/$(timestamp)"
mkdir -p "${LOG_DIR}"

# shellcheck source=/dev/null
LOG_FILE="${LOG_DIR}/controller.log"
export LOG_FILE
# shellcheck disable=SC1091
source "${RUNNER_ROOT}/bin/utils/liblog.sh"
log_info "Controller started. Logs: ${LOG_FILE}"

# Backward-compat: if plain 'log' isn't defined by the logging lib, map it to info
if ! declare -F log >/dev/null 2>&1; then
	log() { log_info "$@"; }
fi

require_cmd() { command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"; }

# --- Optional verbose mode (debug-level logs, no shell tracing noise) ---
if ${VERBOSE}; then
	export LOG_LEVEL=debug
fi

# --- Error trap for clearer failures ---
__on_err() {
	local exit_code=$?
	local line_no=${BASH_LINENO[0]:-?}
	local src_file=${BASH_SOURCE[1]:-$(basename "$0")}
	local last_cmd=${BASH_COMMAND:-unknown}
	log_error "Failure (exit=${exit_code}) at ${src_file}:${line_no} while running: ${last_cmd}"
	log_error "See ${LOG_FILE} for details."
}
trap __on_err ERR

# Ensure background streams are cleaned up on exit
__cleanup() {
	if [[ -n ${STREAM_PID:-} ]]; then
		kill "${STREAM_PID}" >/dev/null 2>&1 || true
		wait "${STREAM_PID}" >/dev/null 2>&1 || true
	fi
}
trap __cleanup EXIT

# --- Dependencies ---
require_cmd jq

# --- Read JSON helpers ---
jq_get() { jq -r "$1" "${CONFIG_PATH}"; }

IMAGE_YAML_NAME=$(jq_get '.machine_setup.image_to_use // empty')
IS_MANUAL=$(jq_get '.machine_setup.is_machine_instantiator_manual // true')
OS_DIST_TYPE=$(jq_get '.machine_setup.os_distribution_type // 1')

PAR_PATH=$(jq_get '.running_experiments.on_fe.to_do_parameters_list_path // empty')
EXEC_CMD=$(jq_get '.running_experiments.on_machine.execute_command // empty')
EXEC_DIR=$(jq_get '.running_experiments.on_machine.full_path_to_executable // empty')
PARALLEL_N=$(jq_get '.running_experiments.number_of_experiments_to_run_in_parallel_on_machine // 1')

COLLECT_STRAT=$(jq_get '.running_experiments.experiments_collection.collection_strategy // empty')
COLLECT_FE_DIR=$(jq_get '.running_experiments.experiments_collection.path_to_save_experiment_results_on_fe // empty')
# shellcheck disable=SC2034 # retained for future use / debugging
COLLECT_MACHINE_DIR=$(jq_get '.running_experiments.experiments_collection.path_to_saved_experiment_results_on_machine // empty')

[[ -n ${IMAGE_YAML_NAME} ]] || die "Config error: .machine_setup.image_to_use is missing or empty"
[[ -n ${PAR_PATH} ]] || die "Config error: .running_experiments.on_fe.to_do_parameters_list_path is missing or empty"
[[ -n ${EXEC_CMD} ]] || die "Config error: .running_experiments.on_machine.execute_command is missing or empty"
[[ -n ${EXEC_DIR} ]] || die "Config error: .running_experiments.on_machine.full_path_to_executable is missing or empty"
[[ ${PARALLEL_N} =~ ^[0-9]+$ ]] || die "Config error: .running_experiments.number_of_experiments_to_run_in_parallel_on_machine must be an integer"

# --- Phase 1: Machine instantiation (on FE) ---
log_step "Phase 1/4: Machine instantiation (${IS_MANUAL:+manual})"
INST_DIR="${BIN_DIR}/machine-instantiator/on-fe"
[[ -d ${INST_DIR} ]] || die "Missing directory: ${INST_DIR}"

if [[ ${IS_MANUAL} == "true" ]]; then
	"${INST_DIR}/manual_instantiator.sh" "${IMAGE_YAML_NAME}" | tee -a "${LOG_DIR}/instantiator.log"
else
	# automatic currently not implemented by design
	if ! "${INST_DIR}/automatic_instantiator.sh" "${IMAGE_YAML_NAME}" | tee -a "${LOG_DIR}/instantiator.log"; then
		die "Automatic instantiation not implemented"
	fi
fi

# Fallback: accept legacy path at repo root if present
if [[ ! -f ${CURRENT_NODE_FILE} ]]; then
	if [[ -f ${ALT_NODE_FILE} ]]; then
		CURRENT_NODE_FILE=${ALT_NODE_FILE}
	else
		die "Node name file not found: ${CURRENT_NODE_FILE}. Ensure Phase 1 saved the node hostname."
	fi
fi
NODE_NAME=$(<"${CURRENT_NODE_FILE}")
[[ -n ${NODE_NAME} ]] || die "Empty node name read from ${CURRENT_NODE_FILE}"
log "Target node: ${NODE_NAME}"

# --- Phase 2: Project preparation ---
log "Phase 2/4: Project preparation (FE copies + node setup)"

# Ensure node is deployed and SSH is available; deploy if necessary
wait_for_ssh() {
	local host="$1"
	local timeout="${2:-600}"
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
		log_warn "SSH not ready on ${NODE_NAME}. Deploying image via kadeploy3..."
		if ! kadeploy3 -a "${HOME}/envs/img-files/${IMAGE_YAML_NAME}" -m "${NODE_NAME}" | tee -a "${LOG_DIR}/kadeploy.log"; then
			die "kadeploy3 failed for ${NODE_NAME}. Check ${LOG_DIR}/kadeploy.log"
		fi
		log_info "Waiting for SSH to come up on ${NODE_NAME}..."
		set +e
		wait_for_ssh "${NODE_NAME}" 900
		wst=$?
		set -e
		if [[ ${wst} -ne 0 ]]; then
			die "Timed out waiting for SSH on ${NODE_NAME} (waited 900s). Verify deployment succeeded."
		fi
		log_success "SSH is now available on ${NODE_NAME}."
	else
		log_warn "kadeploy3 not available; deploy manually: kadeploy3 -a ${HOME}/envs/img-files/${IMAGE_YAML_NAME} -m ${NODE_NAME}"
	fi
fi
PREP_FE_DIR="${BIN_DIR}/project-preparation/on-fe"
"${PREP_FE_DIR}/prepare_on_fe.sh" \
	--node "${NODE_NAME}" \
	--config "${CONFIG_PATH}" \
	--os-type "${OS_DIST_TYPE}" \
	--logs "${LOG_DIR}"

# Attempt to run prepare on node (will fallback to manual if ssh not available)
if ssh -o BatchMode=yes -o StrictHostKeyChecking=no "root@${NODE_NAME}" 'echo ok' >/dev/null 2>&1; then
	log "Running on-node preparation script remotely"
	LOG_FILE="${LOG_DIR}/prepare_on_machine.log" ssh -o StrictHostKeyChecking=no "root@${NODE_NAME}" \
		"bash -lc '~/experiments_node/on-machine/prepare_on_machine.sh'"
else
	log "SSH not available. Please run on the node: ~/experiments_node/on-machine/prepare_on_machine.sh"
fi

# --- Phase 3: Delegate experiments ---
log_step "Phase 3/4: Delegating experiments on node"
DELEG_CMD="bash -lc 'CONFIG_JSON=~/experiments_node/config.json ~/experiments_node/on-machine/run_delegator.sh'"
if ssh -o StrictHostKeyChecking=no "root@${NODE_NAME}" 'echo ok' >/dev/null 2>&1; then
	# Start streaming remote logs to FE console
	if command -v stdbuf >/dev/null 2>&1; then
		log_info "Starting remote log stream from ${NODE_NAME} (${REMOTE_LOGS_DIR})"
		ssh -o StrictHostKeyChecking=no "root@${NODE_NAME}" \
			"bash -lc 'mkdir -p ${REMOTE_LOGS_DIR}; touch ${REMOTE_LOGS_DIR}/delegator.log ${REMOTE_LOGS_DIR}/collector.log; stdbuf -oL -eL tail -n +1 -F ${REMOTE_LOGS_DIR}/delegator.log ${REMOTE_LOGS_DIR}/collector.log ${REMOTE_LOGS_DIR}/*.out 2>/dev/null'" |
			while IFS= read -r line; do log_info "[${NODE_NAME}] ${line}"; done &
		STREAM_PID=$!
	else
		log_warn "stdbuf not available on FE; log streaming may be buffered."
		ssh -o StrictHostKeyChecking=no "root@${NODE_NAME}" \
			"bash -lc 'mkdir -p ${REMOTE_LOGS_DIR}; touch ${REMOTE_LOGS_DIR}/delegator.log ${REMOTE_LOGS_DIR}/collector.log; tail -n +1 -F ${REMOTE_LOGS_DIR}/delegator.log ${REMOTE_LOGS_DIR}/collector.log ${REMOTE_LOGS_DIR}/*.out 2>/dev/null'" |
			while IFS= read -r line; do log_info "[${NODE_NAME}] ${line}"; done &
		STREAM_PID=$!
	fi

	# Run delegator synchronously; its stdout will also appear locally
	LOG_FILE="${LOG_DIR}/delegator.log" ssh -o StrictHostKeyChecking=no "root@${NODE_NAME}" "${DELEG_CMD}"

	# Stop streaming once delegator completes
	if [[ -n ${STREAM_PID:-} ]]; then
		kill "${STREAM_PID}" >/dev/null 2>&1 || true
		wait "${STREAM_PID}" >/dev/null 2>&1 || true
		unset STREAM_PID
		log_info "Stopped remote log stream from ${NODE_NAME}"
	fi
else
	log "SSH not available. Please run on the node: CONFIG_JSON=~/experiments_node/config.json ~/experiments_node/on-machine/run_delegator.sh"
fi

# --- Phase 4: Collect (strategy executed on node as part of delegator). Pull results ---
log_step "Phase 4/4: Collection phase handled by delegator (strategy: ${COLLECT_STRAT:-none})"

if [[ -n ${COLLECT_STRAT} && -n ${COLLECT_FE_DIR} ]]; then
	COMBINED_ON_NODE="/root/experiments_node/on-machine/combined_results.txt"
	# Resolve FE target dir (under experiments-runner/collected unless absolute)
	if [[ ${COLLECT_FE_DIR} == /* ]]; then
		FE_TARGET_DIR="${COLLECT_FE_DIR}"
	else
		FE_TARGET_DIR="${RUNNER_ROOT}/collected/${COLLECT_FE_DIR}"
	fi
	mkdir -p "${FE_TARGET_DIR}"
	if ssh -o StrictHostKeyChecking=no "root@${NODE_NAME}" "test -f '${COMBINED_ON_NODE}'"; then
		log_info "Pulling combined results from node"
		scp -o StrictHostKeyChecking=no "root@${NODE_NAME}:${COMBINED_ON_NODE}" "${FE_TARGET_DIR}/combined_results.txt" | tee -a "${LOG_DIR}/collector_pull.log" || true
		log_success "Combined results saved at: ${FE_TARGET_DIR}/combined_results.txt"
	else
		log_warn "No combined results found on node at ${COMBINED_ON_NODE} (collector may be disabled)."
	fi
fi

log_success "All phases completed. Logs at: ${LOG_DIR}"
