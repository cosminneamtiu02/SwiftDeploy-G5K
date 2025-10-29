#!/usr/bin/env bash
# shellcheck shell=bash

if [[ ${BASH_SOURCE[0]} == "${0}" ]]; then
	printf 'artifact-collector-logging.sh is a library and must be sourced.\n' >&2
	exit 1
fi

COLLECTOR_LOGGING_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -z ${PIPELINE_ENV_BOOTSTRAPPED:-} ]]; then
	# shellcheck source=experiments-runner/runtime/common/pipeline-environment.sh
	source "${COLLECTOR_LOGGING_DIR}/../pipeline-environment.sh"
fi
pipeline_env::bootstrap

pipeline_artifact_logging::log_transfer_intro() {
	local transfer_idx="${1:-}"
	local look_into="${2:-}"
	local labels_name="$3"
	local patterns_name="$4"
	declare -n labels_ref="${labels_name}"
	declare -n patterns_ref="${patterns_name}"
	log_info "Transfer ${transfer_idx}: patterns used (raw) = ${patterns_ref[*]} (labels: ${labels_ref[*]})"
	log_info "Transfer ${transfer_idx}: lookup path (node) = ${look_into}"
}

pipeline_artifact_logging::log_prescan() {
	local transfer_idx="${1:-}"
	local prescan_output="${2:-}"
	local patterns_name="$3"
	declare -n patterns_ref="${patterns_name}"
	local look_into="${4:-}"
	local node="${5:-}"
	if [[ -z ${prescan_output} ]]; then
		return
	fi
	if grep -q '^PRE:missing=1' <<<"${prescan_output}"; then
		local host
		host=$(ssh -o StrictHostKeyChecking=no "root@${node}" 'hostname' 2>/dev/null || true)
		local dir_var
		dir_var=$(sed -n 's/^PRE:dir_var=\(.*\)$/\1/p;q' <<<"${prescan_output}")
		local stat_line
		stat_line=$(ssh -o StrictHostKeyChecking=no "root@${node}" "ls -ld -- '${look_into}' 2>/dev/null || echo 'ls_failed'" 2>/dev/null || true)
		if [[ -n ${dir_var} ]]; then
			log_info "Transfer ${transfer_idx} prescan saw dir_var='${dir_var}'"
		fi
		log_info "Transfer ${transfer_idx} debug: node='${host:-?}', look_into='${look_into}', ls='${stat_line}'"
		if [[ ${stat_line} == ls_failed* ]]; then
			die "Transfer ${transfer_idx} configuration error: source directory does not exist on node: ${look_into}"
		else
			log_warn "Transfer ${transfer_idx}: prescan reported missing but direct ls confirms directory exists; continuing with enumeration guarded by explicit cd."
		fi
		return
	fi
	local pattern
	for pattern in "${patterns_ref[@]}"; do
		local escaped
		escaped=$(printf '%s' "${pattern}" | sed 's/[\\.*\[\]\^$]/\\&/g')
		local count
		count=$(sed -n "s/^PREPAT:count:\"${escaped}\":\([0-9]\+\)$/\1/p" <<<"${prescan_output}")
		count=${count:-0}
		if ((count == 0)); then
			continue
		fi
		log_info "SRC matches for pattern '${pattern}' (${count}):"
		local match_lines
		match_lines=$(sed -n "s/^PREPAT:match:\"${escaped}\":\"\(.*\)\"/\1/p" <<<"${prescan_output}")
		while IFS= read -r match; do
			[[ -n ${match} ]] && log_info "  ${match}"
		done <<<"${match_lines}"
	done
}

pipeline_artifact_logging::log_deep_diag() {
	local transfer_idx="${1:-}"
	local diag_output="${2:-}"
	local patterns_name="$3"
	declare -n patterns_ref="${patterns_name}"
	local look_into="${4:-}"
	if [[ -z ${diag_output} ]]; then
		return
	fi
	local clean
	clean=$(tr -d '\r' <<<"${diag_output}")
	local entries
	entries=$(sed -n 's/^DIAG:entries_count="\([0-9]\+\)".*/\1/p;q' <<<"${clean}")
	local plain
	plain=$(sed -n 's/^DIAG:plain_file_count="\([0-9]\+\)".*/\1/p;q' <<<"${clean}")
	local nullglob_state
	nullglob_state=$(sed -n 's/^shopt -\([su]\) nullglob$/\1/p;q' <<<"${clean}")
	case "${nullglob_state}" in
		s) nullglob_state='on' ;;
		u) nullglob_state='off' ;;
		*) nullglob_state='unknown' ;;
	esac
	log_info "Transfer ${transfer_idx} diagnosis: dir_entries=${entries:-0}, regular_files=${plain:-0}, nullglob=${nullglob_state}"
	local pattern
	for pattern in "${patterns_ref[@]}"; do
		local escaped
		escaped=$(printf '%s' "${pattern}" | sed 's/[\\.*\[\]\^$]/\\&/g')
		local count
		count=$(sed -n "s/^DIAG:pattern_count:\"${escaped}\":count=\"\([0-9]\+\)\".*/\1/p;q" <<<"${clean}")
		count=${count:-0}
		log_info "Transfer ${transfer_idx} per-pattern matches '${pattern}': ${count}"
	done
	if [[ ${plain:-0} -gt 0 ]]; then
		local sample_lines
		sample_lines=$(awk -F: 'BEGIN{count=0} /^DIAG:file_meta:/{size=$4; sub(/^size="/, "", size); sub(/"$/, "", size); print $3" (size="size")"; count++; if(count>=5) exit}' <<<"${clean}")
		if [[ -n ${sample_lines} ]]; then
			local sample_array=()
			while IFS= read -r sample_line; do
				[[ -n ${sample_line} ]] && sample_array+=("${sample_line}")
			done <<<"${sample_lines}"
			if ((${#sample_array[@]} > 0)); then
				local sample=""
				local idx
				for idx in "${!sample_array[@]}"; do
					if ((idx > 0)); then
						sample+="; "
					fi
					sample+="${sample_array[idx]}"
				done
				log_info "Transfer ${transfer_idx} sample files: ${sample}"
			fi
		fi
	fi
	local match_total
	match_total=$(grep -c '^DIAG:match:' <<<"${clean}" || true)
	if [[ ${entries:-0} -eq 0 ]]; then
		log_info "Transfer ${transfer_idx} classification: dir_empty"
	elif [[ ${plain:-0} -eq 0 && ${entries:-0} -gt 0 ]]; then
		log_info "Transfer ${transfer_idx} classification: only_directories"
	elif [[ ${match_total} -eq 0 && ${plain:-0} -gt 0 ]]; then
		log_info "Transfer ${transfer_idx} classification: patterns_mismatch"
	else
		log_info "Transfer ${transfer_idx} classification: unknown"
	fi
	for pattern in "${patterns_ref[@]}"; do
		if [[ ${pattern} != *[*?[]* ]]; then
			log_info "Hint: pattern '${pattern}' is treated as a literal (no wildcards)."
		fi
		if [[ ${pattern} == */* ]]; then
			log_info "Note: pattern '${pattern}' includes a slash; collection is non-recursive."
		fi
	done
}

pipeline_artifact_logging::log_locator() {
	local transfer_idx="${1:-}"
	local locator_output="${2:-}"
	if [[ -z ${locator_output} ]]; then
		return
	fi
	log_info 'Locator hints BEGIN'
	local locator_lines
	locator_lines=$(sed -n '1,200p' <<<"${locator_output}")
	while IFS= read -r line; do
		[[ -n ${line} ]] && log_info "${line}"
	done <<<"${locator_lines}"
	log_info 'Locator hints END'
}
