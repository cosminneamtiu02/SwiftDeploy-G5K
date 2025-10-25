#!/usr/bin/env bash
# shellcheck shell=bash
# shellcheck source-path=../../common
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNTIME_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
COMMON_DIR="${RUNTIME_DIR}/common"

# shellcheck source=experiments-runner/runtime/common/environment.sh
source "${COMMON_DIR}/environment.sh"
runner_env::bootstrap

runner_env::require_cmd jq
runner_env::require_cmd base64

STATE_HEADER=$'# Selection state file\n# shell formatted key=value entries\n'

usage() {
	cat <<'EOF'
Usage:
  select_batch.sh run --config <config-path> --state-file <state-file>
  select_batch.sh finalize --state-file <state-file> --status <success|failure>
EOF
}

resolve_params_file() {
	local params_path="${1:-}"
	if [[ ${params_path} == /* ]]; then
		printf '%s\n' "${params_path}"
	else
		printf '%s\n' "${RUNNER_ROOT}/params/${params_path}"
	fi
}

write_state_file() {
	local state_file="${1:-}"
	shift
	{
		printf '%s' "${STATE_HEADER}"
		printf 'BATCH_SELECTED=%s\n' "$1"
		shift
		while (($# > 0)); do
			printf '%s\n' "$1"
			shift
		done
	} >"${state_file}"
}

refresh_done_snapshot() {
	local done_file="${1:-}"
	local backup_path
	backup_path="${done_file}.bak.$(date +%s).$$"
	cp -f "${done_file}" "${backup_path}" 2>/dev/null || true
	printf '%s\n' "${backup_path}"
}

persist_selected_lines() {
	local params_dir="${1:-}"
	shift
	local -a selected=("$@")
	local selected_file
	selected_file=$(mktemp "${params_dir}/selected_batch.XXXXXX")
	{
		for line in "${selected[@]}"; do
			printf '%s\n' "${line}"
		done
	} >"${selected_file}"
	printf '%s\n' "${selected_file}"
}

phase_run() {
	local config_path=""
	local state_file=""
	while [[ $# -gt 0 ]]; do
		case "$1" in
			--config)
				config_path="$2"
				shift 2
				;;
			--state-file)
				state_file="$2"
				shift 2
				;;
			*)
				log_error "select_batch.sh run: unknown argument $1"
				usage
				exit 1
				;;
		esac
	done
	if [[ -z ${config_path} || -z ${state_file} ]]; then
		die 'select_batch.sh run requires --config and --state-file.'
	fi

	local params_rel
	params_rel=$(jq -r '.running_experiments.on_fe.to_do_parameters_list_path // empty' "${config_path}")
	if [[ -z ${params_rel} ]]; then
		die 'Config missing .running_experiments.on_fe.to_do_parameters_list_path'
	fi

	local parallel_count
	parallel_count=$(jq -r '.running_experiments.number_of_experiments_to_run_in_parallel_on_machine // 1' "${config_path}")
	if [[ ! ${parallel_count} =~ ^[0-9]+$ ]]; then
		die 'Parallel count must be numeric.'
	fi

	local params_file
	params_file=$(resolve_params_file "${params_rel}")
	if [[ ! -f ${params_file} ]]; then
		die "Parameters list not found on FE: ${params_file}"
	fi

	local params_dir
	params_dir="$(dirname "${params_file}")"
	local done_file
	done_file="${params_dir}/done.txt"

	local -a todo_lines=()
	local todo_output=""
	todo_output=$(grep -v '^[[:space:]]*$' "${params_file}" || true)
	if [[ -n ${todo_output} ]]; then
		mapfile -t todo_lines <<<"${todo_output}"
	fi
	if [[ ! -f ${done_file} ]]; then
		: >"${done_file}"
	fi
	local -a done_lines=()
	local done_output=""
	done_output=$(grep -v '^[[:space:]]*$' "${done_file}" || true)
	if [[ -n ${done_output} ]]; then
		mapfile -t done_lines <<<"${done_output}"
	fi
	declare -A done_set=()
	local done_line
	for done_line in "${done_lines[@]}"; do
		done_set["${done_line}"]=1
	done

	local -a selected=()
	local todo_line
	for todo_line in "${todo_lines[@]}"; do
		if [[ -z ${done_set["${todo_line}"]+x} ]]; then
			selected+=("${todo_line}")
			if ((${#selected[@]} >= parallel_count)); then
				break
			fi
		fi
	done

	if ((${#selected[@]} == 0)); then
		log_warn 'Nothing left to run. Cleaning up done.txt and stopping.'
		rm -f "${done_file}" 2>/dev/null || true
		write_state_file "${state_file}" 0 \
			"DONE_FILE=${done_file}" \
			"DONE_BACKUP=" \
			"SELECTED_LINES_FILE=" \
			"SELECTED_LINES_B64="
		log_success 'Stopped before execution: no pending parameters.'
		exit 0
	fi

	log_step "Selected parameters for this run (n=${#selected[@]}):"
	for todo_line in "${selected[@]}"; do
		log_info "[FE] ${todo_line}"
	done

	local backup_file
	backup_file=$(refresh_done_snapshot "${done_file}")

	{
		for todo_line in "${selected[@]}"; do
			printf '%s\n' "${todo_line}"
		done
	} >>"${done_file}"

	local selected_file
	selected_file=$(persist_selected_lines "${params_dir}" "${selected[@]}")

	local selected_b64
	selected_b64=$(printf '%s\n' "${selected[@]}" | base64 -w0)
	local selected_batch_value
	selected_batch_value=$(printf '%s\n' "${selected[@]}")
	export SELECTED_BATCH="${selected_batch_value}"

	write_state_file "${state_file}" 1 \
		"DONE_FILE=${done_file}" \
		"DONE_BACKUP=${backup_file}" \
		"SELECTED_LINES_FILE=${selected_file}" \
		"SELECTED_LINES_B64=${selected_b64}" \
		"SELECTED_COUNT=${#selected[@]}"

	log_info "Selection state stored at ${state_file}"
}

revert_done_batch() {
	local done_file="${1:-}"
	local backup_file="${2:-}"
	local selected_file="${3:-}"
	if [[ -f ${backup_file} ]]; then
		mv -f "${backup_file}" "${done_file}" 2>/dev/null || true
		log_info "Restored ${done_file} from snapshot."
		return
	fi
	if [[ ! -f ${selected_file} ]]; then
		return
	fi
	local tmp_file
	tmp_file="${done_file}.tmp.$$"
	awk 'NR==FNR{c[$0]++;next}{if(c[$0]>0){c[$0]--;next}print}' "${selected_file}" "${done_file}" >"${tmp_file}" || true
	mv "${tmp_file}" "${done_file}" 2>/dev/null || true
}

phase_finalize() {
	local state_file=""
	local status='failure'
	while [[ $# -gt 0 ]]; do
		case "$1" in
			--state-file)
				state_file="$2"
				shift 2
				;;
			--status)
				status="$2"
				shift 2
				;;
			*)
				log_error "select_batch.sh finalize: unknown argument $1"
				usage
				exit 1
				;;
		esac
	done
	if [[ -z ${state_file} ]]; then
		die 'select_batch.sh finalize requires --state-file.'
	fi
	if [[ ! -f ${state_file} ]]; then
		die "select_batch.sh finalize missing state file: ${state_file}"
	fi

	# shellcheck source=/dev/null
	source "${state_file}"
	: "${BATCH_SELECTED:=0}"
	: "${DONE_FILE:=}"
	: "${DONE_BACKUP:=}"
	: "${SELECTED_LINES_FILE:=}"
	if [[ ${BATCH_SELECTED} -ne 1 ]]; then
		log_debug 'select_batch.sh finalize: no batch selected; nothing to do.'
		return 0
	fi

	if [[ ${status} == 'success' ]]; then
		rm -f "${DONE_BACKUP}" 2>/dev/null || true
		log_info 'select_batch.sh finalize: success acknowledged.'
	else
		log_warn 'select_batch.sh finalize: reverting done.txt entries.'
		revert_done_batch "${DONE_FILE}" "${DONE_BACKUP}" "${SELECTED_LINES_FILE}"
	fi
}

main() {
	local subcommand="${1:-}"
	if [[ -z ${subcommand} ]]; then
		usage
		exit 1
	fi
	shift || true
	case "${subcommand}" in
		run)
			phase_run "$@"
			;;
		finalize)
			phase_finalize "$@"
			;;
		*)
			usage
			exit 1
			;;
	esac
}

main "$@"
