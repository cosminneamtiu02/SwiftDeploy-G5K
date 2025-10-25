#!/usr/bin/env bash
# shellcheck shell=bash

if [[ ${BASH_SOURCE[0]} == "${0}" ]]; then
	printf 'collector.sh is a library and must be sourced.\n' >&2
	exit 1
fi

collector::__set_scalar() {
	local target="$1"
	local value="${2-}"
	printf -v "${target}" '%s' "${value}"
}

collector::__set_array() {
	local target="$1"
	shift || true
	local __collector_cmd
	printf -v __collector_cmd '%s=()' "${target}"
	eval "${__collector_cmd}"
	local element
	for element in "$@"; do
		printf -v __collector_cmd '%s+=(%q)' "${target}" "${element}"
		eval "${__collector_cmd}"
	done
}

collector::__assoc_clear() {
	local target="$1"
	local __collector_cmd
	printf -v __collector_cmd '%s=()' "${target}"
	eval "${__collector_cmd}"
}

collector::__assoc_set() {
	local target="$1"
	local key="$2"
	local value="$3"
	local __collector_cmd
	printf -v __collector_cmd '%s[%q]=%q' "${target}" "${key}" "${value}"
	eval "${__collector_cmd}"
}

collector::load_config() {
	local config_path="${1:-}"
	local base_path_var="$2"
	local rules_var="$3"
	local transfers_var="$4"
	local base_path
	local rules_json
	local transfers_json
	base_path=$(jq -r '.running_experiments.experiments_collection.base_path // empty' "${config_path}")
	collector::__set_scalar "${base_path_var}" "${base_path}"
	rules_json=$(jq -c '.running_experiments.experiments_collection.lookup_rules // []' "${config_path}")
	collector::__set_scalar "${rules_var}" "${rules_json}"
	transfers_json=$(jq -c '.running_experiments.experiments_collection.ftransfers // []' "${config_path}")
	collector::__set_scalar "${transfers_var}" "${transfers_json}"
}

collector::validate_config() {
	local base_path="${1:-}"
	local rules_json="${2:-}"
	local transfers_json="${3:-}"
	if [[ -z ${base_path} ]]; then
		return 0
	fi
	if [[ ${base_path} =~ [/\\] ]]; then
		die "Invalid base_path '${base_path}': must be a simple folder name without slashes"
	fi
	local rules_count
	rules_count=$(jq 'length' <<<"${rules_json}")
	declare -A labels=()
	local i
	for ((i = 0; i < rules_count; i++)); do
		local entry
		local label
		local pattern
		entry=$(jq -c ".[${i}]" <<<"${rules_json}")
		label=$(jq -r 'keys[0]' <<<"${entry}")
		pattern=$(jq -r '.[keys[0]]' <<<"${entry}")
		if [[ -z ${label} || -z ${pattern} ]]; then
			die "lookup_rules entry index ${i} has empty label or pattern"
		fi
		if [[ -n ${labels[${label}]:-} ]]; then
			die "Duplicate lookup rule label: ${label}"
		fi
		labels["${label}"]=1
	done
	local transf_count
	transf_count=$(jq 'length' <<<"${transfers_json}")
	for ((i = 0; i < transf_count; i++)); do
		local look_into
		local subfolder
		look_into=$(jq -r ".[${i}].look_into // empty" <<<"${transfers_json}")
		subfolder=$(jq -r ".[${i}].transfer_to_subfolder_of_base_path // empty" <<<"${transfers_json}")
		if [[ -z ${look_into} ]]; then
			die "ftransfers[${i}].look_into missing"
		fi
		if [[ ${look_into} != /* ]]; then
			die "ftransfers[${i}].look_into must be an absolute path"
		fi
		if [[ -z ${subfolder} ]]; then
			die "ftransfers[${i}].transfer_to_subfolder_of_base_path missing"
		fi
		if [[ ${subfolder} =~ [/\\] ]]; then
			die "ftransfers[${i}].transfer_to_subfolder_of_base_path must be simple folder (no slash): '${subfolder}'"
		fi
		local lf_labels=()
		local lf_output=""
		lf_output=$(jq -r ".[${i}].look_for[]?" <<<"${transfers_json}" || true)
		if [[ -n ${lf_output} ]]; then
			mapfile -t lf_labels <<<"${lf_output}"
		fi
		if ((${#lf_labels[@]} == 0)); then
			die "ftransfers[${i}].look_for must list at least one rule label"
		fi
		local lbl
		for lbl in "${lf_labels[@]}"; do
			if [[ -z ${labels[${lbl}]:-} ]]; then
				die "ftransfers[${i}] references unknown rule label: ${lbl}"
			fi
		done
	done
}

collector::build_rule_map() {
	local rules_json="${1:-}"
	local map_var="$2"
	collector::__assoc_clear "${map_var}"
	local rules_count
	rules_count=$(jq 'length' <<<"${rules_json}")
	local i
	for ((i = 0; i < rules_count; i++)); do
		local entry
		local label
		local pattern
		entry=$(jq -c ".[${i}]" <<<"${rules_json}")
		label=$(jq -r 'keys[0]' <<<"${entry}")
		pattern=$(jq -r '.[keys[0]]' <<<"${entry}")
		collector::__assoc_set "${map_var}" "${label}" "${pattern}"
	done
}

collector::transfer_count() {
	local transfers_json="${1:-}"
	jq 'length' <<<"${transfers_json}"
}

collector::get_transfer() {
	local transfers_json="${1:-}"
	local index="${2:-}"
	local look_into_var="$3"
	local subfolder_var="$4"
	local look_for_var="$5"
	local look_into
	local subfolder
	look_into=$(jq -r ".[${index}].look_into" <<<"${transfers_json}")
	collector::__set_scalar "${look_into_var}" "${look_into}"
	subfolder=$(jq -r ".[${index}].transfer_to_subfolder_of_base_path" <<<"${transfers_json}")
	collector::__set_scalar "${subfolder_var}" "${subfolder}"
	local look_for_list=()
	local look_for_output=""
	look_for_output=$(jq -r ".[${index}].look_for[]" <<<"${transfers_json}" || true)
	if [[ -n ${look_for_output} ]]; then
		mapfile -t look_for_list <<<"${look_for_output}"
	fi
	collector::__set_array "${look_for_var}" "${look_for_list[@]}"
}

collector::patterns_from_labels() {
	local rule_map_name="$1"
	local labels_name="$2"
	local patterns_name="$3"
	declare -n rule_map_ref="${rule_map_name}"
	declare -n labels_ref="${labels_name}"
	declare -n patterns_ref="${patterns_name}"
	patterns_ref=()
	local lbl
	for lbl in "${labels_ref[@]}"; do
		local pat
		pat="${rule_map_ref[${lbl}]:-}"
		if [[ -n ${pat} ]]; then
			pat=$(printf '%s' "${pat}" | tr -d '\r' | sed 's/[[:space:]]\+$//' || true)
			patterns_ref+=("${pat}")
		fi
	done
}
