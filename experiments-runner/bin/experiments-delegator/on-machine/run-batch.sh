#!/usr/bin/env bash
# run-batch.sh — On-machine parallel runner
# Inputs: --full-path /abs/path, --commands-file FILE, --parallel N

set -Eeuo pipefail
IFS=$'\n\t'
trap 'echo "[ERROR] ${BASH_SOURCE[0]}:${LINENO} ${BASH_COMMAND}" >&2' ERR

FULL_PATH=""
COMMANDS_FILE=""
PARALLEL=1

usage() {
	cat <<EOF
Usage: run-batch.sh --full-path <abs> --commands-file <file> --parallel <N>
Runs commands listed in <file> in parallel under <abs> directory, logging per job.
EOF
}

while [[ $# -gt 0 ]]; do
	case "${1}" in
		--full-path)
			FULL_PATH="${2}"
			shift 2
			;;
		--commands-file)
			COMMANDS_FILE="${2}"
			shift 2
			;;
		--parallel)
			PARALLEL="${2}"
			shift 2
			;;
		-h | --help)
			usage
			exit 0
			;;
		*)
			echo "Unknown arg: ${1}" >&2
			usage
			exit 2
			;;
	esac
done

[[ -d ${FULL_PATH} ]] || {
	echo "[ERROR] full path not a directory: ${FULL_PATH}" >&2
	exit 2
}
[[ -f ${COMMANDS_FILE} ]] || {
	echo "[ERROR] commands file not found: ${COMMANDS_FILE}" >&2
	exit 2
}

cd "${FULL_PATH}"
mkdir -p logs

if command -v parallel >/dev/null 2>&1; then
	# GNU parallel if available
	nl -ba "${COMMANDS_FILE}" | parallel -j "${PARALLEL}" --colsep '\t' --joblog logs/parallel.log \
		'bash -lc {2} > logs/job_{1}.out 2> logs/job_{1}.err'
else
	# Fallback: background jobs with concurrency control
	pids=()
	idx=0
	while IFS= read -r cmd; do
		[[ -n ${cmd} ]] || continue
		idx=$((idx + 1))
		out="logs/job_${idx}.out"
		err="logs/job_${idx}.err"
		bash -lc "${cmd}" >"${out}" 2>"${err}" &
		pids+=("$!")
		if ((${#pids[@]} >= PARALLEL)); then
			wait -n || true
			tmp=()
			for pid in "${pids[@]}"; do
				if kill -0 "${pid}" 2>/dev/null; then tmp+=("${pid}"); fi
			done
			pids=("${tmp[@]}")
		fi
	done <"${COMMANDS_FILE}"
	for pid in "${pids[@]}"; do wait "${pid}" || true; done
fi

echo "[INFO] Batch run completed; summarizing exits"
failures=0
for f in logs/job_*.err; do
	if [[ -s ${f} ]]; then
		echo "[WARN] Non-empty error log: ${f}"
		((failures++)) || true
	fi
done

if ((failures > 0)); then
	echo "[ERROR] Some jobs reported errors: ${failures}" >&2
	exit 1
fi

echo "[INFO] All jobs finished without error logs."

set -Eeuo pipefail
IFS=$'\n\t'
trap 'echo "[ERROR] ${BASH_SOURCE[0]}:$LINENO ${BASH_COMMAND}" >&2' ERR

echo "[INFO] Placeholder: run-batch implementation will be added (xargs -P or background jobs)."
if [[ ${1:-} == "--help" ]]; then
	cat <<EOF
Usage: run-batch.sh --full-path /abs/path --commands-file FILE --parallel N
EOF
fi
