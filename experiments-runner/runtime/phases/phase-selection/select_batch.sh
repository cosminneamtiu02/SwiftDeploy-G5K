#!/usr/bin/env bash
# shellcheck shell=bash

if [[ ${BASH_SOURCE[0]} == "${0}" ]]; then
	printf 'select_batch.sh is a library and must be sourced.\n' >&2
	exit 1
fi

select_batch::resolve_params_file() {
	local params_path="${1:-}"
	if [[ -z ${params_path} ]]; then
		die 'select_batch::resolve_params_file requires a parameters path.'
	fi
	if [[ ${params_path} == /* ]]; then
		printf '%s\n' "${params_path}"
		return 0
	fi
	: "${RUNNER_ROOT:?runner_env::bootstrap must set RUNNER_ROOT}"
	printf '%s\n' "${RUNNER_ROOT}/params/${params_path}"
}

select_batch::pick() {
	local config_path="${1:-}"
	local selected_ref_name="${2:-}"
	local done_file_ref_name="${3:-}"
	local selected_b64_ref_name="${4:-}"

	if [[ -z ${config_path} ]]; then
		die 'select_batch::pick requires a configuration path.'
	fi
	if [[ -z ${selected_ref_name} || -z ${done_file_ref_name} || -z ${selected_b64_ref_name} ]]; then
		die 'select_batch::pick requires output variable names for selected lines, done file, and base64 payload.'
	fi

	declare -n select_batch__selected_ref="${selected_ref_name}"
	declare -n select_batch__done_file_ref="${done_file_ref_name}"
	declare -n select_batch__selected_b64_ref="${selected_b64_ref_name}"

	runner_env::require_cmd jq
	runner_env::require_cmd base64

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
	params_file=$(select_batch::resolve_params_file "${params_rel}")
	if [[ ! -f ${params_file} ]]; then
		die "Parameters list not found on FE: ${params_file}"
	fi

	local params_dir
	params_dir="$(dirname "${params_file}")"
	select_batch__done_file_ref="${params_dir}/done.txt"

	local todo_output
	todo_output=$(grep -v '^[[:space:]]*$' "${params_file}" || true)
	local -a todo_lines=()
	if [[ -n ${todo_output} ]]; then
		mapfile -t todo_lines <<<"${todo_output}"
	fi

	local done_output
	done_output=$(grep -v '^[[:space:]]*$' "${select_batch__done_file_ref}" 2>/dev/null || true)
	local -a done_lines=()
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
		rm -f "${select_batch__done_file_ref}" 2>/dev/null || true
		select_batch__selected_ref=()
		select_batch__selected_b64_ref=""
		return 0
	fi

	log_step "Selected parameters for this run (n=${#selected[@]}):"
	for todo_line in "${selected[@]}"; do
		log_info "[FE] ${todo_line}"
	done

	# shellcheck disable=SC2034
	select_batch__selected_ref=("${selected[@]}")
	# shellcheck disable=SC2034
	select_batch__selected_b64_ref=$(printf '%s\n' "${selected[@]}" | base64 -w0)
	return 0
}

select_batch::remove_entries_from_done() {
	local done_file="${1:-}"
	shift || true
	if [[ -z ${done_file} || ! -e ${done_file} ]]; then
		return 0
	fi
	if (($# == 0)); then
		return 0
	fi

	declare -A removal_counts=()
	local entry
	for entry in "$@"; do
		((removal_counts["${entry}"]++))
	done

	local done_dir
	done_dir="$(dirname "${done_file}")"
	mkdir -p "${done_dir}"
	local tmp_file
	tmp_file=$(mktemp -p "${done_dir}" done.rollback.XXXXXX)

	# Rebuild done.txt without the selected entries
	if [[ -f ${done_file} ]]; then
		while IFS= read -r line || [[ -n ${line} ]]; do
			if [[ -n ${removal_counts["${line}"]:-} && ${removal_counts["${line}"]} -gt 0 ]]; then
				((removal_counts["${line}"]--))
				continue
			fi
			printf '%s\n' "${line}"
		done <"${done_file}" >"${tmp_file}"
	else
		: >"${tmp_file}"
	fi

	mv "${tmp_file}" "${done_file}"
	if [[ ! -s ${done_file} ]]; then
		rm -f "${done_file}" 2>/dev/null || true
	fi
	log_info "Rolled back $# parameter(s) in ${done_file}."
	return 0
}
