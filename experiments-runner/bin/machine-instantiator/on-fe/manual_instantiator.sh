#!/usr/bin/env bash
# Manual machine instantiation with auto-detection of allocated node
# - Verifies YAML exists under ~/envs/img-files
# - Tries to detect node from OAR nodefile or oarstat
# - Falls back to prompting the user only if detection fails
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
	echo "Hint: the env-creator stores YAMLs under ~/envs/img-files and tars under ~/envs/img" >&2
	exit 1
fi

echo "Manual instantiation selected."
echo "Expecting you already ran: oarsub -I -t deploy -q default (in another terminal)."
echo "To deploy the image there: kadeploy3 -a ${YAML_PATH}"

detect_from_oar_env() {
	# Try common OAR nodefile env vars
	for var in OAR_NODEFILE OAR_NODE_FILE OAR_FILE_NODES; do
		if [[ -n ${!var-} && -f ${!var} ]]; then
			head -n1 "${!var}" | awk '{print $1}'
			return 0
		fi
	done
	return 1
}

detect_from_oarstat() {
	if ! command -v oarstat >/dev/null 2>&1; then
		return 1
	fi
	local last_id
	last_id=$(oarstat -u | awk '/^[0-9]+/ {print $1}' | tail -n1 || true)
	if [[ -z ${last_id} ]]; then
		return 1
	fi
	local line
	line=$(oarstat -j "${last_id}" -f | awk -F': ' '/^assigned_hostnames/ {print $2}')
	# sanitize: remove brackets, quotes, commas, then take first hostname
	echo "${line}" | tr -d '[],' | tr -d "'\"" | awk '{print $1}'
}

NODE_NAME=""
tmp=""

# Try detect from OAR env file without disabling 'set -e' for the whole script
set +e
tmp=$(detect_from_oar_env)
status=$?
set -e
if [[ ${status} -eq 0 && -n ${tmp} ]]; then
	NODE_NAME=${tmp}
	echo "Auto-detected node from OAR env file: ${NODE_NAME}"
else
	set +e
	tmp=$(detect_from_oarstat)
	status=$?
	set -e
	if [[ ${status} -eq 0 && -n ${tmp} ]]; then
		NODE_NAME=${tmp}
		echo "Auto-detected node via oarstat: ${NODE_NAME}"
	fi
fi

if [[ -z ${NODE_NAME} ]]; then
	read -r -p "Enter the allocated node hostname (e.g., parasilo-XX.nancy.grid5000.fr): " NODE_NAME
	if [[ -z ${NODE_NAME} ]]; then
		echo "No node name provided." >&2
		exit 1
	fi
fi

printf '%s\n' "${NODE_NAME}" >"${CURRENT_NODE_FILE}"
chmod 600 "${CURRENT_NODE_FILE}"
echo "Saved node to ${CURRENT_NODE_FILE}: ${NODE_NAME}"
