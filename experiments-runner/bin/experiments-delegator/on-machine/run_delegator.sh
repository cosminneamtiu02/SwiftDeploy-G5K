#!/usr/bin/env bash
# Runs on node. Reads params and runs experiments in parallel, with tracker handling and collection strategy.
set -Eeuo pipefail
IFS=$'\n\t'

BASE_DIR="/root/experiments_node"
CONFIG_JSON_PATH="${CONFIG_JSON:-${BASE_DIR}/config.json}"
PARAMS_FILE="${BASE_DIR}/params.txt"
TRACKER_FILE="${PARAMS_FILE%.*}_tracker.txt"
LOGS_DIR="${BASE_DIR}/on-machine/logs"
# shellcheck source=/root/experiments_node/on-machine/.env
if [[ -f "${BASE_DIR}/on-machine/.env" ]]; then
	# Only source if present
	# shellcheck disable=SC1091
	source "${BASE_DIR}/on-machine/.env"
fi

log() {
	local ts
	ts=$(date +"%H:%M:%S")
	echo "[${ts}] $*" | tee -a "${LOGS_DIR}/delegator.log"
}
err() { echo "ERROR: $*" | tee -a "${LOGS_DIR}/delegator.log" >&2; }

die() {
	err "$*"
	exit 1
}

require_cmd() { command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"; }

require_cmd jq

[[ -f ${CONFIG_JSON_PATH} ]] || die "Missing ${CONFIG_JSON_PATH}"
[[ -f ${PARAMS_FILE} ]] || die "Missing ${PARAMS_FILE}"

EXEC_CMD=$(jq -r '.running_experiments.on_machine.execute_command' "${CONFIG_JSON_PATH}")
EXEC_DIR=$(jq -r '.running_experiments.on_machine.full_path_to_executable' "${CONFIG_JSON_PATH}")
PARALLEL_N=$(jq -r '.running_experiments.number_of_experiments_to_run_in_parallel_on_machine' "${CONFIG_JSON_PATH}")

mkdir -p "${LOGS_DIR}"
: >"${LOGS_DIR}/delegator.log"

# Prefer line-buffered output so streams appear live on the FE even when stdout is a pipe
if command -v stdbuf >/dev/null 2>&1; then
	BUF_PREFIX="stdbuf -oL -eL"
else
	BUF_PREFIX=""
fi

batch=()
if [[ -n ${SELECTED_PARAMS_B64:-} ]]; then
	# FE-side selection provided
	# Decode first to avoid masking return codes in process substitution (SC2312)
	if ! decoded_params=$(printf '%s' "${SELECTED_PARAMS_B64}" | base64 -d); then
		die "Failed to decode SELECTED_PARAMS_B64"
	fi
	mapfile -t batch <<<"${decoded_params}"
else
	# Build todo vs done sets on node
	mapfile -t todo < <(grep -v '^[[:space:]]*$' "${PARAMS_FILE}" || true)
	if [[ -f ${TRACKER_FILE} ]]; then
		mapfile -t already_done < <(grep -v '^[[:space:]]*$' "${TRACKER_FILE}" || true)
	else
		already_done=()
	fi

	# Compute remaining by filtering todo - done
	remaining=()
	for line in "${todo[@]}"; do
		skip=false
		for d in "${already_done[@]}"; do
			if [[ ${line} == "${d}" ]]; then
				skip=true
				break
			fi
		done
		if ! ${skip}; then
			remaining+=("${line}")
		fi
	done

	if [[ ${#remaining[@]} -eq 0 ]]; then
		log "No more lines left to run experiments on. Exiting."
		exit 0
	fi

	# Take up to PARALLEL_N lines
	for ((i = 0; i < ${#remaining[@]} && i < PARALLEL_N; i++)); do
		batch+=("${remaining[${i}]}")
	done
fi

# Log batch parameters prominently and write them immediately to tracker
log "Running execution with the parameters:"
for p in "${batch[@]}"; do
	log "${p}"
done

# Keep a mark of lines we add to tracker, so we can revert on failure or interruption
BATCH_MARK_FILE="${LOGS_DIR}/.current_batch_$$.txt"
: >"${BATCH_MARK_FILE}"
# Success flag and revert guard
BATCH_OK=0
REVERT_DONE=0
for p in "${batch[@]}"; do
	printf '%s\n' "${p}" | tee -a "${TRACKER_FILE}" >>"${BATCH_MARK_FILE}"
done

log "Launching ${#batch[@]} experiments (parallel=${PARALLEL_N}) in ${EXEC_DIR}"

cd "${EXEC_DIR}" || die "Cannot cd to ${EXEC_DIR}"

# Revert tracker entries added for this batch (exact occurrences) — used on failure/interrupt
revert_tracker_entries() {
	[[ -s ${BATCH_MARK_FILE} && -f ${TRACKER_FILE} ]] || return 0
	tmp_trk="${TRACKER_FILE}.tmp.$$"
	# Remove exactly one occurrence of each line listed in BATCH_MARK_FILE
	awk 'BEGIN{ while((getline line<ARGV[2])>0){c[line]++} close(ARGV[2]) } { if(c[$0]>0){ c[$0]--; next } print }' \
		"${TRACKER_FILE}" "${BATCH_MARK_FILE}" >"${tmp_trk}" && mv "${tmp_trk}" "${TRACKER_FILE}" || true
	REVERT_DONE=1
}

on_fail_or_interrupt() {
	err "Execution failed or interrupted. Reverting tracker entries for current batch."
	revert_tracker_entries
	exit 1
}

on_exit() {
	# If not marked success and we haven't reverted yet (e.g., SIGHUP), revert now
	if [[ ${BATCH_OK} -ne 1 && ${REVERT_DONE} -ne 1 ]]; then
		err "Exiting without success; reverting tracker entries for current batch."
		revert_tracker_entries
	fi
	rm -f "${BATCH_MARK_FILE}" 2>/dev/null || true
}

trap on_fail_or_interrupt ERR INT TERM HUP
trap on_exit EXIT

# Detailed error context for debugging: log the exact line and command on failure
__on_err() {
	local exit_code=$?
	local line_no=${BASH_LINENO[0]:-?}
	local cmd=${BASH_COMMAND:-unknown}
	err "Failure (exit=${exit_code}) at line ${line_no} while running: ${cmd}"
	# Fall back to the standard failure handler
	on_fail_or_interrupt
}
trap __on_err ERR

# Prefer GNU parallel if exists
if command -v parallel >/dev/null 2>&1; then
	# Stream outputs to both console and delegator.log so FE tail can display them nicely
	printf '%s\n' "${batch[@]}" |
		sed -e "s#^#${BUF_PREFIX} ${EXEC_CMD} #" |
		parallel -j "${PARALLEL_N}" --line-buffer --halt soon,fail=1 2>&1 |
		tee -a "${LOGS_DIR}/delegator.log"
else
	pids=()
	for params in "${batch[@]}"; do
		# Run in background and stream both stdout/stderr; keep live stdout for FE, and tee to logs
		# shellcheck disable=SC2312
		outfile="${LOGS_DIR}/$(date +%s)_$(echo "${params}" | tr ' ' '_').out"
		sh -c "${BUF_PREFIX} ${EXEC_CMD} ${params}" 2>&1 | tee -a "${LOGS_DIR}/delegator.log" | tee "${outfile}" &
		pids+=("$!")
	done
	# wait for all
	status=0
	for pid in "${pids[@]}"; do
		if ! wait "${pid}"; then
			status=1
		fi
	done
	if [[ ${status} -ne 0 ]]; then
		# Revert tracker entries for this batch on failure
		revert_tracker_entries
		die "At least one experiment failed"
	fi
fi

log "Batch completed. Starting collection if configured."
STRAT=$(jq -r '.running_experiments.experiments_collection.collection_strategy // empty' "${CONFIG_JSON_PATH}")
if [[ -n ${STRAT} && -x "${BASE_DIR}/on-machine/${STRAT}" ]]; then
	"${BASE_DIR}/on-machine/${STRAT}" "${CONFIG_JSON_PATH}" | tee -a "${LOGS_DIR}/collector.log"
else
	log "No collection strategy configured or not found. Skipping."
fi

log "Delegator done."

# Mark success so EXIT trap does not revert
BATCH_OK=1
