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

# FE-side tracking (done.txt) variables
SELECTED_BATCH=""
BATCH_OK=0

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

# Immediately append selected lines to done.txt
{
	for sl in "${FE_SELECTED_LINES[@]}"; do printf '%s\n' "${sl}"; done
} >>"${DONE_FILE_FE}"

# Prepare in-memory text for env export and for potential revert
SELECTED_BATCH_TEXT=$(printf '%s\n' "${FE_SELECTED_LINES[@]}")
export SELECTED_BATCH="${SELECTED_BATCH_TEXT}"

# Revert helper: remove exactly one occurrence of each selected line from done.txt
revert_done_batch() {
	# Protect against missing or empty selection
	[[ -f ${DONE_FILE_FE} ]] || return 0
	# Use process substitution to avoid writing any temp files to disk for the selection
	local tmp
	tmp="${DONE_FILE_FE}.tmp.$$"
	awk 'BEGIN{ while((getline line<ARGV[2])>0){c[line]++} close(ARGV[2]) } { if(c[$0]>0){ c[$0]--; next } print }' \
		"${DONE_FILE_FE}" /dev/fd/3 3<<'EOF_FE_SELECTED'
$(printf '%s
' "${FE_SELECTED_LINES[@]}")
EOF_FE_SELECTED
	mv "${tmp}" "${DONE_FILE_FE}" || true
}

# Arrange revert on any failure before successful completion
FE_BATCH_OK=0
__cleanup_fe_batch() {
	# Invoke after existing cleanup
	if [[ ${FE_BATCH_OK} -ne 1 ]]; then
		log_warn "Reverting FE done.txt entries for this batch due to failure/interruption."
		revert_done_batch
	fi
}

# Chain cleanup: ensure our revert runs at EXIT, but only after controller-local cleanup
trap '__cleanup; __cleanup_fe_batch' EXIT

# --- FE-side parameter selection using done.txt (before any deployment) ---
# Resolve params path on FE
resolve_fe_params_path() {
	local p="$1"
	if [[ -z ${p} ]]; then
		echo ""
		return
	fi
	if [[ ${p} == /* ]]; then
		echo "${p}"
	else
		echo "${RUNNER_ROOT}/params/${p}"
	fi
}

PAR_FILE_FE=$(resolve_fe_params_path "${PAR_PATH}")
[[ -f ${PAR_FILE_FE} ]] || die "Parameters list not found on FE: ${PAR_FILE_FE}"

# done.txt sits in the same folder as the params list
PAR_DIR_FE=$(dirname "${PAR_FILE_FE}")
DONE_FILE_FE="${PAR_DIR_FE}/done.txt"

# Ensure done.txt exists (Case 1)
if [[ ! -f ${DONE_FILE_FE} ]]; then
	log_info "Creating tracker file: ${DONE_FILE_FE}"
	: >"${DONE_FILE_FE}"
fi

# Compute remaining = runs.txt minus done.txt (multiset-aware)
mapfile -t _todo_lines < <(grep -v '^[[:space:]]*$' "${PAR_FILE_FE}" || true)
declare -A _done_counts=()
while IFS= read -r _dl; do
	[[ -n ${_dl} ]] || continue
	((_done_counts["${_dl}"]++)) || true
done < <(grep -v '^[[:space:]]*$' "${DONE_FILE_FE}" || true)

_remaining=()
for _ln in "${_todo_lines[@]}"; do
	if [[ ${_done_counts["${_ln}"]+set} == set && ${_done_counts["${_ln}"]} -gt 0 ]]; then
		((_done_counts["${_ln}"]--)) || true
	else
		_remaining+=("${_ln}")
	fi
done

if [[ ${#_remaining[@]} -eq 0 ]]; then
	log_info "Nothing left to run. Cleaning up tracker and exiting."
	rm -f "${DONE_FILE_FE}" || true
	exit 0
fi

# Take first N lines
_select_n=${PARALLEL_N}
SELECTED=()
for ((i = 0; i < ${#_remaining[@]} && i < _select_n; i++)); do
	SELECTED+=("${_remaining[${i}]}")
done

# Display selection before any deployment
log_step "Selected parameters for this run (count=${#SELECTED[@]}):"
for s in "${SELECTED[@]}"; do
	log_info "${s}"
done

# Append to done.txt immediately (Case 1 and Case 2)
{
	for s in "${SELECTED[@]}"; do
		printf '%s\n' "${s}"
	done
} >>"${DONE_FILE_FE}"

# Keep selection in memory for potential revert (no temp files)
SELECTED_BATCH=$(printf '%s\n' "${SELECTED[@]}")

# Revert function: remove exactly one occurrence of each selected line from done.txt
revert_done_selection() {
	[[ -n ${SELECTED_BATCH} && -f ${DONE_FILE_FE} ]] || return 0
	local tmpf="${DONE_FILE_FE}.tmp.$$"
	awk 'BEGIN{ while((getline line<ARGV[2])>0){c[line]++} close(ARGV[2]) } { if(c[$0]>0){ c[$0]--; next } print }' \
		"${DONE_FILE_FE}" <(printf '%s\n' "${SELECTED_BATCH}") >"${tmpf}" && mv "${tmpf}" "${DONE_FILE_FE}" || true
}

# Trap to revert on any failure in later phases (deploy/prepare/delegate/collect)
__revert_on_fail() {
	local code=$?
	if [[ ${BATCH_OK} -ne 1 ]]; then
		log_warn "Failure detected (exit=${code}). Reverting FE done.txt selection."
		revert_done_selection
	fi
}
trap __revert_on_fail ERR

# --- FE-side parameters selection and done.txt management (before any deployment) ---
FE_PARAMS_REL="${PAR_PATH}"
FE_PARAMS_PATH="${RUNNER_ROOT}/params/${FE_PARAMS_REL}"
FE_PARAMS_DIR="$(dirname "${FE_PARAMS_PATH}")"
FE_DONE_FILE="${FE_PARAMS_DIR}/done.txt"

[[ -f ${FE_PARAMS_PATH} ]] || die "Params file not found on FE: ${FE_PARAMS_PATH}"

# Create done.txt if missing (Case 1)
if [[ ! -f ${FE_DONE_FILE} ]]; then
	: >"${FE_DONE_FILE}"
fi

declare -A __done_map=()
while IFS= read -r __dline || [[ -n ${__dline} ]]; do
	[[ -n ${__dline//[[:space:]]/} ]] || continue
	__done_map["${__dline}"]=1
done <"${FE_DONE_FILE}"

declare -a SELECTED_FE_LINES=()
while IFS= read -r __pline || [[ -n ${__pline} ]]; do
	[[ -n ${__pline//[[:space:]]/} ]] || continue
	if [[ -z ${__done_map["${__pline}"]+x} ]]; then
		SELECTED_FE_LINES+=("${__pline}")
		__done_map["${__pline}"]=1
		if ((${#SELECTED_FE_LINES[@]} >= PARALLEL_N)); then
			break
		fi
	fi
done <"${FE_PARAMS_PATH}"

if ((${#SELECTED_FE_LINES[@]} == 0)); then
	log_step "Nothing left to run. Deleting ${FE_DONE_FILE} and exiting."
	rm -f "${FE_DONE_FILE}" 2>/dev/null || true
	exit 0
fi

log_step "Running execution with the parameters (selected on FE before deployment):"
for __p in "${SELECTED_FE_LINES[@]}"; do
	echo "  ${__p}"
done

# Immediately append selected lines to done.txt
{
	for __p in "${SELECTED_FE_LINES[@]}"; do printf '%s\n' "${__p}"; done
} >>"${FE_DONE_FILE}"

# Keep selection in-memory (no files) and prepare transfer to node via env var
SELECTED_LINES_B64=$(printf '%s\n' "${SELECTED_FE_LINES[@]}" | base64 -w0)
FE_SELECTION_MADE=1
FE_BATCH_OK=0

fe_revert_done() {
	# Remove exactly one occurrence of each selected line from done.txt without creating a file with the lines
	local tmp_out
	tmp_out="${FE_DONE_FILE}.tmp.$$"
	awk -v list="${SELECTED_LINES_B64}" '
		BEGIN { n = split(list_dec(list), arr, "\n"); for (i=1;i<=n;i++) if (length(arr[i])) c[arr[i]]++ }
		function list_dec(s,   cmd, out) { cmd = "echo \"" s "\" | base64 -d"; cmd | getline out; close(cmd); return out }
		{ if (c[$0] > 0) { c[$0]--; next } print }
	' "${FE_DONE_FILE}" >"${tmp_out}" && mv "${tmp_out}" "${FE_DONE_FILE}" || true
}

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
	# Start streaming remote logs to FE console
	if command -v stdbuf >/dev/null 2>&1; then
		log_info "Starting remote log stream from ${NODE_NAME} (${REMOTE_LOGS_DIR})"
		ssh -o StrictHostKeyChecking=no "root@${NODE_NAME}" \
			"bash -lc 'shopt -s nullglob; mkdir -p ${REMOTE_LOGS_DIR}; touch ${REMOTE_LOGS_DIR}/delegator.log ${REMOTE_LOGS_DIR}/collector.log; stdbuf -oL -eL tail -v -n +1 -F ${REMOTE_LOGS_DIR}/delegator.log ${REMOTE_LOGS_DIR}/collector.log 2>/dev/null'" |
			while IFS= read -r line; do
				ts=$(date +%H:%M:%S)
				echo "[${ts}] [INFO]  [${NODE_NAME}] ${line}"
			done &
		STREAM_PID=$!
	else
		log_warn "stdbuf not available on FE; log streaming may be buffered."
		ssh -o StrictHostKeyChecking=no "root@${NODE_NAME}" \
			"bash -lc 'shopt -s nullglob; mkdir -p ${REMOTE_LOGS_DIR}; touch ${REMOTE_LOGS_DIR}/delegator.log ${REMOTE_LOGS_DIR}/collector.log; tail -v -n +1 -F ${REMOTE_LOGS_DIR}/delegator.log ${REMOTE_LOGS_DIR}/collector.log 2>/dev/null'" |
			while IFS= read -r line; do
				ts=$(date +%H:%M:%S)
				echo "[${ts}] [INFO]  [${NODE_NAME}] ${line}"
			done &
		STREAM_PID=$!
	fi

	# Run delegator synchronously; its stdout will also appear locally
	set +e
	LOG_FILE="${LOG_DIR}/delegator.log" ssh -o StrictHostKeyChecking=no "root@${NODE_NAME}" \
		"bash -lc 'if command -v stdbuf >/dev/null 2>&1; then STDBUF_PREFIX="stdbuf -oL -eL "; fi; export SELECTED_PARAMS_B64=${SELECTED_LINES_B64:-}; CONFIG_JSON=~/experiments_node/config.json ${STDBUF_PREFIX:-}~/experiments_node/on-machine/run_delegator.sh'"
	deleg_rc=$?
	set -e

	# Stop streaming once delegator completes
	if [[ -n ${STREAM_PID:-} ]]; then
		kill "${STREAM_PID}" >/dev/null 2>&1 || true
		wait "${STREAM_PID}" >/dev/null 2>&1 || true
		unset STREAM_PID
		log_info "Stopped remote log stream from ${NODE_NAME}"
	fi

	# If delegator failed and FE selection was made, revert done.txt lines selected for this batch
	if [[ ${deleg_rc:-0} -ne 0 && ${FE_SELECTION_MADE:-0} -eq 1 && ${FE_BATCH_OK:-0} -eq 0 ]]; then
		log_warn "Delegator failed; reverting FE done.txt entries for the current batch."
		fe_revert_done
	else
		FE_BATCH_OK=1
	fi
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
