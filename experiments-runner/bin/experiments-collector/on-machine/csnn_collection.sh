#!/usr/bin/env bash
# Collection strategy: concatenate all *.txt from machine path into a single file on FE via scp back
set -euo pipefail
IFS=$'\n\t'

CONFIG_JSON_PATH=${1:-/root/experiments_node/config.json}
require_cmd() { command -v "$1" >/dev/null 2>&1 || {
	echo "Missing required command: $1" >&2
	exit 1
}; }
require_cmd jq

MACHINE_SRC_DIR=$(jq -r '.running_experiments.experiments_collection.path_to_saved_experiment_results_on_machine' "${CONFIG_JSON_PATH}")
FE_SAVE_DIR_REL=$(jq -r '.running_experiments.experiments_collection.path_to_save_experiment_results_on_fe' "${CONFIG_JSON_PATH}")

if [[ -z ${MACHINE_SRC_DIR} || -z ${FE_SAVE_DIR_REL} ]]; then
	echo "Collection paths missing in config" >&2
	exit 1
fi

TMP_COMBINED="/root/experiments_node/on-machine/combined_results.txt"
: >"${TMP_COMBINED}"

shopt -s nullglob
for f in "${MACHINE_SRC_DIR}"/*.txt; do
	cat "${f}" >>"${TMP_COMBINED}"
	echo "" >>"${TMP_COMBINED}"
done

# Attempt to push back to FE path by scp from node to FE via SSH reverse is non-trivial.
# Instead, keep the combined file in node area; FE user can scp it back manually using controller logs hint.
echo "Combined results at ${TMP_COMBINED}. Please pull to FE target directory: ${FE_SAVE_DIR_REL}" >&2
