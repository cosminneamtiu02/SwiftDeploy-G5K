#!/usr/bin/env bash
# experiments-controller.sh — Orchestrates Grid'5000 experiments: instantiate -> prepare -> delegate -> collect
# Strict Bash, robust logging, dry-run support, and phase control.

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_NAME="$(basename "$0")"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSION="0.1.0"

# Hardcoded absolute path to configs as required
CONFIG_DIR_ABS="${SCRIPT_DIR}/experiments-configurations"

# Default settings
CONFIG_FILE_NAME="csnn-faces.json" # only filename accepted; resolved under CONFIG_DIR_ABS
REQUESTED_PHASES="instantiate,prepare,delegate,collect"
DRY_RUN=false
VERBOSE=false
CONTINUE_ON_ERROR=false
NO_COLOR=false
LIVE_LOGS=true
FORCE_MANUAL_INSTANTIATION=false
LOG_DIR=""

# Colors
if [[ -t 1 ]] && [[ ${NO_COLOR} == "false" ]]; then
	RED="\033[31m"
	GREEN="\033[32m"
	YELLOW="\033[33m"
	DIM="\033[2m"
	BOLD="\033[1m"
	RESET="\033[0m"
else
	RED=""
	GREEN=""
	YELLOW=""
	DIM=""
	BOLD=""
	RESET=""
fi

# Fallback logging
log_ts() { date +"%Y-%m-%dT%H:%M:%S%z"; }
log_info() {
	ts=$(log_ts)
	echo -e "${ts} ${GREEN}[INFO]${RESET} $*"
}
log_warn() {
	ts=$(log_ts)
	echo -e "${ts} ${YELLOW}[WARN]${RESET} $*" >&2
}
log_err() {
	ts=$(log_ts)
	echo -e "${ts} ${RED}[ERROR]${RESET} $*" >&2
}
log_debug() {
	if [[ ${VERBOSE} == true ]]; then
		ts=$(log_ts)
		echo -e "${ts} ${DIM}[DEBUG]${RESET} $*"
	fi
}

usage() {
	cat <<EOF
${SCRIPT_NAME} v${VERSION}

Usage: ${SCRIPT_NAME} --config <FILENAME.json> [options]

Options:
	-c, --config <filename>   Filename in experiments-configurations/ (e.g., csnn-faces.json)
	-p, --phases <list>       Comma-separated: instantiate,prepare,delegate,collect
	--dry-run                 Print commands without executing
	--verbose                 Enable debug logs
	--continue-on-error       Continue remaining phases if one fails
	--manual                  Force manual machine instantiation script
	--log-dir <dir>           Custom directory for logs (default: experiments-runner/logs/<ts>)
	--no-color                Disable colored output
	--no-live-logs            Disable live streaming (logs still written)
	-h, --help                Show help
	--version                 Print version
EOF
}

on_error() {
	local exit_code=$?
	log_err "Failed at line ${BASH_LINENO[0]} in ${BASH_SOURCE[1]:-${SCRIPT_NAME}}: ${BASH_COMMAND}"
	exit "${exit_code}"
}
trap on_error ERR

# Parse arguments
while [[ $# -gt 0 ]]; do
	case "$1" in
		-c | --config)
			CONFIG_FILE_NAME="$2"
			shift 2
			;;
		-p | --phases)
			REQUESTED_PHASES="$2"
			shift 2
			;;
		--dry-run)
			DRY_RUN=true
			shift
			;;
		--verbose)
			VERBOSE=true
			shift
			;;
		--continue-on-error)
			CONTINUE_ON_ERROR=true
			shift
			;;
		--manual)
			FORCE_MANUAL_INSTANTIATION=true
			shift
			;;
		--log-dir)
			LOG_DIR="$2"
			shift 2
			;;
		--no-color)
			NO_COLOR=true
			shift
			;;
		--no-live-logs)
			LIVE_LOGS=false
			shift
			;;
		--version)
			echo "${VERSION}"
			exit 0
			;;
		-h | --help)
			usage
			exit 0
			;;
		*)
			log_err "Unknown argument: $1"
			usage
			exit 2
			;;
	esac
done

# Re-evaluate colors
if [[ -t 1 ]] && [[ ${NO_COLOR} == "false" ]]; then
	RED="\033[31m"
	GREEN="\033[32m"
	YELLOW="\033[33m"
	# ...existing code...
	DIM="\033[2m"
	BOLD="\033[1m"
	RESET="\033[0m"
else
	RED=""
	GREEN=""
	YELLOW=""
	DIM=""
	BOLD=""
	RESET=""
fi

require_cmd() { command -v "$1" >/dev/null 2>&1 || {
	log_err "Required command not found: $1"
	exit 2
}; }

check_dependencies() {
	require_cmd bash
	require_cmd ssh
	require_cmd scp
	if ! command -v jq >/dev/null 2>&1; then
		log_err "jq is required; please install it."
		exit 2
	fi
}

check_dependencies

# Resolve config
CONFIG_JSON="${CONFIG_DIR_ABS}/${CONFIG_FILE_NAME}"
[[ -f ${CONFIG_JSON} ]] || {
	log_err "Config file not found in ${CONFIG_DIR_ABS}: ${CONFIG_FILE_NAME}"
	exit 2
}

TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
if [[ -z ${LOG_DIR} ]]; then
	LOG_DIR="${SCRIPT_DIR}/logs/${TIMESTAMP}"
fi
mkdir -p "${LOG_DIR}"
ln -sfn "${LOG_DIR}" "${SCRIPT_DIR}/logs/last-run"

phase_log() { echo "${LOG_DIR}/$1"; }

BIN_DIR="${SCRIPT_DIR}/bin"
INST_AUTO="${BIN_DIR}/machine-instantiator/automatic-machine-start.sh"
INST_MAN="${BIN_DIR}/machine-instantiator/manual-machine-start.sh"
PREPARE_SCRIPT="${BIN_DIR}/project-preparation/prepare-remote-structure.sh"
DELEGATOR_SCRIPT="${BIN_DIR}/experiments-delegator/on-fe/experiments-delegator.sh"
COLLECT_ONM_SCRIPT="${BIN_DIR}/experiments-collector/on-machine/csnn_collection.sh"

run_step() {
	local title="$1"
	shift
	local log_file="$1"
	shift
	local -a cmd=("$@")
	log_info "==> ${title}"
	log_debug "Command: ${cmd[*]}"
	local start_ts end_ts
	start_ts=$(date +%s)
	if [[ ${DRY_RUN} == true ]]; then
		echo "[DRY-RUN] ${cmd[*]}" | tee -a "${log_file}"
		return 0
	fi
	if [[ ${LIVE_LOGS} == true ]]; then
		("${cmd[@]}" 2>&1 | tee -a "${log_file}")
	else
		("${cmd[@]}" >>"${log_file}" 2>&1)
	fi
	end_ts=$(date +%s)
	log_info "<== ${title} completed in $((end_ts - start_ts))s"
}

# Parse JSON config with jq
json_or_empty() { jq -er "$1 // empty" "${CONFIG_JSON}" 2>/dev/null || true; }
json_required() { jq -er "$1" "${CONFIG_JSON}"; }

# Manual vs automatic compatibility handling
IS_MANUAL=""
if jq -e '.machine_setup.is_machine_instantiator_manual' "${CONFIG_JSON}" >/dev/null 2>&1; then
	IS_MANUAL="$(json_required '.machine_setup.is_machine_instantiator_manual | if type=="boolean" then . else ("Invalid type" | halt_error(2)) end')"
else
	if jq -e '.machine_setup.is_machine_instantiator_automatic' "${CONFIG_JSON}" >/dev/null 2>&1; then
		log_warn "Deprecated key is_machine_instantiator_automatic detected; inferring manual = !automatic"
		auto="$(json_required '.machine_setup.is_machine_instantiator_automatic')"
		if [[ ${auto} == "true" ]]; then IS_MANUAL=false; else IS_MANUAL=true; fi
	else
		log_warn "No instantiator mode specified; defaulting to manual"
		IS_MANUAL=true
	fi
fi

IMAGE_TO_USE="$(json_or_empty '.machine_setup.image_to_use')"
OS_TYPE="$(json_required '.machine_setup.os_distribution_type')"
PKG_LIST_FILE="$(json_required '.machine_setup.list_of_needed_libraries')"

PARAMS_FILE="$(json_required '.running_experiments.on_fe.to_do_parameters_list_path')"
EXEC_CMD="$(json_required '.running_experiments.on_machine.execute_command')"
FULL_PATH="$(json_required '.running_experiments.on_machine.full_path_to_executable')"
PARALLEL_N="$(json_required '.running_experiments.number_of_experiments_to_run_in_parallel_on_machine')"
COLLECTION_JSON="$(jq -c '.running_experiments.experiments_collection' "${CONFIG_JSON}")"

log_info "${BOLD}SwiftDeploy-G5K — Experiments Runner${RESET}"
log_info "Config: ${CONFIG_JSON} (name: ${CONFIG_FILE_NAME})"
log_info "Phases: ${REQUESTED_PHASES} | Dry-run: ${DRY_RUN} | Verbose: ${VERBOSE}"
log_info "Logs: ${LOG_DIR}"
log_info "Mode: manual=${IS_MANUAL} | Image: ${IMAGE_TO_USE:-n/a} | OS type: ${OS_TYPE}"

phase_instantiate() {
	local script
	if [[ ${FORCE_MANUAL_INSTANTIATION} == true || ${IS_MANUAL} == "true" ]]; then
		script="${INST_MAN}"
	else
		script="${INST_AUTO}"
	fi
	if [[ ! -x ${script} ]]; then
		log_err "Instantiation script not executable: ${script}"
		return 2
	fi
	local step_cmd
	step_cmd=(bash "${script}")
	local rc
	# shellcheck disable=SC2312
	run_step "Phase 1/4: Machine instantiation" "$(phase_log 01-instantiate.log)" "${step_cmd[@]}"
	rc=$?
	if [[ ${rc} -ne 0 ]]; then
		log_err "Phase 1/4 failed with code ${rc}"
	fi
	return "${rc}"
}

phase_prepare() {
	if [[ ! -x ${PREPARE_SCRIPT} ]]; then
		log_err "Preparation script not executable: ${PREPARE_SCRIPT}"
		return 2
	fi
	local step_cmd
	step_cmd=(bash "${PREPARE_SCRIPT}"
		--config "${CONFIG_JSON}" --os-type "${OS_TYPE}" --full-path "${FULL_PATH}" --packages-file "${PKG_LIST_FILE}" ${DRY_RUN:+--dry-run})
	local rc
	# shellcheck disable=SC2312
	run_step "Phase 2/4: Project preparation" "$(phase_log 02-prepare.log)" "${step_cmd[@]}"
	rc=$?
	if [[ ${rc} -ne 0 ]]; then
		log_err "Phase 2/4 failed with code ${rc}"
	fi
	return "${rc}"
}

phase_delegate() {
	if [[ ! -x ${DELEGATOR_SCRIPT} ]]; then
		log_err "Delegator script not executable: ${DELEGATOR_SCRIPT}"
		return 2
	fi
	local step_cmd
	step_cmd=(bash "${DELEGATOR_SCRIPT}"
		--parallel "${PARALLEL_N}" --execute-command "${EXEC_CMD}" --full-path "${FULL_PATH}"
		--params-file "${PARAMS_FILE}" --collection-json "${COLLECTION_JSON}" ${DRY_RUN:+--dry-run})
	local rc
	# shellcheck disable=SC2312
	run_step "Phase 3/4: Experiment delegation" "$(phase_log 03-delegate.log)" "${step_cmd[@]}"
	rc=$?
	if [[ ${rc} -ne 0 ]]; then
		log_err "Phase 3/4 failed with code ${rc}"
	fi
	return "${rc}"
}

phase_collect() {
	if [[ -z ${COLLECTION_JSON} || ${COLLECTION_JSON} == "null" ]]; then
		log_info "Phase 4/4: Results collection — no-op (empty collection block)"
		return 0
	fi
	if [[ ! -x ${COLLECT_ONM_SCRIPT} ]]; then
		log_warn "Collector script not found: ${COLLECT_ONM_SCRIPT}; skipping collection"
		return 0
	fi
	# Extract paths if present; tolerate missing keys per TEMPLATE
	local machine_path fe_path
	machine_path="$(jq -r '.path_to_saved_experiment_results_on_machine // empty' <<<"${COLLECTION_JSON}")"
	fe_path="$(jq -r '.path_to_save_experiment_results_on_fe // empty' <<<"${COLLECTION_JSON}")"
	local step_cmd
	step_cmd=(bash "${COLLECT_ONM_SCRIPT}"
		${machine_path:+--machine-path "${machine_path}"} ${fe_path:+--fe-path "${fe_path}"} ${DRY_RUN:+--dry-run})
	local rc
	# shellcheck disable=SC2312
	run_step "Phase 4/4: Results collection" "$(phase_log 04-collect.log)" "${step_cmd[@]}"
	rc=$?
	if [[ ${rc} -ne 0 ]]; then
		log_err "Phase 4/4 failed with code ${rc}"
	fi
	return "${rc}"
}

# Execute requested phases
IFS="," read -r -a PHASES <<<"${REQUESTED_PHASES,,}"
phase_status=0
for p in "${PHASES[@]}"; do
	case "${p}" in
		instantiate)
			phase_instantiate
			rc=$?
			if [[ ${rc} -ne 0 ]]; then
				phase_status=${rc}
				log_err "Phase 'instantiate' failed (${phase_status})"
				${CONTINUE_ON_ERROR} || exit "${phase_status}"
			fi
			;;
		prepare)
			phase_prepare
			rc=$?
			if [[ ${rc} -ne 0 ]]; then
				phase_status=${rc}
				log_err "Phase 'prepare' failed (${phase_status})"
				${CONTINUE_ON_ERROR} || exit "${phase_status}"
			fi
			;;
		delegate)
			phase_delegate
			rc=$?
			if [[ ${rc} -ne 0 ]]; then
				phase_status=${rc}
				log_err "Phase 'delegate' failed (${phase_status})"
				${CONTINUE_ON_ERROR} || exit "${phase_status}"
			fi
			;;
		collect)
			phase_collect
			rc=$?
			if [[ ${rc} -ne 0 ]]; then
				phase_status=${rc}
				log_err "Phase 'collect' failed (${phase_status})"
				${CONTINUE_ON_ERROR} || exit "${phase_status}"
			fi
			;;
		"") ;;
		*) log_warn "Unknown phase '${p}', skipping" ;;
	esac
done

log_info "All requested phases completed."
