#!/usr/bin/env bash
# node-agent.sh — Runs on node, polls for commands and executes them. Communication is file-based via scp.
# Directories:
#   BASE=~/experiments_node
#   CONTROL=$BASE/control
#   BOOTSTRAP=$BASE/on-machine/bootstrap
#   LOGS=$BASE/on-machine/logs
# Protocol:
#   FE scps commands.pending -> $CONTROL/
#   FE scps config.json (optional collection config) -> $CONTROL/
#   FE scps a zero-length file 'trigger' -> $CONTROL/ to start
#   Agent moves commands.pending -> commands.running, invokes run-batch.sh, writes status.json
#   On completion, agent writes status.json {state: done}

set -Eeuo pipefail
IFS=$'\n\t'
trap 'echo "[AGENT-ERROR] ${BASH_SOURCE[0]}:$LINENO ${BASH_COMMAND}" >&2' ERR

BASE="${HOME}/experiments_node"
ONM_BASE="${BASE}/on-machine"
BOOTSTRAP="${ONM_BASE}/bootstrap"
EXECUTABLES="${ONM_BASE}/executables"
LOGS="${ONM_BASE}/logs"
RESULTS="${ONM_BASE}/results"
CONTROL="${BASE}/control"

mkdir -p "${BOOTSTRAP}" "${EXECUTABLES}" "${LOGS}" "${RESULTS}" "${CONTROL}"

STATUS_FILE="${CONTROL}/status.json"
CMDS_PENDING="${CONTROL}/commands.pending"
CMDS_RUNNING="${CONTROL}/commands.running"
TRIGGER_FILE="${CONTROL}/trigger"
CONFIG_JSON="${CONTROL}/config.json"

PARALLEL_DEFAULT=${PARALLEL_DEFAULT:-1}
SLEEP_INTERVAL=${SLEEP_INTERVAL:-2}

write_status() {
	local state="$1" msg="${2:-}"
	jq -n --arg state "${state}" --arg msg "${msg}" '{state: $state, message: $msg, ts: now|toiso8601}' >"${STATUS_FILE}.tmp" 2>/dev/null ||
		echo "{\"state\":\"${state}\",\"message\":\"${msg}\"}" >"${STATUS_FILE}.tmp"
	mv "${STATUS_FILE}.tmp" "${STATUS_FILE}"
}

run_batch() {
	local full_path="$1" parallel="$2" commands_file="$3"
	write_status running "starting batch"
	# Ensure run-batch.sh exists; it should be delivered via FE package
	local runner="${ONM_BASE}/run-batch.sh"
	if [[ ! -x ${runner} ]]; then
		write_status error "runner not found: ${runner}"
		return 1
	fi
	bash "${runner}" --full-path "${full_path}" --commands-file "${commands_file}" --parallel "${parallel}" \
		>>"${LOGS}/agent-run-batch.out" 2>>"${LOGS}/agent-run-batch.err" || true
}

collect_if_configured() {
	if [[ -f ${CONFIG_JSON} ]] && command -v jq >/dev/null 2>&1; then
		local strategy machine_path fe_path
		strategy=$(jq -r '.collection_strategy // empty' <"${CONFIG_JSON}")
		machine_path=$(jq -r '.path_to_saved_experiment_results_on_machine // empty' <"${CONFIG_JSON}")
		fe_path=$(jq -r '.path_to_save_experiment_results_on_fe // empty' <"${CONFIG_JSON}")
		if [[ -n ${strategy} && -n ${machine_path} && -n ${fe_path} ]]; then
			local collector="${ONM_BASE}/collection/${strategy}"
			if [[ -x ${collector} ]]; then
				bash -lc "'${collector}' --machine-path '${machine_path}' --fe-path '${fe_path}'" \
					>>"${LOGS}/agent-collect.out" 2>>"${LOGS}/agent-collect.err" || true
			fi
		fi
	fi
}

echo "[AGENT] started; watching ${CONTROL}"
write_status idle "waiting for trigger"

while :; do
	if [[ -f ${TRIGGER_FILE} && -f ${CMDS_PENDING} ]]; then
		# Snapshot and clear trigger to allow next cycles
		rm -f "${TRIGGER_FILE}"
		mv -f "${CMDS_PENDING}" "${CMDS_RUNNING}"
		# Parse optional agent params from a sidecar file
		PARALLEL="${PARALLEL_DEFAULT}"
		if [[ -f ${CONTROL}/parallel.txt ]]; then
			PARALLEL=$(<"${CONTROL}/parallel.txt")
		fi
		FULL_PATH=""
		if [[ -f ${CONTROL}/full_path.txt ]]; then
			FULL_PATH=$(<"${CONTROL}/full_path.txt")
		else
			# Fallback: attempt to extract path from first command's leading token
			FULL_PATH=$(head -n1 "${CMDS_RUNNING}" | awk '{print $1}')
		fi
		run_batch "${FULL_PATH}" "${PARALLEL}" "${CMDS_RUNNING}"
		# Run collection best-effort without affecting set -e
		set +e
		collect_if_configured
		set -e
		write_status "done" "batch finished"
		# Keep commands.running for inspection; next trigger will overwrite when new pending arrives
	fi
	sleep "${SLEEP_INTERVAL}"
done
