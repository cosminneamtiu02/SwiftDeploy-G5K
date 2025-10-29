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

CURRENT_PHASE="Initialization"
ROLLBACK_PENDING=false
ROLLBACK_COMPLETED=false
ERROR_ALREADY_HANDLED=false
declare -a SELECTED_PARAMS=()
SELECTED_DONE_FILE=""
SELECTED_PARAMS_B64=""

controller::set_phase() {
	CURRENT_PHASE="$1"
}

controller::revert_selection() {
	if [[ ${ROLLBACK_PENDING} != true ]]; then
		return 0
	fi
	if [[ ${ROLLBACK_COMPLETED} == true ]]; then
		return 0
	fi
	if [[ -z ${SELECTED_DONE_FILE} ]]; then
		return 0
	fi
	if ((${#SELECTED_PARAMS[@]} == 0)); then
		return 0
	fi
	log_debug "Reverting selection in ${SELECTED_DONE_FILE} (entries=${#SELECTED_PARAMS[@]})"
	local rollback_rc=0
	# shellcheck disable=SC2310
	select_batch::remove_entries_from_done "${SELECTED_DONE_FILE}" "${SELECTED_PARAMS[@]}" || rollback_rc=$?
	if ((rollback_rc == 0)); then
		log_info "Selection rollback completed for ${#SELECTED_PARAMS[@]} entrie(s)."
		ROLLBACK_PENDING=false
		ROLLBACK_COMPLETED=true
	else
		log_error "Selection rollback failed for ${SELECTED_DONE_FILE} (rc=${rollback_rc})"
	fi
	return 0
}

controller::handle_error() {
	local exit_code="$1"
	local failed_command="$2"
	log_error "Error source: ${CURRENT_PHASE:-unknown phase}"
	log_error "Failing command: ${failed_command}"
	log_error "Exit code: ${exit_code}"
	ERROR_ALREADY_HANDLED=true
	controller::revert_selection
	trap - ERR INT TERM HUP QUIT
	exit "${exit_code}"
}

controller::handle_interrupt() {
	log_error "Execution interrupted by user during ${CURRENT_PHASE:-unknown phase}."
	ERROR_ALREADY_HANDLED=true
	controller::revert_selection
	trap - ERR INT TERM HUP QUIT
	exit 130
}

controller::handle_termination() {
	local signal="${1:-TERM}"
	log_error "Execution terminated (${signal}) during ${CURRENT_PHASE:-unknown phase}."
	ERROR_ALREADY_HANDLED=true
	controller::revert_selection
	trap - ERR INT TERM HUP QUIT
	case "${signal}" in
		TERM) exit 143 ;;
		QUIT) exit 131 ;;
		HUP) exit 129 ;;
		*) exit 1 ;;
	esac
}

controller::ensure_ssh_identity() {
	local default_key="${HOME}/.ssh/id_rsa"
	local key_path="${G5K_SSH_KEY:-${default_key}}"
	if [[ ! -f ${key_path} ]]; then
		die "SSH identity not found. Set G5K_SSH_KEY to your private key path (e.g., export G5K_SSH_KEY=${default_key})."
	fi
	G5K_SSH_KEY="${key_path}"
	export G5K_SSH_KEY
	log_debug "Using SSH identity ${G5K_SSH_KEY}"
}

controller::disable_failure_traps() {
	trap - ERR INT TERM HUP QUIT
}

trap 'controller::handle_error $? "${BASH_COMMAND}"' ERR
trap controller::handle_interrupt INT
trap 'controller::handle_termination TERM' TERM
trap 'controller::handle_termination QUIT' QUIT
trap 'controller::handle_termination HUP' HUP

usage() {
	cat <<'EOF'
Usage: experiments-controller.sh --config <config.json> [--verbose]
EOF
}

CONFIG_NAME=""
VERBOSE=false

controller::set_phase "Project preparation"
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

controller::ensure_ssh_identity

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

controller::handle_exit() {
	local exit_code=$?
	trap - EXIT
	if ((exit_code != 0)); then
		if [[ ${ERROR_ALREADY_HANDLED} != true ]]; then
			log_error "Terminating during ${CURRENT_PHASE:-unknown phase}."
			log_error "Exit code: ${exit_code}"
			controller::revert_selection
		fi
	else
		controller::disable_failure_traps
	fi
	cleanup_state_dir
	exit "${exit_code}"
}
trap controller::handle_exit EXIT

PHASE1_STATE_FILE="${STATE_DIR}/phase1_state.env"
PHASE2_STATE_FILE="${STATE_DIR}/phase2_state.env"
PHASE3_STATE_FILE="${STATE_DIR}/phase3_state.env"
PHASE4_STATE_FILE="${STATE_DIR}/phase4_state.env"

SELECTION_LIB="${SELECTION_ROOT}/select_batch.sh"
PROVISION_SCRIPT="${PROVISIONING_ROOT}/provision_machine.sh"
PREPARATION_SCRIPT="${PREPARATION_ROOT}/prepare_project_assets.sh"
EXECUTION_SCRIPT="${EXECUTION_ROOT}/delegate_experiments.sh"
COLLECTION_SCRIPT="${COLLECTION_ROOT}/collect-artifacts.sh"

[[ -r ${SELECTION_LIB} ]] || die "Missing selection library: ${SELECTION_LIB}"

for required_script in \
	"${PROVISION_SCRIPT}" \
	"${PREPARATION_SCRIPT}" \
	"${EXECUTION_SCRIPT}" \
	"${COLLECTION_SCRIPT}"; do
	[[ -x ${required_script} ]] || die "Missing executable script: ${required_script}"
done

# shellcheck source=experiments-runner/runtime/phases/phase-selection/select_batch.sh
source "${SELECTION_LIB}"

# --- Phase 0: Selection ---
controller::set_phase "Selection"
SELECTED_PARAMS=()
SELECTED_DONE_FILE=""
SELECTED_PARAMS_B64=""

select_batch::pick "${CONFIG_PATH}" SELECTED_PARAMS SELECTED_DONE_FILE SELECTED_PARAMS_B64

if ((${#SELECTED_PARAMS[@]} == 0)); then
	controller::disable_failure_traps
	log_success 'Stopped before execution: no pending parameters.'
	exit 0
fi

runner_env::ensure_directory "$(dirname "${SELECTED_DONE_FILE}")"
if [[ ! -f ${SELECTED_DONE_FILE} ]]; then
	: >"${SELECTED_DONE_FILE}"
fi
{
	for todo_line in "${SELECTED_PARAMS[@]}"; do
		printf '%s\n' "${todo_line}"
	done
} >>"${SELECTED_DONE_FILE}"
log_info "Recorded ${#SELECTED_PARAMS[@]} parameter(s) in ${SELECTED_DONE_FILE}."

ROLLBACK_PENDING=true
ROLLBACK_COMPLETED=false

SELECTED_BATCH=$(printf '%s\n' "${SELECTED_PARAMS[@]}")
export SELECTED_BATCH
SELECTED_LINES_B64="${SELECTED_PARAMS_B64}"

controller::set_phase "Machine provisioning"

# --- Phase 1: Machine provisioning ---
phase1_node=""
phase1_image=""
phase1_status=0

while IFS= read -r phase1_line; do
	case "${phase1_line}" in
		__RESULT__*)
			entry=${phase1_line#__RESULT__ }
			key=${entry%%=*}
			value=${entry#*=}
			case "${key}" in
				NODE_NAME)
					phase1_node=${value}
					;;
				IMAGE_YAML)
					phase1_image=${value}
					;;
				*)
					die "Phase 1 provisioning produced unexpected key: ${key}"
					;;
			esac
			;;
		__STATUS__*)
			phase1_status=${phase1_line#__STATUS__ }
			;;
		*)
			printf '%s\n' "${phase1_line}"
			;;
	esac
done < <(
	{
		# shellcheck disable=SC2312  # exit code captured via phase1_rc below
		if "${PROVISION_SCRIPT}" run \
			--config "${CONFIG_PATH}" \
			--log-dir "${LOG_DIR}" \
			--state-file "${PHASE1_STATE_FILE}"; then
			phase1_rc=0
		else
			phase1_rc=$?
		fi
		printf '__STATUS__ %d\n' "${phase1_rc}"
	}
)

if [[ ${phase1_status} -ne 0 ]]; then
	die "Phase 1 provisioning failed with exit code ${phase1_status}"
fi

NODE_NAME=${phase1_node}
IMAGE_YAML=${phase1_image}
[[ -n ${NODE_NAME} ]] || die 'Phase 1 did not produce NODE_NAME'
[[ -n ${IMAGE_YAML} ]] || die 'Phase 1 did not produce IMAGE_YAML'

# --- Phase 2: Project preparation ---
controller::set_phase "Project preparation"
"${PREPARATION_SCRIPT}" run \
	--config "${CONFIG_PATH}" \
	--node "${NODE_NAME}" \
	--image-yaml "${IMAGE_YAML}" \
	--selected-b64 "${SELECTED_LINES_B64}" \
	--log-dir "${LOG_DIR}" \
	--state-file "${PHASE2_STATE_FILE}"

# --- Phase 3: Delegation ---
controller::set_phase "Delegation"
"${EXECUTION_SCRIPT}" run \
	--node "${NODE_NAME}" \
	--selected-b64 "${SELECTED_LINES_B64}" \
	--log-dir "${LOG_DIR}" \
	--state-file "${PHASE3_STATE_FILE}"

# --- Phase 4: Collection ---
controller::set_phase "Collection"
EXEC_DIR=$(jq -r '.running_experiments.on_machine.full_path_to_executable // empty' "${CONFIG_PATH}")
[[ -n ${EXEC_DIR} ]] || die 'Config error: .running_experiments.on_machine.full_path_to_executable is missing or empty'

"${COLLECTION_SCRIPT}" run \
	--config "${CONFIG_PATH}" \
	--node "${NODE_NAME}" \
	--exec-dir "${EXEC_DIR}" \
	--log-dir "${LOG_DIR}" \
	--state-file "${PHASE4_STATE_FILE}"

# --- Finalization ---
ROLLBACK_PENDING=false
controller::disable_failure_traps
controller::set_phase "Finalization"

log_success "All phases completed. Logs at: ${LOG_DIR}"
