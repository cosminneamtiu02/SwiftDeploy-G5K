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

# Auto-detect Grid'5000 env if not provided. Prefer OAR_NODEFILE and standard keys.
if [[ -z ${G5K_USER:-} ]]; then
	G5K_USER="${USER:-$(whoami)}"
	export G5K_USER
fi
if [[ -z ${G5K_HOST:-} && -n ${OAR_NODEFILE:-} && -f ${OAR_NODEFILE} ]]; then
	G5K_HOST="$(head -n1 "${OAR_NODEFILE}")"
	export G5K_HOST
fi
if [[ -z ${G5K_SSH_KEY:-} ]]; then
	for cand in "${HOME}/.ssh/id_rsa" "${HOME}/.ssh/id_ed25519"; do
		if [[ -f ${cand} ]]; then
			G5K_SSH_KEY="${cand}"
			export G5K_SSH_KEY
			break
		fi
	done
fi

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
REMOTE_CONTROL="${REMOTE_BASE}/control"
REMOTE_CMDS="${REMOTE_CONTROL}/commands.pending"
REMOTE_LOGS="${REMOTE_BASE}/on-machine/logs"

# Common copy helpers (scp with retries)
# shellcheck source=../utils/libremote.sh
# shellcheck disable=SC1091
source "${ROOT_DIR}/bin/utils/libremote.sh"

if [[ ${DRY_RUN} == true ]]; then
	echo "[DRY-RUN] Would upload commands to ${REMOTE_CMDS} and call run-batch"
	cat "${TMP_CMDS_LOCAL}"
	rm -f "${TMP_TODO}" "${TMP_CMDS_LOCAL}"
	exit 0
fi

echo "[INFO] Uploading commands list to remote control: ${REMOTE_CMDS}"
# Ensure control dir exists by copying a local stub directory
tmpdir=$(mktemp -d)
mkdir -p "${tmpdir}/control"
: >"${tmpdir}/control/.keep"
scp_to_retry "${G5K_USER}" "${G5K_HOST}" "${G5K_SSH_KEY}" "${tmpdir}/control" "${REMOTE_BASE}/"
rm -rf "${tmpdir}"
scp_to_retry "${G5K_USER}" "${G5K_HOST}" "${G5K_SSH_KEY}" "${TMP_CMDS_LOCAL}" "${REMOTE_CMDS}"

echo "[INFO] Triggering node agent via control file"
# Upload parallel.txt and full_path.txt if not already present
tmp_par=$(mktemp)
printf '%s\n' "${PARALLEL}" >"${tmp_par}"
scp_to_retry "${G5K_USER}" "${G5K_HOST}" "${G5K_SSH_KEY}" "${tmp_par}" "${REMOTE_CONTROL}/parallel.txt"
rm -f "${tmp_par}"
tmp_fp=$(mktemp)
printf '%s\n' "${FULL_PATH}" >"${tmp_fp}"
scp_to_retry "${G5K_USER}" "${G5K_HOST}" "${G5K_SSH_KEY}" "${tmp_fp}" "${REMOTE_CONTROL}/full_path.txt"
rm -f "${tmp_fp}"
# Create trigger file remotely by scp of an empty file
tmp_tr=$(mktemp)
: >"${tmp_tr}"
scp_to_retry "${G5K_USER}" "${G5K_HOST}" "${G5K_SSH_KEY}" "${tmp_tr}" "${REMOTE_CONTROL}/trigger"
rm -f "${tmp_tr}"

echo "[INFO] Remote batch started."

# Optional live log streaming loop while commands run
if [[ ${STREAM} == true ]]; then
	echo "[INFO] Streaming is disabled in pure-scp mode. Check logs under ${REMOTE_LOGS} after completion."
fi

echo "[INFO] Waiting for remote batch to complete (polling status file via scp) ..."
STATUS_LOCAL=$(mktemp)
while :; do
	if scp_from_retry "${G5K_USER}" "${G5K_HOST}" "${G5K_SSH_KEY}" "${REMOTE_CONTROL}/status.json" "${STATUS_LOCAL}" 2>/dev/null; then
		state=$(jq -r '.state // empty' <"${STATUS_LOCAL}" 2>/dev/null || true)
		if [[ ${state} == "done" ]]; then
			echo "[INFO] Remote batch completed."
			break
		fi
	fi
	sleep 2
done
rm -f "${STATUS_LOCAL}"

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
	echo "[INFO] Requesting collection via agent config"
	tmp_cfg=$(mktemp)
	printf '%s' "${COLLECTION_JSON}" >"${tmp_cfg}"
	scp_to_retry "${G5K_USER}" "${G5K_HOST}" "${G5K_SSH_KEY}" "${tmp_cfg}" "${REMOTE_CONTROL}/config.json"
	rm -f "${tmp_cfg}"
	# Re-trigger for collection
	tmp_tr2=$(mktemp)
	: >"${tmp_tr2}"
	scp_to_retry "${G5K_USER}" "${G5K_HOST}" "${G5K_SSH_KEY}" "${tmp_tr2}" "${REMOTE_CONTROL}/trigger"
	rm -f "${tmp_tr2}"
else
	echo "[INFO] No collection triggered (strategy or paths missing)."
fi
rm -f "${TMP_TODO}" "${TMP_CMDS_LOCAL}"
