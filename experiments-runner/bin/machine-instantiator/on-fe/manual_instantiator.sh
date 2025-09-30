#!/usr/bin/env bash
# Manual machine instantiation: user reserves a node and deploys the given image YAML
# Writes the node name to experiments-runner/current_node.txt
set -euo pipefail
IFS=$'\n\t'

YAML_NAME=${1:-}
if [[ -z ${YAML_NAME} ]]; then
	echo "Usage: $0 <image_yaml_filename>" >&2
	exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNNER_ROOT="$(cd "${SCRIPT_DIR}/../../../.." && pwd)"
CURRENT_NODE_FILE="${RUNNER_ROOT}/current_node.txt"
YAML_DIR="${HOME}/envs/img-files"
YAML_PATH="${YAML_DIR}/${YAML_NAME}"

if [[ ! -f ${YAML_PATH} ]]; then
	echo "ERROR: YAML not found at ${YAML_PATH}" >&2
	echo "Hint: the env-creator now stores YAMLs under ~/envs/img-files and tars under ~/envs/img" >&2
	exit 1
fi

cat <<EOF
Manual instantiation selected.
Please ensure you have an interactive deploy shell on Grid'5000 with a node reserved, e.g.:
  oarsub -I -t deploy -q default
Then deploy the image in that terminal (YAML from ~/envs/img-files):
	kadeploy3 -a ${YAML_PATH}
After deployment completes, identify the node name (hostname). Enter it below.
EOF

read -r -p "Enter the allocated node hostname (e.g., parasilo-XX.nancy.grid5000.fr): " NODE_NAME
if [[ -z ${NODE_NAME} ]]; then
	echo "No node name provided." >&2
	exit 1
fi

printf '%s\n' "${NODE_NAME}" >"${CURRENT_NODE_FILE}"
chmod 600 "${CURRENT_NODE_FILE}"
echo "Saved node to ${CURRENT_NODE_FILE}: ${NODE_NAME}"
