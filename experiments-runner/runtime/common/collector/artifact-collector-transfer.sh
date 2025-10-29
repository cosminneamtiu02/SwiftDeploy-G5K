#!/usr/bin/env bash
# shellcheck shell=bash

if [[ ${BASH_SOURCE[0]} == "${0}" ]]; then
	printf 'artifact-collector-transfer.sh is a library and must be sourced.\n' >&2
	exit 1
fi

COLLECTOR_TRANSFER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -z ${PIPELINE_ENV_BOOTSTRAPPED:-} ]]; then
	# shellcheck source=experiments-runner/runtime/common/pipeline-environment.sh
	source "${COLLECTOR_TRANSFER_DIR}/../pipeline-environment.sh"
fi

pipeline_artifact_transfer::join_patterns() {
	local patterns_ref_name="$1"
	declare -n patterns_ref="${patterns_ref_name}"
	local dest_var="$2"
	local joined=""
	local pattern
	for pattern in "${patterns_ref[@]}"; do
		if [[ -n ${pattern} ]]; then
			joined+="${pattern} "
		fi
	done
	printf -v "${dest_var}" '%s' "${joined% }"
}

pipeline_artifact_transfer::run_prescan() {
	local transfer_idx="${1:-}"
	local node="${2:-}"
	local bundle_dir="${3:-}"
	local look_into="${4:-}"
	local patterns_ref_name="$5"
	declare -n patterns_ref="${patterns_ref_name}"
	local output_var="$6"
	local patterns_joined=""
	pipeline_artifact_transfer::join_patterns "${patterns_ref_name}" patterns_joined
	local prescan_tmp=""
	prescan_tmp=$(mktemp) || return 1
	local rc=0
	local run_rc=0
	set +e
	pipeline_remote::run_script "${node}" "${bundle_dir}/pre-scan.sh" \
		--env "LOOK_INTO_REMOTE=${look_into}" \
		--env "PATTERNS_GLOBS=${patterns_joined}" >"${prescan_tmp}"
	run_rc=$?
	set -e
	if ((run_rc == 0)); then
		if [[ -n ${output_var} ]]; then
			printf -v "${output_var}" '%s' "$(<"${prescan_tmp}")"
		fi
	else
		rc=${run_rc}
	fi
	rm -f "${prescan_tmp}"
	return "${rc}"
}

pipeline_artifact_transfer::run_quickcheck() {
	local transfer_idx="${1:-}"
	local node="${2:-}"
	local look_into="${3:-}"
	local patterns_ref_name="$4"
	declare -n patterns_ref="${patterns_ref_name}"
	local total_var="$5"
	local total=0
	local pattern
	for pattern in "${patterns_ref[@]}"; do
		local count
		count=$(ssh -o StrictHostKeyChecking=no "root@${node}" DIR_REMOTE="${look_into}" PAT_TOKEN="${pattern}" bash -lc $'cd "$DIR_REMOTE" 2>/dev/null || exit 0; compgen -G "$PAT_TOKEN" 2>/dev/null | wc -l' 2>/dev/null || true)
		count=${count:-0}
		total=$((total + count))
		if [[ ${LOG_LEVEL:-info} == debug && ${count} -gt 0 ]]; then
			local sample
			sample=$(ssh -o StrictHostKeyChecking=no "root@${node}" DIR_REMOTE="${look_into}" PAT_TOKEN="${pattern}" bash -lc $'cd "$DIR_REMOTE" 2>/dev/null || exit 0; compgen -G "$PAT_TOKEN" 2>/dev/null | head -5' 2>/dev/null || true)
			while IFS= read -r line; do
				[[ -n ${line} ]] && log_debug "quickcheck sample: ${line}"
			done <<<"${sample}"
		fi
	done
	if [[ -n ${total_var} ]]; then
		printf -v "${total_var}" '%s' "${total}"
	fi
}

pipeline_artifact_transfer::run_enumerate() {
	local node="${1:-}"
	local bundle_dir="${2:-}"
	local look_into="${3:-}"
	local patterns_ref_name="$4"
	declare -n patterns_ref="${patterns_ref_name}"
	local output_var="$5"
	local patterns_joined=""
	pipeline_artifact_transfer::join_patterns "${patterns_ref_name}" patterns_joined
	local tmp_output=""
	tmp_output=$(mktemp) || return 1
	local rc=0
	local run_rc=0
	set +e
	pipeline_remote::run_script "${node}" "${bundle_dir}/enumerate.sh" \
		--env "DIR_REMOTE=${look_into}" \
		--env "PATTERNS_GLOBS=${patterns_joined}" >"${tmp_output}"
	run_rc=$?
	set -e
	if ((run_rc == 0)); then
		if [[ -n ${output_var} ]]; then
			printf -v "${output_var}" '%s' "$(<"${tmp_output}")"
		fi
	else
		rc=${run_rc}
	fi
	rm -f "${tmp_output}"
	return "${rc}"
}

pipeline_artifact_transfer::run_deep_diag() {
	local node="${1:-}"
	local bundle_dir="${2:-}"
	local look_into="${3:-}"
	local patterns_ref_name="$4"
	declare -n patterns_ref="${patterns_ref_name}"
	local output_var="$5"
	local patterns_joined=""
	pipeline_artifact_transfer::join_patterns "${patterns_ref_name}" patterns_joined
	local tmp_output=""
	tmp_output=$(mktemp) || return 1
	local rc=0
	local run_rc=0
	set +e
	pipeline_remote::run_script "${node}" "${bundle_dir}/deep-diag.sh" \
		--env "LOOK_INTO_REMOTE=${look_into}" \
		--env "PATTERNS_GLOBS=${patterns_joined}" >"${tmp_output}"
	run_rc=$?
	set -e
	if ((run_rc == 0)); then
		if [[ -n ${output_var} ]]; then
			printf -v "${output_var}" '%s' "$(<"${tmp_output}")"
		fi
	else
		rc=${run_rc}
	fi
	rm -f "${tmp_output}"
	return "${rc}"
}

pipeline_artifact_transfer::run_locator() {
	local node="${1:-}"
	local bundle_dir="${2:-}"
	local alt_dirs="${3:-}"
	local exec_dir="${4:-}"
	local patterns_ref_name="$5"
	declare -n patterns_ref="${patterns_ref_name}"
	local output_var="$6"
	local patterns_joined=""
	pipeline_artifact_transfer::join_patterns "${patterns_ref_name}" patterns_joined
	local tmp_output=""
	tmp_output=$(mktemp) || return 1
	local rc=0
	local run_rc=0
	set +e
	pipeline_remote::run_script "${node}" "${bundle_dir}/locator.sh" \
		--env "ALT_DIRS=${alt_dirs}" \
		--env "PATTERNS_GLOBS=${patterns_joined}" \
		--env "EXEC_DIR_REMOTE=${exec_dir}" >"${tmp_output}"
	run_rc=$?
	set -e
	if ((run_rc == 0)); then
		if [[ -n ${output_var} ]]; then
			printf -v "${output_var}" '%s' "$(<"${tmp_output}")"
		fi
	else
		rc=${run_rc}
	fi
	rm -f "${tmp_output}"
	return "${rc}"
}

pipeline_artifact_transfer::run_snapshot_copy() {
	local node="${1:-}"
	local bundle_dir="${2:-}"
	local look_into="${3:-}"
	local patterns_ref_name="$4"
	declare -n patterns_ref="${patterns_ref_name}"
	local dest_dir="${5:-}"
	local patterns_joined=""
	pipeline_artifact_transfer::join_patterns patterns_ref patterns_joined
	local snapshot_tmp=""
	snapshot_tmp=$(mktemp) || return 1
	local rc=0
	local run_rc=0
	set +e
	pipeline_remote::run_script "${node}" "${bundle_dir}/snapshot.sh" \
		--env "DIR_REMOTE=${look_into}" \
		--env "PATTERNS_GLOBS=${patterns_joined}" >"${snapshot_tmp}"
	run_rc=$?
	set -e
	if ((run_rc == 0)); then
		if ! tar -xzf "${snapshot_tmp}" -C "${dest_dir}"; then
			rc=$?
		fi
	else
		rc=${run_rc}
	fi
	rm -f "${snapshot_tmp}"
	return "${rc}"
}

pipeline_artifact_transfer::handle_zero_matches() {
	local transfer_idx="${1:-}"
	local node="${2:-}"
	local look_into="${3:-}"
	local patterns_ref_name="$4"
	declare -n patterns_ref="${patterns_ref_name}"
	local bundle_dir="${5:-}"
	local exec_dir="${6:-}"
	local dest_dir="${7:-}"
	if ssh -o StrictHostKeyChecking=no "root@${node}" "test -d '${look_into}'" 2>/dev/null; then
		local quick_sum=0
		pipeline_artifact_transfer::run_quickcheck "${transfer_idx}" "${node}" "${look_into}" "${patterns_ref_name}" quick_sum
		if ((quick_sum > 0)); then
			log_info "Transfer ${transfer_idx} hint: likely_race_condition (quickcheck/recheck>0 but enumeration=0)."
			local snapshot_rc=0
			set +e
			pipeline_artifact_transfer::run_snapshot_copy "${node}" "${bundle_dir}" "${look_into}" "${patterns_ref_name}" "${dest_dir}"
			snapshot_rc=$?
			set -e
			if ((snapshot_rc == 0)); then
				local dest_after
				dest_after=$(find "${dest_dir}" -mindepth 1 -maxdepth 1 -printf '.' 2>/dev/null | wc -c | tr -d '[:space:]' || true)
				log_success "Transfer ${transfer_idx} snapshot copy completed. FE entries now=${dest_after:-0}"
				local snapshot_tmp=""
				snapshot_tmp=$(mktemp) || snapshot_tmp=""
				if [[ -n ${snapshot_tmp} ]]; then
					if find "${dest_dir}" -mindepth 1 -maxdepth 1 -printf '%f\n' 2>/dev/null >"${snapshot_tmp}"; then
						local snapshot_entry
						local snapshot_count=0
						while IFS= read -r snapshot_entry; do
							log_info "FE: ${snapshot_entry}"
							((snapshot_count++))
							if ((snapshot_count >= 10)); then
								break
							fi
						done <"${snapshot_tmp}"
					fi
					rm -f "${snapshot_tmp}"
				fi
				return 0
			fi
			log_info "Transfer ${transfer_idx} snapshot: no files captured. Proceeding with diagnostics."
		fi
		log_warn "Transfer ${transfer_idx}: no files matched in ${look_into} (patterns: ${patterns_ref[*]})"
		local dest_count
		dest_count=$(find "${dest_dir}" -mindepth 1 -maxdepth 1 -printf '.' 2>/dev/null | wc -c | tr -d '[:space:]' || true)
		log_info "Transfer ${transfer_idx} FE destination pre-state: '${dest_dir}' entries=${dest_count:-0}"
		if [[ ${dest_count:-0} -gt 0 ]]; then
			log_info "Transfer ${transfer_idx} FE destination first entries:"
			local prestate_tmp=""
			prestate_tmp=$(mktemp) || prestate_tmp=""
			if [[ -n ${prestate_tmp} ]]; then
				if find "${dest_dir}" -mindepth 1 -maxdepth 1 -printf '%f\n' 2>/dev/null >"${prestate_tmp}"; then
					local pre_entry
					local pre_count=0
					while IFS= read -r pre_entry; do
						log_info "FE: ${pre_entry}"
						((pre_count++))
						if ((pre_count >= 20)); then
							break
						fi
					done <"${prestate_tmp}"
				fi
				rm -f "${prestate_tmp}"
			fi
		fi
		local diag_output=""
		pipeline_artifact_transfer::run_deep_diag "${node}" "${bundle_dir}" "${look_into}" "${patterns_ref_name}" diag_output
		pipeline_artifact_logging::log_deep_diag "${transfer_idx}" "${diag_output}" "${patterns_ref_name}" "${look_into}"
		local alt_dirs=()
		if [[ ${look_into} == */result ]]; then alt_dirs+=("${look_into%/result}/results"); fi
		if [[ ${look_into} == */results ]]; then alt_dirs+=("${look_into%/results}/result"); fi
		alt_dirs+=("${exec_dir%/}/results" "${exec_dir%/}/result")
		local dedup=()
		local candidate
		for candidate in "${alt_dirs[@]}"; do
			if [[ ${candidate} == "${look_into}" ]]; then
				continue
			fi
			local seen=false
			local existing
			for existing in "${dedup[@]}"; do
				if [[ ${candidate} == "${existing}" ]]; then
					seen=true
					break
				fi
			done
			if ! ${seen}; then
				dedup+=("${candidate}")
			fi
		done
		if ((${#dedup[@]} > 0)); then
			local alt_join=""
			local alt
			for alt in "${dedup[@]}"; do
				alt_join+="${alt} "
			done
			local locator_out=""
			pipeline_artifact_transfer::run_locator "${node}" "${bundle_dir}" "${alt_join% }" "${exec_dir}" "${patterns_ref_name}" locator_out
			pipeline_artifact_logging::log_locator "${transfer_idx}" "${locator_out}"
		fi
	else
		die "Transfer ${transfer_idx} configuration error: directory does not exist on node: ${look_into}"
	fi
	return 1
}

pipeline_artifact_transfer::handle_transfer() {
	local transfer_idx="${1:-}"
	local node_name="${2:-}"
	local look_into="${3:-}"
	local dest_dir="${4:-}"
	local bundle_dir="${5:-}"
	local exec_dir="${6:-}"
	local patterns_ref_name="$7"
	declare -n patterns_ref="${patterns_ref_name}"

	local prescan_output=""
	set +e
	pipeline_artifact_transfer::run_prescan "${transfer_idx}" "${node_name}" "${bundle_dir}" "${look_into}" "${patterns_ref_name}" prescan_output
	local prescan_rc=$?
	set -e
	if ((prescan_rc != 0)); then
		log_warn "Transfer ${transfer_idx}: prescan returned status ${prescan_rc}"
	fi
	pipeline_artifact_logging::log_prescan "${transfer_idx}" "${prescan_output}" "${patterns_ref_name}" "${look_into}" "${node_name}"

	local enum_output=""
	set +e
	pipeline_artifact_transfer::run_enumerate "${node_name}" "${bundle_dir}" "${look_into}" "${patterns_ref_name}" enum_output
	local enum_rc=$?
	set -e
	case "${enum_rc}" in
		0) ;;
		1)
			log_info "Transfer ${transfer_idx}: enumeration returned no matches."
			;;
		2)
			log_info "Transfer ${transfer_idx}: enumeration failed (permissions) for ${look_into}"
			;;
		3)
			log_info "Transfer ${transfer_idx}: enumeration failed (directory missing or not a dir): ${look_into}"
			;;
		4)
			log_info "Transfer ${transfer_idx}: enumeration failed (cd error) into: ${look_into}"
			;;
		*) ;;
	esac
	local remote_files=()
	if [[ -n ${enum_output} ]]; then
		mapfile -t remote_files <<<"${enum_output}"
	fi

	if ((${#remote_files[@]} == 0)); then
		pipeline_artifact_transfer::handle_zero_matches "${transfer_idx}" "${node_name}" "${look_into}" "${patterns_ref_name}" "${bundle_dir}" "${exec_dir}" "${dest_dir}"
		return
	fi

	log_info "Transfer ${transfer_idx}: matched ${#remote_files[@]} file(s) to copy:"
	local matched
	for matched in "${remote_files[@]}"; do
		log_info "  ${matched}"
	done

	local dest_before
	dest_before=$(find "${dest_dir}" -mindepth 1 -maxdepth 1 -printf '.' 2>/dev/null | wc -c | tr -d '[:space:]' || true)
	log_info "Transfer ${transfer_idx}: ${#remote_files[@]} unique files from ${look_into} -> ${dest_dir}, FE entries before=${dest_before:-0}"

	# Detailed per-file pattern diagnostics removed after verifying transfer correctness.

	local copied=0
	local failed=0
	local file_name
	for file_name in "${remote_files[@]}"; do
		if [[ ${file_name} == */* ]]; then
			log_debug "Skipping nested path '${file_name}'"
			continue
		fi
		if scp -q -o StrictHostKeyChecking=no "root@${node_name}:${look_into%/}/${file_name}" "${dest_dir}/${file_name}"; then
			((copied++)) || true
		else
			((failed++)) || true
			log_warn "Failed to copy ${look_into%/}/${file_name}"
		fi
	done

	local dest_after
	dest_after=$(find "${dest_dir}" -mindepth 1 -maxdepth 1 -printf '.' 2>/dev/null | wc -c | tr -d '[:space:]' || true)
	local delta=$((${dest_after:-0} - ${dest_before:-0}))
	log_info "Transfer ${transfer_idx} FE destination after copy: entries=${dest_after:-0} (delta=${delta})"
	local per_pattern_after=()
	local pattern
	for pattern in "${patterns_ref[@]}"; do
		local count
		count=$(bash -lc "shopt -s nullglob; cd '${dest_dir}' 2>/dev/null || exit 0; set -- ${pattern}; echo \$#" 2>/dev/null || true)
		count=${count:-0}
		per_pattern_after+=("'${pattern}'=${count}")
	done
	log_info "Transfer ${transfer_idx} FE destination per-pattern matches (after): ${per_pattern_after[*]}"

	if ((failed > 0)); then
		log_warn "Transfer ${transfer_idx} partial: copied=${copied} failed=${failed} total=${#remote_files[@]}"
	else
		log_success "Transfer ${transfer_idx} completed: ${copied}/${#remote_files[@]} files copied."
	fi
}

pipeline_artifact_transfer::process_transfer() {
	local transfer_idx="${1:-}"
	local node_name="${2:-}"
	local dest_root="${3:-}"
	local exec_dir="${4:-}"
	local bundle_dir="${5:-}"
	local rule_map_name="$6"
	declare -n rule_map_ref="${rule_map_name}"
	local transfers_json="${7:-}"

	local look_into=""
	local subfolder=""
	local labels=()
	pipeline_collector::get_transfer "${transfers_json}" "${transfer_idx}" look_into subfolder labels
	local patterns=()
	pipeline_collector::patterns_from_labels "${rule_map_name}" "labels" "patterns"
	: "${rule_map_ref[@]:-}"
	: "${labels[@]:-}"
	: "${patterns[@]:-}"

	local dest_dir
	dest_dir="${dest_root}/${subfolder}"
	pipeline_env::ensure_directory "${dest_dir}"

	pipeline_artifact_logging::log_transfer_intro "${transfer_idx}" "${look_into}" "labels" "patterns"
	pipeline_artifact_transfer::handle_transfer "${transfer_idx}" "${node_name}" "${look_into}" "${dest_dir}" "${bundle_dir}" "${exec_dir}" "patterns"
}
