for v in G5K_USER G5K_HOST G5K_SSH_KEY; do
	if [[ -z ${!v:-} ]]; then
		echo "[ERROR] Environment variable ${v} is required but not set." >&2
		exit 2
	fi
done
#!/usr/bin/env bash
# experiments-delegator.sh — Frontend delegator: choose params, run batch remotely, stream logs

set -Eeuo pipefail
IFS=$'\n\t'
trap 'echo "[ERROR] ${BASH_SOURCE[0]}:${LINENO} ${BASH_COMMAND}" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../../.." && pwd)"

PARALLEL=1
EXEC_CMD=""
FULL_PATH=""
PARAMS_FILE=""
COLLECTION_JSON="{}"
DRY_RUN=false
STREAM=true

usage() {
	cat <<EOF
Usage: experiments-delegator.sh --parallel N --execute-command CMD --full-path PATH --params-file FILE --collection-json JSON [--dry-run]
Requires env: G5K_USER, G5K_HOST, G5K_SSH_KEY
EOF
}

while [[ $# -gt 0 ]]; do
	case "$1" in
		--parallel)
			PARALLEL="$2"
			shift 2
			;;
		--execute-command)
			EXEC_CMD="$2"
			shift 2
			;;
		--full-path)
			FULL_PATH="$2"
			shift 2
			;;
		--params-file)
			PARAMS_FILE="$2"
			shift 2
			;;
		--collection-json)
			COLLECTION_JSON="$2"
			shift 2
			;;
		--dry-run)
			DRY_RUN=true
			shift
			;;
		--no-stream)
			STREAM=false
			shift
			;;
		-h | --help)
			usage
			exit 0
			;;
		*)
			echo "Unknown arg: $1" >&2
			usage
			exit 2
			;;
	esac
done

for v in G5K_USER G5K_HOST G5K_SSH_KEY; do
	: "${!v:?Environment variable ${v} is required}"
done

[[ -f ${PARAMS_FILE} ]] || {
	echo "[ERROR] params file not found: ${PARAMS_FILE}" >&2
	exit 2
}

TRACKER_FILE="${PARAMS_FILE%.txt}_tracker.txt"
TMP_TODO="$(mktemp)"

echo "[INFO] Selecting up to ${PARALLEL} TODO lines (tracker: ${TRACKER_FILE})"
"${ROOT_DIR}/bin/experiments-delegator/on-fe/utils-params-tracker.sh" select_next_lines "${PARAMS_FILE}" "${TRACKER_FILE}" "${PARALLEL}" >"${TMP_TODO}"

if [[ ! -s ${TMP_TODO} ]]; then
	echo "[INFO] No TODO lines found; nothing to run."
	rm -f "${TMP_TODO}"
	exit 0
fi

mapfile -t SELECTED <"${TMP_TODO}"

echo "[INFO] Appending selected lines to tracker to avoid double booking"
"${ROOT_DIR}/bin/experiments-delegator/on-fe/utils-params-tracker.sh" append_tracker "${TRACKER_FILE}" "${SELECTED[@]}"

TMP_CMDS_LOCAL="$(mktemp)"
: >"${TMP_CMDS_LOCAL}"
for line in "${SELECTED[@]}"; do
	printf '%s\n' "${EXEC_CMD} ${line}" >>"${TMP_CMDS_LOCAL}"
done

REMOTE_BASE="${HOME}/experiments_node"
REMOTE_BOOTSTRAP="${REMOTE_BASE}/on-machine/bootstrap"
REMOTE_CMDS="${REMOTE_BOOTSTRAP}/commands.pending"
REMOTE_LOGS="${REMOTE_BASE}/on-machine/logs"

if [[ ${DRY_RUN} == true ]]; then
	echo "[DRY-RUN] Would upload commands to ${REMOTE_CMDS} and call run-batch"
	cat "${TMP_CMDS_LOCAL}"
	rm -f "${TMP_TODO}" "${TMP_CMDS_LOCAL}"
	exit 0
fi

echo "[INFO] Uploading commands list to remote: ${REMOTE_CMDS}"
if [[ -z ${G5K_SSH_KEY:-} ]]; then
	echo "G5K_SSH_KEY is not set" >&2
	exit 1
fi
if [[ -z ${G5K_USER:-} ]]; then
	echo "G5K_USER is not set" >&2
	exit 1
fi
if [[ -z ${G5K_HOST:-} ]]; then
	echo "G5K_HOST is not set" >&2
	exit 1
fi
ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -i "${G5K_SSH_KEY}" "${G5K_USER}@${G5K_HOST}" "mkdir -p '${REMOTE_BOOTSTRAP}' '${REMOTE_LOGS}'"
scp -o BatchMode=yes -o StrictHostKeyChecking=accept-new -i "${G5K_SSH_KEY}" "${TMP_CMDS_LOCAL}" "${G5K_USER}@${G5K_HOST}:${REMOTE_CMDS}"

echo "[INFO] Triggering remote batch runner"
ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -i "${G5K_SSH_KEY}" "${G5K_USER}@${G5K_HOST}" \
	"bash '${REMOTE_BASE}/on-machine/run-batch.sh' --full-path '${FULL_PATH}' --commands-file '${REMOTE_CMDS}' --parallel '${PARALLEL}'"

echo "[INFO] Remote batch started."

# Optional live log streaming loop while commands run
if [[ ${STREAM} == true ]]; then
	echo "[INFO] Streaming remote logs (Ctrl-C to stop streaming; job will continue)"
	ssh -t -o BatchMode=yes -o StrictHostKeyChecking=accept-new -i "${G5K_SSH_KEY}" "${G5K_USER}@${G5K_HOST}" \
		"bash -lc 'mkdir -p \"${REMOTE_LOGS}\"; touch \"${REMOTE_LOGS}/stream.marker\"; tail -F \"${REMOTE_LOGS}\"/*.out \"${REMOTE_LOGS}\"/*.err 2>/dev/null'" || true
fi

echo "[INFO] Waiting for remote batch to complete..."
ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -i "${G5K_SSH_KEY}" "${G5K_USER}@${G5K_HOST}" \
	"bash -lc 'while pgrep -af run-batch.sh >/dev/null; do sleep 2; done'" || true

echo "[INFO] Remote batch completed."

# Trigger collection if strategy and paths provided
if command -v jq >/dev/null 2>&1; then
	strategy=$(jq -r '.collection_strategy // empty' <<<"${COLLECTION_JSON}")
	machine_path=$(jq -r '.path_to_saved_experiment_results_on_machine // empty' <<<"${COLLECTION_JSON}")
	fe_path=$(jq -r '.path_to_save_experiment_results_on_fe // empty' <<<"${COLLECTION_JSON}")
else
	strategy=""
	machine_path=""
	fe_path=""
fi

if [[ -n ${strategy} && -n ${machine_path} && -n ${fe_path} ]]; then
	echo "[INFO] Triggering collection: ${strategy}"
	ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -i "${G5K_SSH_KEY}" "${G5K_USER}@${G5K_HOST}" \
		"bash -lc '${REMOTE_BASE}/on-machine/collection/${strategy} --machine-path \"${machine_path}\" --fe-path \"${fe_path}\"'"
else
	echo "[INFO] No collection triggered (strategy or paths missing)."
fi
rm -f "${TMP_TODO}" "${TMP_CMDS_LOCAL}"
