#!/usr/bin/env bash
# csnn_collection.sh — Concatenate *.txt from machine path into FE path/collected_results.txt

set -Eeuo pipefail
IFS=$'\n\t'
trap 'echo "[ERROR] ${BASH_SOURCE[0]}:$LINENO ${BASH_COMMAND}" >&2' ERR

MACHINE_PATH=""
FE_PATH=""
DRY_RUN=false

usage() {
	cat <<EOF
Usage: csnn_collection.sh --machine-path <dir> --fe-path <dir> [--dry-run]
EOF
}

while [[ $# -gt 0 ]]; do
	case "$1" in
		--machine-path)
			MACHINE_PATH="$2"
			shift 2
			;;
		--fe-path)
			FE_PATH="$2"
			shift 2
			;;
		--dry-run)
			DRY_RUN=true
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

[[ -n ${MACHINE_PATH} ]] || {
	echo "[ERROR] --machine-path required" >&2
	exit 2
}
[[ -n ${FE_PATH} ]] || {
	echo "[ERROR] --fe-path required" >&2
	exit 2
}

if [[ ! -d ${MACHINE_PATH} ]]; then
	echo "[ERROR] Machine path not found: ${MACHINE_PATH}" >&2
	exit 2
fi

mkdir -p "${FE_PATH}"
OUT_FILE="${FE_PATH}/collected_results.txt"

mkdir -p "${FE_PATH}"
OUT_FILE="${FE_PATH}/collected_results.txt"

echo "[INFO] Collecting *.txt from ${MACHINE_PATH} into ${OUT_FILE}"
count_files=0
count_lines=0
{
	for f in $(find "${MACHINE_PATH}" -type f -name '*.txt' | sort); do
		echo "===== BEGIN ${f} ====="
		if [[ ${DRY_RUN} == true ]]; then
			echo "[DRY-RUN] Would append contents of ${f}"
		else
			nl -ba "${f}"
		fi
		echo "===== END ${f} ====="
		((count_files++)) || true
		((count_lines += $(wc -l <"${f}" 2>/dev/null || echo 0))) || true
	done
} >"${OUT_FILE}"

echo "[INFO] Collection summary: files=${count_files}, lines=${count_lines}"
