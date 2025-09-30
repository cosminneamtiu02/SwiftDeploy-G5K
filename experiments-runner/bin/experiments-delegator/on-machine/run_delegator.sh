#!/usr/bin/env bash
# Runs on node. Reads params and runs experiments in parallel, then runs collection strategy.
set -euo pipefail
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

# Build todo vs done sets
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
	log "No remaining experiments to run. Exiting."
	exit 0
fi

# Take up to PARALLEL_N lines
batch=()
for ((i = 0; i < ${#remaining[@]} && i < PARALLEL_N; i++)); do
	batch+=("${remaining[${i}]}")
	echo "${remaining[${i}]}" >>"${TRACKER_FILE}"
done

log "Launching ${#batch[@]} experiments (parallel=${PARALLEL_N}) in ${EXEC_DIR}"

cd "${EXEC_DIR}" || die "Cannot cd to ${EXEC_DIR}"

# Prefer GNU parallel if exists
if command -v parallel >/dev/null 2>&1; then
	# Stream outputs to both console and delegator.log so FE tail can display them nicely
	printf '%s\n' "${batch[@]}" |
		sed -e "s#^#${EXEC_CMD} #" |
		parallel -j "${PARALLEL_N}" --halt soon,fail=1 2>&1 |
		tee -a "${LOGS_DIR}/delegator.log"
else
	pids=()
	for params in "${batch[@]}"; do
		# Running in background; capturing command's output, so SC2312 is not applicable here.
		# shellcheck disable=SC2312
		sh -c "${EXEC_CMD} ${params}" >"${LOGS_DIR}/$(date +%s)_$(echo "${params}" | tr ' ' '_').out" 2>&1 &
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
