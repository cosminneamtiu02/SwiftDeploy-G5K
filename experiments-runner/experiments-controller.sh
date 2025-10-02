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

# FE-side tracking (done.txt) variables
SELECTED_BATCH=""

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
require_cmd base64

# --- Read JSON helpers ---
jq_get() { jq -r "$1" "${CONFIG_PATH}"; }

IMAGE_YAML_NAME=$(jq_get '.machine_setup.image_to_use // empty')
IS_MANUAL=$(jq_get '.machine_setup.is_machine_instantiator_manual // true')
OS_DIST_TYPE=$(jq_get '.machine_setup.os_distribution_type // 1')

PAR_PATH=$(jq_get '.running_experiments.on_fe.to_do_parameters_list_path // empty')
EXEC_CMD=$(jq_get '.running_experiments.on_machine.execute_command // empty')
EXEC_DIR=$(jq_get '.running_experiments.on_machine.full_path_to_executable // empty')
PARALLEL_N=$(jq_get '.running_experiments.number_of_experiments_to_run_in_parallel_on_machine // 1')

COLLECT_FE_DIR=$(jq_get '.running_experiments.experiments_collection.path_to_save_experiment_results_on_fe // empty')
COLLECT_MACHINE_DIR=$(jq_get '.running_experiments.experiments_collection.path_to_saved_experiment_results_on_machine // empty')

[[ -n ${IMAGE_YAML_NAME} ]] || die "Config error: .machine_setup.image_to_use is missing or empty"
[[ -n ${PAR_PATH} ]] || die "Config error: .running_experiments.on_fe.to_do_parameters_list_path is missing or empty"
[[ -n ${EXEC_CMD} ]] || die "Config error: .running_experiments.on_machine.execute_command is missing or empty"
[[ -n ${EXEC_DIR} ]] || die "Config error: .running_experiments.on_machine.full_path_to_executable is missing or empty"
[[ ${PARALLEL_N} =~ ^[0-9]+$ ]] || die "Config error: .running_experiments.number_of_experiments_to_run_in_parallel_on_machine must be an integer"

# --- Phase 0: FE-side selection using done.txt (before any machine work) ---
# Resolve params file on FE
resolve_params_file_fe() {
	local p="$1"
	if [[ -z ${p} ]]; then
		return 1
	fi
	if [[ ${p} == /* ]]; then
		printf '%s\n' "${p}"
	else
		printf '%s\n' "${RUNNER_ROOT}/params/${p}"
	fi
}

PAR_FILE_FE=$(resolve_params_file_fe "${PAR_PATH}")
[[ -f ${PAR_FILE_FE} ]] || die "Parameters list not found on FE: ${PAR_FILE_FE}"

# Determine done.txt path next to the params file
PAR_DIR_FE=$(dirname "${PAR_FILE_FE}")
DONE_FILE_FE="${PAR_DIR_FE}/done.txt"

# Read TODO lines (preserve order, ignore blanks)
mapfile -t FE_TODO_LINES < <(grep -v '^[[:space:]]*$' "${PAR_FILE_FE}" || true)

# Ensure done.txt exists (Case 1)
if [[ ! -f ${DONE_FILE_FE} ]]; then
	: >"${DONE_FILE_FE}"
fi
mapfile -t FE_DONE_LINES < <(grep -v '^[[:space:]]*$' "${DONE_FILE_FE}" || true)

# Build a quick membership map for done lines
declare -A FE_DONE_SET=()
for dl in "${FE_DONE_LINES[@]}"; do FE_DONE_SET["${dl}"]=1; done

# Select up to PARALLEL_N lines from TODO not in done.txt
FE_SELECTED_LINES=()
for tl in "${FE_TODO_LINES[@]}"; do
	if [[ -z ${FE_DONE_SET["${tl}"]+x} ]]; then
		FE_SELECTED_LINES+=("${tl}")
		if ((${#FE_SELECTED_LINES[@]} >= PARALLEL_N)); then
			break
		fi
	fi
done

if ((${#FE_SELECTED_LINES[@]} == 0)); then
	log_warn "Nothing left to run. Cleaning up done.txt and stopping."
	rm -f "${DONE_FILE_FE}" 2>/dev/null || true
	log_success "Stopped before execution: no pending parameters."
	exit 0
fi

# Display selected lines at the very beginning (before deploy)
log_step "Selected parameters for this run (n=${#FE_SELECTED_LINES[@]}):"
for sl in "${FE_SELECTED_LINES[@]}"; do
	ts=$(date +%H:%M:%S)
	echo "[${ts}] [INFO]  [FE] ${sl}"
done

# Snapshot done.txt BEFORE appending, so we can restore exact pre-run state on failure
BATCH_DONE_BACKUP="${DONE_FILE_FE}.bak.$(date +%s).$$"
cp -f "${DONE_FILE_FE}" "${BATCH_DONE_BACKUP}" 2>/dev/null || true

# Immediately append selected lines to done.txt
{
	for sl in "${FE_SELECTED_LINES[@]}"; do printf '%s\n' "${sl}"; done
} >>"${DONE_FILE_FE}"

# Prepare in-memory text and base64 for env export and for potential revert
SELECTED_BATCH_TEXT=$(printf '%s\n' "${FE_SELECTED_LINES[@]}")
export SELECTED_BATCH="${SELECTED_BATCH_TEXT}"
SELECTED_LINES_B64=$(printf '%s\n' "${FE_SELECTED_LINES[@]}" | base64 -w0)
FE_BATCH_OK=0

revert_done_batch() {
	# Prefer exact restore from snapshot if available
	if [[ -f ${BATCH_DONE_BACKUP} ]]; then
		mv -f "${BATCH_DONE_BACKUP}" "${DONE_FILE_FE}" 2>/dev/null || true
		log_info "Restored ${DONE_FILE_FE} from snapshot."
		return 0
	fi
	# Fallback: remove one occurrence of each selected line
	[[ -f ${DONE_FILE_FE} ]] || return 0
	local tmp tmp_sel
	tmp="${DONE_FILE_FE}.tmp.$$"
	tmp_sel=$(mktemp "${DONE_FILE_FE}.sel.XXXXXX")
	for __l in "${FE_SELECTED_LINES[@]}"; do printf '%s\n' "${__l}"; done >"${tmp_sel}"
	awk 'BEGIN{ while((getline line<ARGV[2])>0){c[line]++} close(ARGV[2]) } { if(c[$0]>0){ c[$0]--; next } print }' \
		"${DONE_FILE_FE}" "${tmp_sel}" >"${tmp}" || true
	mv "${tmp}" "${DONE_FILE_FE}" 2>/dev/null || true
	rm -f "${tmp_sel}" 2>/dev/null || true
}

# Arrange revert on any failure before successful completion
FE_BATCH_OK=0
__cleanup_fe_batch() {
	# Invoke after existing cleanup
	if [[ ${FE_BATCH_OK} -ne 1 ]]; then
		log_warn "Reverting FE done.txt entries for this batch due to failure/interruption."
		revert_done_batch
	else
		# Success: remove backup snapshot if present
		rm -f "${BATCH_DONE_BACKUP}" 2>/dev/null || true
	fi
}

# Chain cleanup: ensure our revert runs at EXIT, but only after controller-local cleanup
trap '__cleanup; __cleanup_fe_batch' EXIT

# Remove legacy duplicated FE selection logic below. The above block owns selection and revert.

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
		"bash -lc 'export SELECTED_PARAMS_B64=${SELECTED_LINES_B64:-}; ~/experiments_node/on-machine/prepare_on_machine.sh'"
else
	log "SSH not available. Please run on the node: ~/experiments_node/on-machine/prepare_on_machine.sh"
fi

# --- Phase 3: Delegate experiments ---
log_step "Phase 3/4: Delegating experiments on node"
if ssh -o StrictHostKeyChecking=no "root@${NODE_NAME}" 'echo ok' >/dev/null 2>&1; then
	log_info "Starting delegation and live log stream from ${NODE_NAME}"
	# Stream run_delegator.sh output directly; run_delegator already tees to its log.
	set +e
	set +o pipefail
	trap - ERR
	ssh -o StrictHostKeyChecking=no "root@${NODE_NAME}" bash -lc \
		"'export SELECTED_PARAMS_B64=${SELECTED_LINES_B64:-}; CONFIG_JSON=~/experiments_node/config.json; if command -v stdbuf >/dev/null 2>&1; then stdbuf -oL -eL ~/experiments_node/on-machine/run_delegator.sh; else ~/experiments_node/on-machine/run_delegator.sh; fi'" 2>&1 |
		while IFS= read -r line; do
			ts=$(date +%H:%M:%S)
			printf '[%s] [INFO]  [%s] %s\n' "${ts}" "${NODE_NAME}" "${line}" 2>/dev/null || true
		done
	deleg_rc=${PIPESTATUS[0]}
	trap __on_err ERR
	set -o pipefail
	set -e

	if [[ ${deleg_rc:-0} -ne 0 ]]; then
		log_warn "Delegator failed (rc=${deleg_rc}). Exiting and reverting selection."
		exit "${deleg_rc}"
	fi
	FE_BATCH_OK=1
else
	log "SSH not available. Please run on the node: CONFIG_JSON=~/experiments_node/config.json ~/experiments_node/on-machine/run_delegator.sh"
fi

# --- Phase 4: Transfer results (.txt files) from node to FE ---
log_step "Phase 4/4: Transferring .txt result files from node to FE"

# We copy each individual .txt file from the configured node results directory
# to the configured FE collected directory. No concatenation.
if [[ -n ${COLLECT_FE_DIR} && -n ${COLLECT_MACHINE_DIR} ]]; then
	# Resolve FE target dir (under experiments-runner/collected unless absolute)
	if [[ ${COLLECT_FE_DIR} == /* ]]; then
		FE_TARGET_DIR="${COLLECT_FE_DIR}"
	else
		FE_TARGET_DIR="${RUNNER_ROOT}/collected/${COLLECT_FE_DIR}"
	fi
	mkdir -p "${FE_TARGET_DIR}"

	# List .txt files on node within the specified directory (non-recursive)
	REMOTE_DIR_NO_TRAIL="${COLLECT_MACHINE_DIR%/}"
	# Use find for robust matching even if no files exist
	mapfile -t REMOTE_TXT_FILES < <(ssh -o StrictHostKeyChecking=no "root@${NODE_NAME}" \
		"bash -lc 'find \"${REMOTE_DIR_NO_TRAIL}\" -maxdepth 1 -type f -name \"*.txt\" -print 2>/dev/null'" || true)

	if ((${#REMOTE_TXT_FILES[@]} == 0)); then
		log_warn "No .txt result files found on node at ${REMOTE_DIR_NO_TRAIL}."
	else
		log_info "Found ${#REMOTE_TXT_FILES[@]} .txt files on node; starting transfer to ${FE_TARGET_DIR}"
		copied=0
		for rf in "${REMOTE_TXT_FILES[@]}"; do
			# Copy one file at a time, preserving filename into FE_TARGET_DIR
			if scp -o StrictHostKeyChecking=no "root@${NODE_NAME}:${rf}" "${FE_TARGET_DIR}/" | tee -a "${LOG_DIR}/collector_pull.log"; then
				((copied++)) || true
			else
				log_warn "Failed to copy ${rf}"
			fi
		done
		log_success "Transferred ${copied}/${#REMOTE_TXT_FILES[@]} .txt files to ${FE_TARGET_DIR}"
	fi
else
	log_info "Result transfer skipped: missing paths. on-node='${COLLECT_MACHINE_DIR:-}' on-FE='${COLLECT_FE_DIR:-}'"
fi

log_success "All phases completed. Logs at: ${LOG_DIR}"

# Mark FE selection success so done.txt batch is retained
FE_BATCH_OK=1
