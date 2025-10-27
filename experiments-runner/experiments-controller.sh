#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=experiments-runner/runtime/common/environment.sh
source "${SCRIPT_DIR}/runtime/common/environment.sh"
runner_env::bootstrap

: "${RUNNER_ROOT:?runner_env::bootstrap must set RUNNER_ROOT}"
: "${LOG_ROOT:?runner_env::bootstrap must set LOG_ROOT}"
: "${SELECTION_ROOT:?runner_env::bootstrap must set SELECTION_ROOT}"
: "${PROVISIONING_ROOT:?runner_env::bootstrap must set PROVISIONING_ROOT}"
: "${PREPARATION_ROOT:?runner_env::bootstrap must set PREPARATION_ROOT}"
: "${EXECUTION_ROOT:?runner_env::bootstrap must set EXECUTION_ROOT}"
: "${COLLECTION_ROOT:?runner_env::bootstrap must set COLLECTION_ROOT}"

runner_env::require_cmd jq

usage() {
	cat <<'EOF'
Usage: experiments-controller.sh --config <config.json> [--verbose]
EOF
}

CONFIG_NAME=""
VERBOSE=false

while [[ $# -gt 0 ]]; do
	case "$1" in
		--config)
			CONFIG_NAME=${2:-}
			shift 2
			;;
		--verbose | -v)
			VERBOSE=true
			shift
			;;
		*)
			usage
			exit 1
			;;
	esac
done

[[ -n ${CONFIG_NAME} ]] || {
	usage
	exit 1
}

if [[ ${VERBOSE} == true ]]; then
	export LOG_LEVEL=debug
else
	export LOG_LEVEL=${LOG_LEVEL:-info}
fi

find_config_path() {
	local name="$1"
	local search_dir
	local -a search_dirs=(
		"${RUNNER_ROOT}/experiments-configurations"
		"${RUNNER_ROOT}/experiments-configurations/implementations"
	)
	for search_dir in "${search_dirs[@]}"; do
		if [[ -f "${search_dir}/${name}" ]]; then
			printf '%s\n' "${search_dir}/${name}"
			return 0
		fi
	done
	return 1
}

set +e
CONFIG_PATH=$(find_config_path "${CONFIG_NAME}")
config_lookup_rc=$?
set -e
if ((config_lookup_rc != 0)) || [[ -z ${CONFIG_PATH} ]]; then
	die "Config ${CONFIG_NAME} not found under ${RUNNER_ROOT}/experiments-configurations"
fi

runner_env::ensure_directory "${LOG_ROOT}"
LOG_DIR="${LOG_ROOT}"

STATE_DIR=$(mktemp -d "${LOG_DIR}/controller_state.XXXXXX")

cleanup_state_dir() {
	if [[ -d ${STATE_DIR} ]]; then
		rm -rf "${STATE_DIR}" 2>/dev/null || true
	fi
}
trap cleanup_state_dir EXIT

PHASE0_STATE_FILE="${STATE_DIR}/phase0_state.env"
PHASE1_STATE_FILE="${STATE_DIR}/phase1_state.env"
PHASE2_STATE_FILE="${STATE_DIR}/phase2_state.env"
PHASE3_STATE_FILE="${STATE_DIR}/phase3_state.env"
PHASE4_STATE_FILE="${STATE_DIR}/phase4_state.env"

SELECTION_SCRIPT="${SELECTION_ROOT}/select_batch.sh"
PROVISION_SCRIPT="${PROVISIONING_ROOT}/provision_machine.sh"
PREPARATION_SCRIPT="${PREPARATION_ROOT}/prepare_project_assets.sh"
EXECUTION_SCRIPT="${EXECUTION_ROOT}/delegate_experiments.sh"
COLLECTION_SCRIPT="${COLLECTION_ROOT}/collect-artifacts.sh"

for required_script in \
	"${SELECTION_SCRIPT}" \
	"${PROVISION_SCRIPT}" \
	"${PREPARATION_SCRIPT}" \
	"${EXECUTION_SCRIPT}" \
	"${COLLECTION_SCRIPT}"; do
	[[ -x ${required_script} ]] || die "Missing executable script: ${required_script}"
done

# --- Phase 0: Selection ---
"${SELECTION_SCRIPT}" run --config "${CONFIG_PATH}" --state-file "${PHASE0_STATE_FILE}"
# shellcheck source=/dev/null
source "${PHASE0_STATE_FILE}"

BATCH_SELECTED=${BATCH_SELECTED:-0}
SELECTED_LINES_FILE=${SELECTED_LINES_FILE:-""}
SELECTED_LINES_B64=${SELECTED_LINES_B64:-""}

if [[ ${BATCH_SELECTED} -ne 1 ]]; then
	"${SELECTION_SCRIPT}" finalize --state-file "${PHASE0_STATE_FILE}" --status success
	cleanup_state_dir
	trap - EXIT
	log_success 'Stopped before execution: no pending parameters.'
	exit 0
fi

if [[ -f ${SELECTED_LINES_FILE} ]]; then
	SELECTED_BATCH_CONTENT=$(<"${SELECTED_LINES_FILE}")
	export SELECTED_BATCH="${SELECTED_BATCH_CONTENT}"
fi

phase0_finalize_on_exit() {
	"${SELECTION_SCRIPT}" finalize --state-file "${PHASE0_STATE_FILE}" --status failure
	cleanup_state_dir
}
trap phase0_finalize_on_exit EXIT

# --- Phase 1: Machine provisioning ---
"${PROVISION_SCRIPT}" run \
	--config "${CONFIG_PATH}" \
	--log-dir "${LOG_DIR}" \
	--state-file "${PHASE1_STATE_FILE}"
# shellcheck source=/dev/null
source "${PHASE1_STATE_FILE}"

NODE_NAME=${NODE_NAME:-""}
IMAGE_YAML=${IMAGE_YAML:-""}
[[ -n ${NODE_NAME} ]] || die 'Phase 1 did not produce NODE_NAME'
[[ -n ${IMAGE_YAML} ]] || die 'Phase 1 did not produce IMAGE_YAML'

# --- Phase 2: Project preparation ---
"${PREPARATION_SCRIPT}" run \
	--config "${CONFIG_PATH}" \
	--node "${NODE_NAME}" \
	--image-yaml "${IMAGE_YAML}" \
	--selected-b64 "${SELECTED_LINES_B64}" \
	--log-dir "${LOG_DIR}" \
	--state-file "${PHASE2_STATE_FILE}"

# --- Phase 3: Delegation ---
"${EXECUTION_SCRIPT}" run \
	--node "${NODE_NAME}" \
	--selected-b64 "${SELECTED_LINES_B64}" \
	--log-dir "${LOG_DIR}" \
	--state-file "${PHASE3_STATE_FILE}"

# --- Phase 4: Collection ---
EXEC_DIR=$(jq -r '.running_experiments.on_machine.full_path_to_executable // empty' "${CONFIG_PATH}")
[[ -n ${EXEC_DIR} ]] || die 'Config error: .running_experiments.on_machine.full_path_to_executable is missing or empty'

"${COLLECTION_SCRIPT}" run \
	--config "${CONFIG_PATH}" \
	--node "${NODE_NAME}" \
	--exec-dir "${EXEC_DIR}" \
	--log-dir "${LOG_DIR}" \
	--state-file "${PHASE4_STATE_FILE}"

# --- Finalize Phase 0 ---
"${SELECTION_SCRIPT}" finalize --state-file "${PHASE0_STATE_FILE}" --status success
trap cleanup_state_dir EXIT

if [[ -f ${SELECTED_LINES_FILE} ]]; then
	rm -f "${SELECTED_LINES_FILE}" 2>/dev/null || true
fi

log_success "All phases completed. Logs at: ${LOG_DIR}"
