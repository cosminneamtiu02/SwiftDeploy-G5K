#!/usr/bin/env bash
# shellcheck shell=bash
# shellcheck source-path=../../common
# shellcheck source-path=../../common/collector
set -euo pipefail
IFS=$'\n\t'

PHASE_COLLECTION_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PIPELINE_COMMON_ROOT="${PIPELINE_COMMON_ROOT:-$(cd "${PHASE_COLLECTION_DIR}/../../common" && pwd)}"

# shellcheck source=experiments-runner/runtime/common/pipeline-environment.sh
source "${PIPELINE_COMMON_ROOT}/pipeline-environment.sh"
pipeline_env::bootstrap

PIPELINE_COLLECTOR_ROOT="${PIPELINE_COLLECTOR_ROOT:-${PIPELINE_COMMON_ROOT}/collector}"

# shellcheck source=experiments-runner/runtime/common/collector/collector-config.sh
source "${PIPELINE_COLLECTOR_ROOT}/collector-config.sh"
# shellcheck source=experiments-runner/runtime/common/collector/artifact-state.sh
source "${PIPELINE_COLLECTOR_ROOT}/artifact-state.sh"
# shellcheck source=experiments-runner/runtime/common/collector/artifact-collector-bundle.sh
source "${PIPELINE_COLLECTOR_ROOT}/artifact-collector-bundle.sh"
# shellcheck source=experiments-runner/runtime/common/collector/artifact-collector-transfer.sh
source "${PIPELINE_COLLECTOR_ROOT}/artifact-collector-transfer.sh"

usage() {
	cat <<'EOF'
Usage:
  collect-artifacts.sh run --config <config> --node <hostname> --exec-dir <path> --log-dir <dir> --state-file <state>
EOF
}

pipeline_collect_artifacts::run() {
	local config_path="${1:-}"
	local node_name="${2:-}"
	local exec_dir="${3:-}"
	local log_dir="${4:-}"
	local state_file="${5:-}"

	local base_path=""
	local rules_json=""
	local transfers_json=""
	pipeline_collector::load_config "${config_path}" base_path rules_json transfers_json
	pipeline_collector::validate_config "${base_path}" "${rules_json}" "${transfers_json}"

	if [[ -z ${base_path} ]]; then
		log_info 'No collection base_path defined; skipping artifact transfer.'
		pipeline_artifact_state::write "${state_file}" 'COLLECTION_SKIPPED=1'
		return 0
	fi

	local dest_root
	dest_root="${HOME}/collected/${base_path}"
	log_info "Collector destination root: ${dest_root}"
	pipeline_env::ensure_directory "${dest_root}"

	declare -A rule_map=()
	pipeline_collector::build_rule_map "${rules_json}" rule_map
	: "${rule_map[@]:-}"

	local bundle_dir
	bundle_dir=$(pipeline_artifact_bundle::deploy "${node_name}")
	trap 'pipeline_artifact_bundle::cleanup "'"${node_name}"' "'"${bundle_dir}"'' EXIT

	local transfer_total
	transfer_total=$(pipeline_collector::transfer_count "${transfers_json}")
	if ((transfer_total == 0)); then
		log_info 'No ftransfers defined; nothing to collect.'
		pipeline_artifact_state::write "${state_file}" 'COLLECTION_SKIPPED=1'
		return 0
	fi

	log_step 'Collecting experiment artifacts'

	local idx
	for ((idx = 0; idx < transfer_total; idx++)); do
		pipeline_artifact_transfer::process_transfer "${idx}" "${node_name}" "${dest_root}" "${exec_dir}" "${bundle_dir}" rule_map "${transfers_json}"
	done

	pipeline_artifact_state::write "${state_file}" \
		"COLLECTION_SKIPPED=0" \
		"DEST_ROOT=${dest_root}" \
		"TRANSFERS=${transfer_total}"
}

main() {
	case "${1:-}" in
		run)
			shift
			local config_path=""
			local node_name=""
			local exec_dir=""
			local log_dir=""
			local state_file=""
			while [[ $# -gt 0 ]]; do
				case "$1" in
					--config)
						config_path="$2"
						shift 2
						;;
					--node)
						node_name="$2"
						shift 2
						;;
					--exec-dir)
						exec_dir="$2"
						shift 2
						;;
					--log-dir)
						log_dir="$2"
						shift 2
						;;
					--state-file)
						state_file="$2"
						shift 2
						;;
					*)
						log_error "collect-artifacts.sh run: unknown argument $1"
						usage
						exit 1
						;;
				esac
			done
			if [[ -z ${config_path} || -z ${node_name} || -z ${exec_dir} || -z ${log_dir} || -z ${state_file} ]]; then
				die 'collect-artifacts.sh run requires --config, --node, --exec-dir, --log-dir, and --state-file.'
			fi
			pipeline_env::ensure_directory "${log_dir}"
			pipeline_collect_artifacts::run "${config_path}" "${node_name}" "${exec_dir}" "${log_dir}" "${state_file}"
			;;
		*)
			usage
			exit 1
			;;
	esac
}

main "$@"
